"""guest-portal 安全原語:密碼雜湊(scrypt)、session 簽章、審計日誌。

全程 stdlib,零外部依賴(比照 life-ops-mcp / CT203 裸套件最小攻擊面風格)。
密碼雜湊用 hashlib.scrypt(記憶體困難),不落任何 pip 套件。
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

# ── scrypt 參數(RFC 7914 建議互動登入級別)──
_N = 2 ** 14  # CPU/記憶體成本
_R = 8
_P = 1
_DKLEN = 32


def hash_password(password: str) -> str:
    """回傳 'scrypt$N$r$p$salt_b64$dk_b64' 自描述字串,寫入 NocoDB GuestAccounts.hash。"""
    salt = os.urandom(16)
    dk = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=_N, r=_R, p=_P, dklen=_DKLEN)
    return "scrypt${}${}${}${}${}".format(
        _N, _R, _P,
        base64.b64encode(salt).decode(),
        base64.b64encode(dk).decode(),
    )


# 固定 dummy hash(真 scrypt 產,格式合法可完整跑):未知/停用帳號路徑拿它跑一次 verify,
# 讓「帳號不存在」與「帳號存在但密碼錯」的回應時間一致,堵使用者名枚舉時序側信道。
DUMMY_HASH = "scrypt$16384$8$1$hzOPKmn906tNIb50wicEQw==$S4FqB0Vd2KKyOm7P0g5NmCZ9rYVD7RbIwWMBFvqcc+4="


def verify_password(password: str, stored: str) -> bool:
    """常數時間比對。stored 格式不符或空 → False(不拋例外,登入路徑不因髒資料 500)。"""
    try:
        scheme, n, r, p, salt_b64, dk_b64 = stored.split("$")
        if scheme != "scrypt":
            return False
        salt = base64.b64decode(salt_b64)
        expect = base64.b64decode(dk_b64)
        dk = hashlib.scrypt(
            password.encode("utf-8"), salt=salt,
            n=int(n), r=int(r), p=int(p), dklen=len(expect),
        )
        return hmac.compare_digest(dk, expect)
    except Exception:  # noqa: BLE001 — 任何解析/計算失敗都當驗證失敗
        return False


# ── session cookie 簽章(HMAC,無伺服器狀態)──
# 秘鑰由 env SESSION_SECRET 提供(部署時 openssl rand);缺則以啟動期臨時鑰
# (重啟即登出所有人,對這種低頻站可接受;正式部署務必給固定 env)。
_SECRET = os.environ.get("SESSION_SECRET", "").encode() or os.urandom(32)
SESSION_TTL = int(os.environ.get("SESSION_TTL_SECONDS", str(12 * 3600)))


def _b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _b64u_dec(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def make_session(username: str) -> str:
    """簽發 'payload_b64.sig_b64';payload = {u, exp}。"""
    payload = json.dumps(
        {"u": username, "exp": int(time.time()) + SESSION_TTL},
        separators=(",", ":"),
    ).encode()
    body = _b64u(payload)
    sig = hmac.new(_SECRET, body.encode(), hashlib.sha256).digest()
    return f"{body}.{_b64u(sig)}"


def read_session(token: str | None) -> str | None:
    """驗簽 + 驗未過期,回傳 username;任何不符回 None。"""
    if not token or "." not in token:
        return None
    body, _, sig = token.partition(".")
    try:
        expect = hmac.new(_SECRET, body.encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(_b64u_dec(sig), expect):
            return None
        payload = json.loads(_b64u_dec(body))
        if int(payload.get("exp", 0)) < time.time():
            return None
        return payload.get("u")
    except Exception:  # noqa: BLE001
        return None


# ── 審計日誌(JSONL 附加寫,供 CT260 hl-guest-watch 拉增量分析)──
# 密碼記錄策略(使用者裁決 2026-07-10):
#   未知帳號嘗試 → 記密碼原文(蜜罐情報,反正不是真帳號)
#   已知帳號密碼錯 → 預設遮罩(只記長度;GUEST_LOG_WRONG_PW=full 可切全文)
#   登入成功 → 永不記密碼
_LOG_PATH = Path(os.environ.get("GUEST_AUDIT_LOG", "/opt/guest-portal/data/audit.jsonl"))
_LOG_WRONG_PW_FULL = os.environ.get("GUEST_LOG_WRONG_PW", "mask") == "full"
_log_lock = threading.Lock()


def audit(event: str, *, ip: str, country: str, username: str = "",
          password: str | None = None, known_user: bool = False, extra: dict | None = None) -> None:
    """附加一筆審計。event ∈ login_ok|login_fail|login_unknown|locked。"""
    rec: dict = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "event": event,
        "ip": ip,
        "country": country or "??",
        "user": username,
        "known_user": known_user,
    }
    if password is not None:
        if event == "login_unknown":
            rec["pw"] = password  # 蜜罐:未知帳號記原文
        elif event in ("login_fail", "locked"):
            rec["pw"] = password if _LOG_WRONG_PW_FULL else f"<{len(password)} chars>"
        # login_ok 不帶密碼
    if extra:
        rec.update(extra)
    line = json.dumps(rec, ensure_ascii=False) + "\n"
    try:
        with _log_lock:
            _LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
            with _LOG_PATH.open("a", encoding="utf-8") as f:
                f.write(line)
    except Exception:  # noqa: BLE001 — 審計寫入失敗不得中斷登入流程
        pass
