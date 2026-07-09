"""生活助理轉發層(待辦49 生活對話框,2026-07-09)。

POST /api/life/chat → CT260 life-chat(:5002,Sonnet 5 唯讀工具+提案單)。
POST /api/life/confirm → 同服務 /confirm(HMAC 驗簽後服務端執行寫入)。
本層不解讀提案內容,只轉發;半徑受 life-chat 端寫入白名單 6 動作+驗簽+限速封頂。
權限比照 M3 actions.py:僅受理帶 Remote-User 的請求(portal.hl 經 Caddy forward_auth),
非認證鐵律,真邊界在 CT260 端(獨立 token+白名單+簽名)。
"""
import asyncio
import os
from datetime import datetime, timezone

import httpx

MODE = os.environ.get("PORTAL_MODE", "mock")
ACTION_AUTH = os.environ.get("PORTAL_ACTION_AUTH", "remote-user")  # remote-user | open
CHAT_URL = os.environ.get("LIFE_CHAT_URL", "")
CHAT_TOKEN = os.environ.get("LIFE_CHAT_TOKEN", "")

# claude -p 上限 110s → 轉發留餘裕;confirm 只跑幾個 API 呼叫,90s 綽綽有餘
_CHAT_TIMEOUT = httpx.Timeout(150.0, connect=5.0)
_CONFIRM_TIMEOUT = httpx.Timeout(90.0, connect=5.0)

_inflight_chat = asyncio.Lock()  # 單飛與 CT260 端一致:同時只跑一輪對話


class ChatError(Exception):
    def __init__(self, status: int, error: str, hint: str = ""):
        super().__init__(error)
        self.status, self.error, self.hint = status, error, hint


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def enabled() -> bool:
    return MODE == "mock" or bool(CHAT_URL and CHAT_TOKEN)


def allowed(remote_user: str | None) -> bool:
    return ACTION_AUTH != "remote-user" or bool(remote_user)


def info(remote_user: str | None) -> dict:
    """GET /api/life/chat:前端能力探測(零上游呼叫)。"""
    return {"enabled": enabled(), "allowed": allowed(remote_user),
            "scope": "calendar+ledger", "generated_at": _now()}


def _gate(remote_user: str | None) -> None:
    if not allowed(remote_user):
        raise ChatError(403, "僅限經 portal.hl 認證的請求", "直達 :8088 為唯讀,對話請走 portal.hl")
    if MODE != "mock" and not enabled():
        raise ChatError(503, "生活助理未配置",
                        "portal.env 補 LIFE_CHAT_URL/LIFE_CHAT_TOKEN 後 force-recreate")


def _validate_messages(body: dict) -> list:
    msgs = body.get("messages")
    ok = (isinstance(msgs, list) and 0 < len(msgs) <= 40
          and all(isinstance(m, dict) and m.get("role") in ("user", "assistant")
                  and isinstance(m.get("content"), str) and 0 < len(m["content"]) <= 4000
                  for m in msgs)
          and msgs[-1]["role"] == "user")
    if not ok:
        raise ChatError(400, "messages 形狀不合法", "≤40 則 {role:user|assistant, content};末則須為 user")
    return msgs


async def _post(path: str, payload: dict, timeout: httpx.Timeout) -> httpx.Response:
    async with httpx.AsyncClient(timeout=timeout) as client:
        return await client.post(f"{CHAT_URL}{path}",
                                 headers={"Authorization": f"Bearer {CHAT_TOKEN}"},
                                 json=payload)


def _map(r: httpx.Response, fallback: str) -> tuple[int, dict]:
    try:
        body = r.json()
    except ValueError:
        body = {}
    if r.status_code == 200 and body.get("ok"):
        return 200, body
    if r.status_code in (401, 403):
        # 403 可能是驗簽失敗/白名單拒絕——把服務端訊息帶給前端
        raise ChatError(403 if r.status_code == 403 else 502,
                        str(body.get("error") or "life-chat 拒絕請求")[:200],
                        "檢查 LIFE_CHAT_TOKEN 或提案是否過期/被改")
    if r.status_code == 429:
        raise ChatError(429, "對話限速中(6 次/分)", "稍候一分鐘再試")
    if r.status_code == 409:
        raise ChatError(409, "上一輪對話仍在處理中", "等它回完再送")
    if r.status_code == 410:
        raise ChatError(410, str(body.get("error") or "提案已過期")[:200], "重新對話產生提案")
    raise ChatError(502, f"{fallback}(HTTP {r.status_code})",
                    str(body.get("error") or "")[:200])


async def chat(body: dict, remote_user: str | None) -> tuple[int, dict]:
    _gate(remote_user)
    msgs = _validate_messages(body)
    if _inflight_chat.locked():
        raise ChatError(409, "上一輪對話仍在處理中", "等它回完再送")
    async with _inflight_chat:
        if MODE == "mock":
            return 200, await _mock_chat(msgs)
        try:
            r = await _post("/chat", {"messages": msgs}, _CHAT_TIMEOUT)
        except httpx.TimeoutException:
            raise ChatError(504, "生活助理無回應(timeout)", "模型可能仍在跑,稍候重問;或檢查 CT260 :5002")
        except httpx.HTTPError as e:
            raise ChatError(504, "life-chat 連線失敗",
                            f"{type(e).__name__};檢查 CT260 :5002 或 OpenWrt Allow-Monitor-To-CT260-LifeChat-5002")
        return _map(r, "life-chat 回應異常")


async def confirm(body: dict, remote_user: str | None) -> tuple[int, dict]:
    _gate(remote_user)
    for k in ("action", "args", "summary", "ts", "sig"):
        if k not in body:
            raise ChatError(400, f"缺欄位 {k}", "提案五欄位原樣帶回:action/args/summary/ts/sig")
    if MODE == "mock":
        return 200, {"ok": True, "result": f"mock:已執行 {body.get('summary')}", "mock": True}
    payload = {k: body[k] for k in ("action", "args", "summary", "ts", "sig")}
    try:
        r = await _post("/confirm", payload, _CONFIRM_TIMEOUT)
    except httpx.TimeoutException:
        raise ChatError(504, "確認執行無回應(timeout)", "結果見 TG 回報;或檢查 CT260 :5002")
    except httpx.HTTPError as e:
        raise ChatError(504, "life-chat 連線失敗", f"{type(e).__name__};檢查 CT260 :5002")
    return _map(r, "確認執行回應異常")


async def _mock_chat(msgs: list) -> dict:
    """mock:UI 走查用——問句含「記」「新增」「加」出提案卡,其餘純文字回覆。"""
    await asyncio.sleep(0.8)
    last = msgs[-1]["content"]
    if any(k in last for k in ("記", "新增", "加")):
        return {"ok": True,
                "reply": "好,我準備新增這筆(mock),請按確認卡執行:",
                "proposals": [{"action": "calendar_add",
                               "args": {"title": "牙醫", "start": "2026-07-11T14:00"},
                               "summary": "新增行程:07/11(六) 14:00 牙醫",
                               "ts": 0, "sig": "mock"}],
                "rejected": [], "meta": {"turns": 1, "secs": 0.8}}
    return {"ok": True,
            "reply": "你 7/10(五)有 2 個行程:09:00 站立會議、14:00 回診(mock)。",
            "proposals": [], "rejected": [], "meta": {"turns": 2, "secs": 0.8}}
