#!/usr/bin/env python3
"""mc-gate —— CT100 上的 MC 開停機閘門(mc-autosleep,2026-07-10)。

角色:CT102 LimboAutoServer 的 start/stop shell 指令打到這裡,
由本 hook 走 MCSManager protected_instance 穩定路徑開停實例——
與 /root/mc-safe-backup.sh 共用同一把 flock 鎖(/var/lock/mc-safe-backup.lock),
備份進行中喚醒/休眠一律等鎖,保證 tar 期間世界檔絕不被 Java 寫入。

介面(僅 CT102 10.70.70.10 經 nft 放行;Bearer token):
  GET  /health          -> 200 {"ok":true}
  POST /start           -> 202 受理(背景執行緒:等鎖->狀態=stopped 才 open)
  POST /stop            -> 202 受理(背景執行緒:等鎖->狀態=running 且 mcping 0 人才 stop)

稽核標記(stdout->journald,promtail 收 unit=mc-gate.service 供 CT260 哨兵發 TG):
  MC-GATE wake ok / wake skip status=N / wake deferred backup-lock
  MC-GATE sleep ok / sleep skip status=N / sleep skip players=N / sleep skip backup-lock
  MC-GATE auth-fail src=IP

零第三方依賴(stdlib only,比照 guest-portal BFF 戒律)。
"""
import fcntl
import hmac
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GATE_ENV = "/root/mc-gate.env"
MCSM_ENV = "/root/mcsm.env"       # 與 mc-safe-backup.sh 同一份憑證
LOCK_FILE = "/var/lock/mc-safe-backup.lock"   # ★ 與備份腳本同鎖域(衝突互斥核心)
WAKE_LOCK_WAIT = 300   # 喚醒等鎖上限(tar 實測 ~70s;備份完才開機=使用者裁決)
SLEEP_LOCK_WAIT = 45   # 休眠等鎖上限(拿不到=備份正在處理伺服器,跳過即可)
STATE_POLL_WAIT = 60   # busy/stopping 等狀態落定上限


def log(*a):
    print("MC-GATE", *a, flush=True)


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v.strip().strip('"').strip("'")
    return env


_gate = load_env(GATE_ENV)
_mcsm = load_env(MCSM_ENV)
TOKEN = _gate["GATE_TOKEN"]
BIND = _gate.get("GATE_BIND", "0.0.0.0")
PORT = int(_gate.get("GATE_PORT", "25580"))
MCS_URL = _mcsm["MCS_URL"].rstrip("/")
API_KEY = _mcsm["MCS_API_KEY"]
DAEMON_ID = _mcsm["DAEMON_ID"]
INSTANCE_ID = _mcsm["INSTANCE_ID"]

# 同類動作單飛:重複 join / 重複 idle 觸發不疊執行緒
_busy = {"start": threading.Lock(), "stop": threading.Lock()}


def _api(path, params, method="GET", timeout=10):
    qs = urllib.parse.urlencode({"apikey": API_KEY, **params})
    req = urllib.request.Request(f"{MCS_URL}{path}?{qs}", method=method,
                                 headers={"X-Requested-With": "XMLHttpRequest"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def instance_info():
    """(status, players) —— status: -1busy/0stopped/1stopping/2starting/3running;
    players: mcping 在線人數,拿不到(未上線/停機)回 None。"""
    d = _api("/api/auth/", {"advanced": "true"})
    insts = (d.get("data") or {}).get("instances") or []
    inst = next((i for i in insts if i.get("instanceUuid") == INSTANCE_ID),
                insts[0] if insts else None)
    if inst is None:
        raise RuntimeError("MCSM 回應無實例")
    info = inst.get("info") or {}
    players = int(info["currentPlayers"]) if info.get("mcPingOnline") else None
    return inst.get("status"), players


def mcs_open():
    d = _api("/api/protected_instance/open",
             {"daemonId": DAEMON_ID, "uuid": INSTANCE_ID}, method="POST")
    if d.get("status") != 200:
        raise RuntimeError(f"open 非 200: {d}")


def mcs_stop():
    d = _api("/api/protected_instance/stop",
             {"daemonId": DAEMON_ID, "uuid": INSTANCE_ID})
    if d.get("status") != 200:
        raise RuntimeError(f"stop 非 200: {d}")


def hold_lock(max_wait):
    """拿備份鎖(advisory,與 bash flock 同檔相容);逾時回 None。"""
    fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o644)
    deadline = time.monotonic() + max_wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                return None
            time.sleep(2)


def settle_status():
    """等 busy(-1)/stopping(1) 落定;回落定後 status。"""
    deadline = time.monotonic() + STATE_POLL_WAIT
    while True:
        st, _ = instance_info()
        if st not in (-1, 1) or time.monotonic() >= deadline:
            return st
        time.sleep(3)


def do_start():
    fd = hold_lock(WAKE_LOCK_WAIT)
    if fd is None:
        log("wake deferred backup-lock")   # 等待室玩家繼續等;下次 join 重觸發
        return
    try:
        st = settle_status()
        if st == 0:
            mcs_open()
            log("wake ok")
        else:
            log(f"wake skip status={st}")  # 2/3=已在路上;-1/1 未落定=保守不動
    finally:
        # open 送出即放鎖:不佔著鎖陪 Java 開機 60-90s,03:10 備份 flock -w 120 等得到
        os.close(fd)


def do_stop():
    fd = hold_lock(SLEEP_LOCK_WAIT)
    if fd is None:
        log("sleep skip backup-lock")      # 備份腳本正在管伺服器,不插手
        return
    try:
        st, players = instance_info()
        if st != 3:
            log(f"sleep skip status={st}")
            return
        if players is not None and players > 0:
            log(f"sleep skip players={players}")   # 防 beta 插件誤判(mcping 雙保險)
            return
        mcs_stop()
        log("sleep ok")
    finally:
        os.close(fd)


def _run(kind, fn):
    if not _busy[kind].acquire(blocking=False):
        return False   # 已有同類動作在途
    def wrapped():
        try:
            fn()
        except Exception as e:  # noqa: BLE001
            log(f"{kind} error {type(e).__name__}: {e}")
        finally:
            _busy[kind].release()
    threading.Thread(target=wrapped, daemon=True).start()
    return True


class Handler(BaseHTTPRequestHandler):
    server_version = "mc-gate"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _drain(self):
        n = int(self.headers.get("Content-Length") or 0)
        while n > 0:
            n -= len(self.rfile.read(min(n, 65536)))

    def _authed(self):
        got = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
        if hmac.compare_digest(got, TOKEN):
            return True
        log(f"auth-fail src={self.client_address[0]}")
        self._send(401, {"error": "unauthorized"})
        return False

    def do_GET(self):
        self._drain()
        if self.path == "/health":
            return self._send(200, {"ok": True})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        self._drain()
        if not self._authed():
            return
        if self.path == "/start":
            accepted = _run("start", do_start)
            return self._send(202, {"accepted": True, "queued": not accepted})
        if self.path == "/stop":
            accepted = _run("stop", do_stop)
            return self._send(202, {"accepted": True, "queued": not accepted})
        self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):  # 靜默預設存取日誌,只留 MC-GATE 標記
        pass


if __name__ == "__main__":
    log(f"listening {BIND}:{PORT} lock={LOCK_FILE}")
    try:
        ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
