"""guest-portal 資料層:載入 guest.json(推不是拉)、帳號查詢、每人資料過濾、登入鎖定。

guest.json 由 CT260 hl-write-guest 產出並 hl-push 到 /opt/guest-portal/data/guest.json。
BFF 只讀此檔(mtime 快取),永不直連 NocoDB/GCal——app 全程零憑證、零出站。

帳號連「登入名(身分證字號)」都以 scrypt 雜湊儲存(username_hash),資料庫/快照外洩
也讀不到明文身分證字號;登入時把輸入的登入名逐一 scrypt 比對(帳號數少,O(N) 可接受)。
person(記賬人名)維持明文=NocoDB 借貸 bucket 鍵,且本就存在 NocoDB,非新增曝露。

guest.json 結構:
{
  "generated_at": "...",
  "accounts": [ {"username_hash": "scrypt$...", "person": "小明", "hash": "scrypt$...", "enabled": true} ],
  "calendar": [ {"date":"2026-07-11","time":"14:00","title":"...","all_day":false} ],  # 全體共用(展示屋主行程)
  "debts": {
    "小明": {
       "net": -1200, "currency": "TWD",
       "open":   [ {"id":1,"dir":"they_owe|i_owe","amount":..,"item":..,"date":..,"due":..,"notes":..} ],
       "settled":[ ... 最近已結 10 筆 ... ]
    }
  }
}
"""
from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path

from . import security

_DATA_PATH = Path(os.environ.get("GUEST_DATA", "/opt/guest-portal/data/guest.json"))
_FIXTURE_PATH = Path(__file__).parent / "fixtures" / "guest.json"
MODE = os.environ.get("GUEST_MODE", "live")  # live | mock

_cache: dict = {}
_cache_mtime: float = -1.0
_cache_lock = threading.Lock()


def _source_path() -> Path:
    return _FIXTURE_PATH if MODE == "mock" else _DATA_PATH


def load() -> dict:
    """讀 guest.json,mtime 未變則回快取。檔案缺失/壞掉 → 回上次成功快取或空殼。"""
    global _cache, _cache_mtime
    path = _source_path()
    try:
        mtime = path.stat().st_mtime
    except OSError:
        # 檔案還沒被推上來:回空殼(前端顯示「資料尚未就緒」),不 500
        return _cache or {"generated_at": None, "accounts": [], "calendar": [], "debts": {}}
    if mtime == _cache_mtime and _cache:
        return _cache
    with _cache_lock:
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
            _cache = doc
            _cache_mtime = mtime
        except Exception:  # noqa: BLE001 — 壞檔不覆蓋上次好資料
            if not _cache:
                _cache = {"generated_at": None, "accounts": [], "calendar": [], "debts": {}}
        return _cache


def find_by_login(username: str) -> dict | None:
    """把輸入的登入名逐一 scrypt 比對 username_hash(帳號數少 O(N) 可接受)。
    永遠掃完全部帳號(不早退)=不因帳號位置/存在與否洩漏時序。找到回帳號,否則 None。"""
    matched = None
    for acc in load().get("accounts", []):
        if security.verify_password(username, acc.get("username_hash", "")):
            matched = acc  # 不 break,掃完等化時序
    return matched


def find_by_person(person: str) -> dict | None:
    """依 person(記賬人名,明文)精確比對——session 內存 person,/me /data 用它復核 enabled。"""
    for acc in load().get("accounts", []):
        if acc.get("person") == person:
            return acc
    return None


def data_for(person: str) -> dict:
    """登入後回傳此人可見資料:全體行事曆 + 只屬於自己的借貸。"""
    doc = load()
    debts = doc.get("debts", {}).get(person, {"net": 0, "currency": "TWD", "open": [], "settled": []})
    return {
        "person": person,
        "generated_at": doc.get("generated_at"),
        "calendar": doc.get("calendar", []),
        "debts": debts,
    }


# ── 登入失敗鎖定(記憶體態,per (username,ip));重啟即清,對低頻站可接受 ──
_LOCK_THRESHOLD = int(os.environ.get("GUEST_LOCK_FAILS", "5"))
_LOCK_WINDOW = int(os.environ.get("GUEST_LOCK_WINDOW_SECONDS", str(15 * 60)))
_fails: dict[tuple[str, str], list[float]] = {}
_fails_lock = threading.Lock()


def _key(username: str, ip: str) -> tuple[str, str]:
    return (username or "", ip or "")


def is_locked(username: str, ip: str) -> bool:
    now = time.time()
    with _fails_lock:
        hits = [t for t in _fails.get(_key(username, ip), []) if now - t < _LOCK_WINDOW]
        _fails[_key(username, ip)] = hits
        return len(hits) >= _LOCK_THRESHOLD


def record_fail(username: str, ip: str) -> int:
    """記一次失敗,回傳窗口內累計次數。"""
    now = time.time()
    with _fails_lock:
        # 機會性清除:字典過大時掃掉全過期 key(擋輪換帳號/IP 撐大記憶體)
        if len(_fails) > 4096:
            for k in [k for k, ts in _fails.items()
                      if not any(now - t < _LOCK_WINDOW for t in ts)]:
                del _fails[k]
        hits = [t for t in _fails.get(_key(username, ip), []) if now - t < _LOCK_WINDOW]
        hits.append(now)
        _fails[_key(username, ip)] = hits
        return len(hits)


def clear_fails(username: str, ip: str) -> None:
    with _fails_lock:
        _fails.pop(_key(username, ip), None)
