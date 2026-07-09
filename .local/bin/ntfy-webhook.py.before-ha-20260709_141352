#!/usr/bin/env python3
"""
ntfy-webhook: 待辦19d — CT260 極簡動作 webhook（:5001，Bearer 驗證）。

ntfy 互動按鈕（X-Actions http POST）打進來，只允許白名單動作字典內的具名動作；
動作與請求全量落 log，執行後回發 TG「已執行 X，結果 Y」。
安全邊界：只做白名單既定動作，不接受任意命令——觀測/操作分離（待辦19 原文行401）。

設定（chmod 600）：
  ~/.config/homelab/ntfy-webhook.env   WEBHOOK_TOKEN / WEBHOOK_PORT(預設5001)
  ~/.config/homelab/notify-telegram.env TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID（回發用，沿用）

請求格式：POST /run  Authorization: Bearer <token>
  body JSON {"action": "<白名單動作名>", "param": "<選填，僅 silence-* 用=alertname>"}
GET /health 免驗證回 ok（Kuma 探活用）。

偏離記錄：原文 flask → python3 stdlib（CT260 無 sudo 不裝包，比照 CT203 gate.py 先例）。
"""
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import urllib.request

try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo("Asia/Taipei")
except Exception:
    TZ = timezone.utc

HOME = Path(os.path.expanduser("~"))
CONFIG_FILES = [
    HOME / ".config/homelab/ntfy-webhook.env",
    HOME / ".config/homelab/notify-telegram.env",
]
LOG_FILE = HOME / ".local/state/homelab-notify/webhook.log"

PARAM_RE = re.compile(r"^[A-Za-z0-9_:-]{1,64}$")

# --- 白名單動作字典：每顆按鈕 = 這裡一個具名動作；除 silence-* 外一律無參數 ---
# 執行路徑沿用 notifier 慣例：CT260 不能直連 VLAN80 → ssh pve24 -> pct exec。
_PCT201 = ["ssh", "pve24-auto", "sudo", "pct", "exec", "201", "--"]


def _amtool(dur):
    def build(param):
        return _PCT201 + ["docker", "exec", "alertmanager",
                          "amtool", "silence", "add", f"alertname={param}",
                          "--alertmanager.url=http://localhost:9093",
                          f"--duration={dur}", "--author=ntfy-button",
                          "--comment=phone-button"]
    return build


ACTIONS = {
    # 告警靜音（param=alertname，白名單唯二收參數的動作）
    "silence-1h":  {"desc": "靜音該告警 1 小時",  "param": True,  "cmd": _amtool("1h")},
    "silence-24h": {"desc": "靜音該告警 24 小時", "param": True,  "cmd": _amtool("24h")},
    # CT201 監控棧個別服務重啟
    "restart-gotify":       {"desc": "重啟 Gotify",       "cmd": _PCT201 + ["docker", "restart", "gotify"]},
    "restart-kuma":         {"desc": "重啟 Uptime Kuma",  "cmd": _PCT201 + ["docker", "restart", "uptime-kuma"]},
    "restart-grafana":      {"desc": "重啟 Grafana",      "cmd": _PCT201 + ["docker", "restart", "grafana"]},
    "restart-prometheus":   {"desc": "重啟 Prometheus",   "cmd": _PCT201 + ["docker", "restart", "prometheus"]},
    "restart-alertmanager": {"desc": "重啟 Alertmanager", "cmd": _PCT201 + ["docker", "restart", "alertmanager"]},
    "restart-ntfy":         {"desc": "重啟 ntfy",         "cmd": _PCT201 + ["docker", "restart", "ntfy"]},
    "restart-monitoring-stack": {"desc": "重啟整個監控棧（compose restart）",
                                 "cmd": _PCT201 + ["bash", "-lc",
                                                   "cd /opt/monitoring && docker compose restart"]},
    # 容器/CT 層級
    "pct-reboot-201": {"desc": "重啟 CT201（監控主機）", "cmd": ["ssh", "pve24-auto", "sudo", "pct", "reboot", "201"]},
    "pct-start-250":  {"desc": "啟動 CT250（沙盒，窮人遙控器）", "cmd": ["ssh", "pve24-auto", "sudo", "pct", "start", "250"]},
    # 其他節點具名處置
    "restart-squid":     {"desc": "重啟 CT202 squid",
                          "cmd": ["ssh", "pve24-auto", "sudo", "pct", "exec", "202", "--",
                                  "systemctl", "restart", "squid"]},
    "restart-ctdmz-nft": {"desc": "重啟 CT203 ctdmz-nft（會清空 tailnet 通行證=需重驗）",
                          "cmd": ["ssh", "pve24-auto", "sudo", "pct", "exec", "203", "--",
                                  "systemctl", "restart", "ctdmz-nft"]},
}

# 全域簡易限速：每 60s 最多 N 次動作執行（診斷/誤按保護；被拒請求不計）
RATE_MAX = 6
_rate_lock = threading.Lock()
_rate_window = []


def log(msg):
    ts = datetime.now(TZ).strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass
    print(line, file=sys.stderr)


def load_config():
    cfg = {}
    for cf in CONFIG_FILES:
        if not cf.exists():
            continue
        for raw in cf.read_text().splitlines():
            raw = raw.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                continue
            k, v = raw.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


CFG = load_config()


def tg_send(text):
    token = CFG.get("TELEGRAM_BOT_TOKEN")
    chat = CFG.get("TELEGRAM_CHAT_ID")
    if not token or not chat:
        return
    data = json.dumps({"chat_id": chat, "text": text,
                       "disable_web_page_preview": True}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=data, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=20).read()
    except Exception as e:
        log(f"tg send failed: {type(e).__name__}: {str(e)[:120]}")


def rate_ok():
    now = time.time()
    with _rate_lock:
        while _rate_window and now - _rate_window[0] > 60:
            _rate_window.pop(0)
        if len(_rate_window) >= RATE_MAX:
            return False
        _rate_window.append(now)
        return True


def run_action(name, param):
    spec = ACTIONS[name]
    cmd = spec["cmd"](param) if spec.get("param") else spec["cmd"]
    t0 = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        rc, out = r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        rc, out = -1, "timeout 120s"
    dt = time.time() - t0
    return rc, out[-400:], dt


class Handler(BaseHTTPRequestHandler):
    server_version = "ntfy-webhook/1.0"
    protocol_version = "HTTP/1.1"
    timeout = 30  # 對抗驗證加固：slowloris/慢送請求行 30s 斷線，不佔死執行緒

    def _reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # 靜默預設 stderr access log（自管 log）
        pass

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, {"ok": True})
        else:
            self._reply(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        src = self.client_address[0]
        if self.path != "/run":
            self._reply(404, {"ok": False, "error": "not found"})
            return
        auth = self.headers.get("Authorization", "")
        # 雙 token(待辦49 M3):WEBHOOK_TOKEN_PORTAL 供 portal BFF,與 ntfy 按鈕 token 分開輪替(報告 §9)
        via = None
        for kind, tok in (("ntfy", CFG.get("WEBHOOK_TOKEN", "")),
                          ("portal", CFG.get("WEBHOOK_TOKEN_PORTAL", ""))):
            if tok and hmac.compare_digest(auth, "Bearer " + tok):
                via = kind
                break
        if via is None:
            log(f"DENY auth src={src}")
            self._reply(401, {"ok": False, "error": "unauthorized"})
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n < 0 or n > 4096:  # 對抗驗證加固：負值會讓 read(-1) 讀到 EOF 卡死執行緒
                raise ValueError("bad content-length")
            body = json.loads(self.rfile.read(n).decode() or "{}")
            action = str(body.get("action", ""))
            param = body.get("param")
        except Exception:
            log(f"DENY bad-body src={src}")
            self._reply(400, {"ok": False, "error": "bad request"})
            return
        if action not in ACTIONS:
            log(f"DENY non-whitelist src={src} action={action!r}")
            self._reply(403, {"ok": False, "error": "action not in whitelist"})
            return
        spec = ACTIONS[action]
        if spec.get("param"):
            if not (isinstance(param, str) and PARAM_RE.match(param)):
                log(f"DENY bad-param src={src} action={action} param={param!r}")
                self._reply(400, {"ok": False, "error": "bad param"})
                return
        else:
            param = None
        if not rate_ok():
            log(f"DENY rate-limit src={src} action={action}")
            self._reply(429, {"ok": False, "error": "rate limited"})
            return
        label = f"{action}" + (f"({param})" if param else "")
        log(f"RUN src={src} via={via} {label}")
        rc, out, dt = run_action(action, param)
        ok = rc == 0
        log(f"DONE {label} rc={rc} {dt:.1f}s out={out[:160]!r}")
        emoji = "✅" if ok else "❌"
        tg_send(f"🔘 {'portal' if via == 'portal' else 'ntfy 按鈕'}：已執行 {label} — {spec['desc']}\n"
                f"{emoji} 結果 rc={rc}（{dt:.1f}s）" + (f"\n{out[-300:]}" if out else ""))
        self._reply(200 if ok else 500,
                    {"ok": ok, "action": action, "rc": rc, "out": out[-200:]})


def main():
    if not CFG.get("WEBHOOK_TOKEN"):
        log("missing WEBHOOK_TOKEN in ~/.config/homelab/ntfy-webhook.env; aborting")
        sys.exit(1)
    port = int(CFG.get("WEBHOOK_PORT", "5001"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    log(f"ntfy-webhook listening :{port} actions={len(ACTIONS)}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
