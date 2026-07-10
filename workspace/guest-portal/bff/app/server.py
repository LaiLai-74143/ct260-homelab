"""guest-portal —— 純 stdlib HTTP server(零 pip 依賴,比照 CT203/life-ops-mcp 最小攻擊面)。

DMZ 節點(CT204)只需 Debian 內建 python3,無 venv/pip/Docker/PyPI 窗。
以 ThreadingHTTPServer 承載;前面是 CT203 Caddy(:80 host 分流)+ CF Tunnel。

端點:
  GET  /api/health           免驗,回模式/資料時間/帳號數
  POST /api/login            {username,password} → 設 session cookie / 401 / 429(鎖定)
  POST /api/logout           清 cookie
  GET  /api/me               驗 cookie,回 {username,person} / 401
  GET  /api/data             驗 cookie,回此人可見資料(全體行程 + 自己借貸)/ 401
  GET  /*                    SPA 靜態檔(dist),找不到回 index.html

執行:python3 -m app.server(WorkingDirectory=部署根;env 見下)
env:GUEST_MODE, GUEST_STATIC, GUEST_DATA, GUEST_AUDIT_LOG, SESSION_SECRET,
    GUEST_COOKIE_SECURE, GUEST_BIND, GUEST_PORT, GUEST_LOG_WRONG_PW
"""
from __future__ import annotations

import json
import mimetypes
import os
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

from . import security, store

VERSION = "0.1.0"
BASE = Path(__file__).resolve().parent
STATIC_DIR = Path(os.environ.get("GUEST_STATIC", BASE.parent.parent / "frontend" / "dist"))
COOKIE_NAME = "gp_session"
COOKIE_SECURE = os.environ.get("GUEST_COOKIE_SECURE", "1" if store.MODE == "live" else "0") == "1"
BIND = os.environ.get("GUEST_BIND", "127.0.0.1")
PORT = int(os.environ.get("GUEST_PORT", "8300"))
MAX_BODY = 8192  # 登入 body 極小;超過即拒(擋垃圾請求)


class Handler(BaseHTTPRequestHandler):
    server_version = "guest-portal/" + VERSION
    protocol_version = "HTTP/1.1"

    # ── 輔助 ──
    def _client_ip(self) -> str:
        cf = self.headers.get("cf-connecting-ip")
        if cf:
            return cf.strip()
        xff = self.headers.get("x-forwarded-for")
        if xff:
            return xff.split(",")[0].strip()
        return self.client_address[0] if self.client_address else "?"

    def _country(self) -> str:
        return self.headers.get("cf-ipcountry", "??")

    def _cookie_user(self) -> str | None:
        raw = self.headers.get("cookie")
        if not raw:
            return None
        try:
            c = SimpleCookie()
            c.load(raw)
            morsel = c.get(COOKIE_NAME)
            return security.read_session(morsel.value) if morsel else None
        except Exception:  # noqa: BLE001
            return None

    def _send_json(self, status: int, payload: dict, set_cookie: str | None = None) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if set_cookie:
            self.send_header("Set-Cookie", set_cookie)
        self.end_headers()
        self.wfile.write(body)

    def _err(self, status: int, error: str, hint: str = "") -> None:
        self._send_json(status, {"error": error, "hint": hint})

    def _drain_body(self) -> bytes:
        """讀掉整個請求 body(HTTP/1.1 keep-alive 下不讀=殘留污染下一請求解析)。
        超過 MAX_BODY 仍照 Content-Length 全部讀掉再丟棄,保持連線同步。"""
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0:
            return b""
        data = self.rfile.read(length)  # 一律讀完,避免 keep-alive 錯位
        return data if length <= MAX_BODY else b""  # 過大=視為空(不解析)

    def _read_json(self) -> dict | None:
        raw = self._body  # do_POST 已讀好
        if not raw:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:  # noqa: BLE001
            return None

    def _cookie_header(self, token: str) -> str:
        parts = [
            f"{COOKIE_NAME}={token}",
            "Path=/",
            "HttpOnly",
            "SameSite=Lax",
            f"Max-Age={security.SESSION_TTL}",
        ]
        if COOKIE_SECURE:
            parts.append("Secure")
        return "; ".join(parts)

    # ── 路由 ──
    def do_GET(self) -> None:  # noqa: N802
        self._drain_body()  # 正常 GET 無 body=no-op;防非標準 GET+body 污染 keep-alive
        path = urlparse(self.path).path
        if path == "/api/health":
            return self._health()
        if path == "/api/me":
            return self._me()
        if path == "/api/data":
            return self._data()
        if path.startswith("/api/"):
            return self._err(404, "not found")
        return self._static(path)

    def do_POST(self) -> None:  # noqa: N802
        # 先讀掉 body(即使 handler 不用它)——否則 keep-alive 下殘留 body 污染下一請求
        self._body = self._drain_body()
        path = urlparse(self.path).path
        if path == "/api/login":
            return self._login()
        if path == "/api/logout":
            return self._logout()
        return self._err(404, "not found")

    def do_HEAD(self) -> None:  # noqa: N802
        self._drain_body()
        # 探活/預檢:回 200 不帶 body
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ── 端點實作 ──
    def _health(self) -> None:
        doc = store.load()
        self._send_json(200, {
            "ok": True,
            "mode": store.MODE,
            "version": VERSION,
            "data_generated_at": doc.get("generated_at"),
            "accounts": len(doc.get("accounts", [])),
            "time": datetime.now(timezone.utc).isoformat(),
        })

    def _login(self) -> None:
        ip, country = self._client_ip(), self._country()
        body = self._read_json()
        if body is None:
            return self._err(400, "請求格式錯誤", "需 JSON body {username, password}")
        username = (body.get("username") or "").strip()
        password = body.get("password") or ""
        if not username or not password:
            return self._err(400, "缺帳號或密碼")

        acc = store.find_account(username)
        known = acc is not None and acc.get("enabled", True)

        if store.is_locked(username, ip):
            security.audit("locked", ip=ip, country=country, username=username,
                           password=password, known_user=known)
            return self._err(429, "嘗試過於頻繁", "帳號暫時鎖定,請 15 分鐘後再試")

        if acc is None:
            security.verify_password(password, security.DUMMY_HASH)  # 等化時間,堵帳號枚舉
            store.record_fail(username, ip)
            security.audit("login_unknown", ip=ip, country=country, username=username,
                           password=password, known_user=False)
            return self._err(401, "帳號或密碼錯誤")

        if not acc.get("enabled", True):
            security.verify_password(password, security.DUMMY_HASH)  # 等化時間
            store.record_fail(username, ip)
            security.audit("login_fail", ip=ip, country=country, username=username,
                           password=password, known_user=True, extra={"reason": "disabled"})
            return self._err(401, "帳號或密碼錯誤")

        if not security.verify_password(password, acc.get("hash", "")):
            n = store.record_fail(username, ip)
            security.audit("login_fail", ip=ip, country=country, username=username,
                           password=password, known_user=True, extra={"fails": n})
            return self._err(401, "帳號或密碼錯誤")

        store.clear_fails(username, ip)
        security.audit("login_ok", ip=ip, country=country, username=username, known_user=True)
        token = security.make_session(username)
        self._send_json(200, {"ok": True, "username": username},
                        set_cookie=self._cookie_header(token))

    def _logout(self) -> None:
        expired = f"{COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
        self._send_json(200, {"ok": True}, set_cookie=expired)

    def _me(self) -> None:
        user = self._cookie_user()
        if not user:
            return self._err(401, "未登入")
        acc = store.find_account(user)
        if acc is None or not acc.get("enabled", True):
            return self._err(401, "帳號已停用")
        self._send_json(200, {"username": user, "person": acc.get("person") or user})

    def _data(self) -> None:
        user = self._cookie_user()
        if not user:
            return self._err(401, "未登入")
        acc = store.find_account(user)
        if acc is None or not acc.get("enabled", True):
            return self._err(401, "帳號已停用")
        self._send_json(200, store.data_for(user))

    def _static(self, path: str) -> None:
        # SPA:實體檔存在則回,否則 index.html(前端路由)
        rel = unquote(path).lstrip("/")
        # 防目錄穿越:解析後必須仍在 STATIC_DIR 內
        target = (STATIC_DIR / rel).resolve()
        index = (STATIC_DIR / "index.html").resolve()
        try:
            inside = target == STATIC_DIR.resolve() or STATIC_DIR.resolve() in target.parents
        except Exception:  # noqa: BLE001
            inside = False
        if rel and inside and target.is_file():
            return self._send_file(target)
        if index.is_file():
            return self._send_file(index)
        return self._err(404, "not found")

    def _send_file(self, fp: Path) -> None:
        try:
            data = fp.read_bytes()
        except OSError:
            return self._err(404, "not found")
        ctype = mimetypes.guess_type(str(fp))[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        # 帶指紋的 assets 可長快取;index.html 不快取
        if "/assets/" in fp.as_posix():
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        else:
            self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    # 靜音預設 access log(改用簡潔一行;錯誤仍留)
    def log_message(self, fmt: str, *args) -> None:  # noqa: A002
        pass


def main() -> None:
    mimetypes.add_type("application/javascript", ".js")
    mimetypes.add_type("application/javascript", ".mjs")
    mimetypes.add_type("text/css", ".css")
    mimetypes.add_type("font/woff2", ".woff2")
    mimetypes.add_type("font/woff", ".woff")
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"guest-portal {VERSION} mode={store.MODE} listening on {BIND}:{PORT} "
          f"static={STATIC_DIR}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.shutdown()


if __name__ == "__main__":
    main()
