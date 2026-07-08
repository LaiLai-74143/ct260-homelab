"""M3 動作轉發層(待辦49 M3,2026-07-08)。

BFF 唯一的寫入方向端點:POST /api/action → CT260 ntfy-webhook(:5001,待辦19 白名單機制)。
本層不執行任何動作,只轉發具名白名單動作;半徑受 webhook 端 13 動作字典 + 6/分限速封頂。
刻意不走 providers._get()——那是唯讀快取/negative-cache 語意,動作不可快取、不可去重合併。

權限(使用者裁決 2026-07-08):PORTAL_ACTION_AUTH=remote-user(預設)時僅受理帶
Remote-User header 的請求(portal.hl 經 Caddy forward_auth 才有)。與生活頁 8b 同款
兩層模式——非認證鐵律(直達 :8088 可偽造 header),真邊界=webhook 白名單+獨立 token+限速。

token:WEBHOOK_TOKEN_PORTAL 與手機 ntfy 按鈕的 WEBHOOK_TOKEN 分開(報告 §9,可獨立輪替)。
"""
import asyncio
import os
import re
from datetime import datetime, timezone

import httpx

from .registry import WEBHOOK_ACTIONS

MODE = os.environ.get("PORTAL_MODE", "mock")
ACTION_AUTH = os.environ.get("PORTAL_ACTION_AUTH", "remote-user")  # remote-user | open
WEBHOOK_URL = os.environ.get("WEBHOOK_URL", "")
WEBHOOK_TOKEN = os.environ.get("WEBHOOK_TOKEN_PORTAL", "")
MOCK_ACTION = os.environ.get("PORTAL_MOCK_ACTION", "ok")  # ok | fail | ratelimit | slow

# 鏡像自 webhook 端 PARAM_RE(ntfy-webhook.py)——前置驗參,壞參不消耗 CT260 限速額度
PARAM_RE = re.compile(r"^[A-Za-z0-9_:-]{1,64}$")

# webhook 同步執行 subprocess timeout=120s → 轉發上限留餘裕
_TIMEOUT = httpx.Timeout(130.0, connect=5.0)

# in-flight 防重:同 action:param 併發第二發回 409(多分頁在同一 BFF 上有效)
_inflight: set[str] = set()


class ActionError(Exception):
    """帶 HTTP 狀態碼的動作錯誤,main.py 統一折成 {error,hint}。"""

    def __init__(self, status: int, error: str, hint: str = ""):
        super().__init__(error)
        self.status, self.error, self.hint = status, error, hint


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def enabled() -> bool:
    """動作功能是否已配置(mock 恆 true;live 需 WEBHOOK_URL+token 兩鍵)。"""
    return MODE == "mock" or bool(WEBHOOK_URL and WEBHOOK_TOKEN)


def allowed(remote_user: str | None) -> bool:
    """本請求可否操作(Q2 開關)。"""
    return ACTION_AUTH != "remote-user" or bool(remote_user)


def actions_info(remote_user: str | None) -> dict:
    """GET /api/actions:前端能力探測(零上游呼叫)。"""
    return {
        "enabled": enabled(),
        "allowed": allowed(remote_user),
        "scope": "all-firing",  # 使用者裁決:全部 firing 掛靜音,對映者加處置鍵
        "actions": {k: {"desc": v["desc"],
                        **({"param": v["param"]} if v.get("param") else {}),
                        **({"danger": v["danger"]} if v.get("danger") else {})}
                    for k, v in WEBHOOK_ACTIONS.items()},
        "alert_map": _alert_map(),
        "generated_at": _now(),
    }


def _alert_map() -> dict:
    from .registry import ALERT_ACTION_MAP
    return ALERT_ACTION_MAP


def _validate(body: dict, remote_user: str | None) -> tuple[str, str | None, dict]:
    """驗證鏈(全過才打 webhook,失敗不消耗 CT260 限速額度)。"""
    if not allowed(remote_user):
        raise ActionError(403, "僅限經 portal.hl 認證的請求", "直達 :8088 為唯讀,操作請走 portal.hl")
    action = str(body.get("action", ""))
    spec = WEBHOOK_ACTIONS.get(action)
    if spec is None:
        raise ActionError(403, "動作不在白名單", "見 GET /api/actions;鏡像表=registry.py WEBHOOK_ACTIONS")
    param = body.get("param")
    if spec.get("param"):
        if not (isinstance(param, str) and PARAM_RE.match(param)):
            raise ActionError(400, "參數不合法", f"{action} 需 param={spec['param']}(regex 同 webhook 端)")
    else:
        param = None  # 不收參數的動作強制丟棄,不透傳
    if MODE != "mock" and not enabled():
        raise ActionError(503, "動作功能未配置",
                          "portal.env 補 WEBHOOK_URL/WEBHOOK_TOKEN_PORTAL 後 force-recreate")
    return action, param, spec


async def _post_webhook(action: str, param: str | None) -> httpx.Response:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        return await client.post(f"{WEBHOOK_URL}/run",
                                 headers={"Authorization": f"Bearer {WEBHOOK_TOKEN}"},
                                 json={"action": action, "param": param})


async def _mock_result(action: str, spec: dict) -> dict:
    """mock 模擬(PORTAL_MOCK_ACTION=ok|fail|ratelimit|slow)——UI 四態走查用。"""
    await asyncio.sleep(120 if MOCK_ACTION == "slow" else 0.6)
    if MOCK_ACTION == "fail":
        raise ActionError(502, "動作已執行但失敗", f"mock rc=1:{spec['desc']}")
    if MOCK_ACTION == "ratelimit":
        raise ActionError(429, "動作限速中(全域 6 次/分,與手機 ntfy 按鈕共用)", "稍候一分鐘再試")
    return {"ok": True, "action": action, "rc": 0, "out": "", "desc": spec["desc"],
            "mock": True, "generated_at": _now()}


async def run(body: dict, remote_user: str | None) -> tuple[int, dict]:
    """POST /api/action 主流程;回 (status, payload)。"""
    action, param, spec = _validate(body, remote_user)
    key = f"{action}:{param or ''}"
    if key in _inflight:
        raise ActionError(409, "同一動作執行中", "等前一發結果(webhook 同步執行,最長 120s)")
    _inflight.add(key)
    try:
        if MODE == "mock":
            return 200, await _mock_result(action, spec)
        if spec.get("fire_and_forget"):
            # pct-reboot-201 會殺掉 BFF 自身,同步等待必死於斷線 → 送出即回 202,
            # 結果由 CT260 回發 TG 兜底;前端靠 Offline 畫面+自動重連恢復。
            asyncio.get_running_loop().create_task(_fire_and_forget(action, param))
            return 202, {"ok": True, "accepted": True, "action": action, "desc": spec["desc"],
                         "hint": "CT201 重啟中,入口將短暫離線後自動恢復;結果見 TG",
                         "generated_at": _now()}
        try:
            r = await _post_webhook(action, param)
        except httpx.TimeoutException:
            raise ActionError(504, "webhook 無回應(timeout)",
                              "動作可能仍在執行,結果見 TG 回報;或檢查 CT260 :5001 與防火牆放行")
        except httpx.HTTPError as e:
            raise ActionError(504, "webhook 連線失敗",
                              f"{type(e).__name__};檢查 CT260 :5001 或 OpenWrt Allow-Monitor-To-CT260-Webhook-5001")
        return _map_response(r, action, spec)
    finally:
        _inflight.discard(key)


async def _fire_and_forget(action: str, param: str | None) -> None:
    try:
        await _post_webhook(action, param)
    except httpx.HTTPError:
        pass  # BFF 自身將被該動作重啟,斷線屬預期;結果以 TG 回發為準


def _map_response(r: httpx.Response, action: str, spec: dict) -> tuple[int, dict]:
    try:
        body = r.json()
    except ValueError:
        body = {}
    if r.status_code == 200 and body.get("ok"):
        return 200, {"ok": True, "action": action, "rc": body.get("rc", 0),
                     "out": body.get("out", ""), "desc": spec["desc"], "generated_at": _now()}
    if r.status_code == 429:
        raise ActionError(429, "動作限速中(全域 6 次/分,與手機 ntfy 按鈕共用)", "稍候一分鐘再試")
    if r.status_code in (401, 403):
        raise ActionError(502, "webhook 拒絕請求",
                          "檢查 WEBHOOK_TOKEN_PORTAL 或動作鏡像表同步(registry.py ↔ ntfy-webhook.py)")
    if r.status_code == 500:
        out = str(body.get("out", ""))[:200]
        raise ActionError(502, f"動作已執行但失敗(rc={body.get('rc', '?')})", out or spec["desc"])
    raise ActionError(502, f"webhook 回應異常(HTTP {r.status_code})", str(body)[:200])
