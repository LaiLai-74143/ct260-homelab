"""遊戲 MCSM 控制轉發層(待辦49 0.8.0,2026-07-09)。

BFF → MCSManager(:23333,9.x)protected_instance API,走實例的優雅開/停/重啟
(open/stop/restart)——不含 kill(那是粗暴 SIGKILL Java 進程)、不含檔案/設定面。
實例 uuid/daemonId 由 BFF 自身向 MCSM 解析(認 Fabric-MC),不吃前端傳入,
杜絕帶任意 uuid 操控別的實例。

權限(使用者裁決 2026-07-09 Q2「portal.hl+PC40 皆可」;審查修正 2026-07-09):
:8088 的可達面不只 PC40(發證手機經 CT203 masq、VLAN80 主機皆可達)——故 gate=
Remote-User(portal.hl 經 Caddy)**或** 來源 IP 在 PORTAL_GAME_ALLOW_IPS(預設
PC40 192.168.40.4)。另要求自訂 header X-Requested-With(跨站惡意頁的簡單請求
帶不了自訂 header,會被 CORS preflight 擋下=CSRF 防護)。與 M3 同款非硬邊界
(VLAN80 主機可偽造 header,明文接受);真邊界=BFF 白名單三動作+MCSM_CTRL_KEY
需獨立配置(未設=控制停用)。與讀取用的 MCSM_API_KEY 分開(可獨立輪替)。
key 以 query 參數傳 MCSM(其 API 形制),會入 MCSM access log——CT100 root-only,
接受並文件化;疑外洩即輪替。
"""
import asyncio
import os
from datetime import datetime, timezone

import httpx

MODE = os.environ.get("PORTAL_MODE", "mock")
MCSM_URL = os.environ.get("MCSM_URL", "http://10.70.70.20:23333")
MCSM_CTRL_KEY = os.environ.get("MCSM_CTRL_KEY", "")
MCSM_INSTANCE = os.environ.get("MCSM_INSTANCE_NICK", "Fabric-MC")
MOCK_ACTION = os.environ.get("PORTAL_MOCK_GAME_ACTION", "ok")  # ok | fail | offline
ALLOW_IPS = {ip.strip() for ip in
             os.environ.get("PORTAL_GAME_ALLOW_IPS", "192.168.40.4").split(",") if ip.strip()}

# 白名單三動作(不含 kill;kill=強殺,對映 MCSM /kill,刻意不暴露)
ACTIONS: dict[str, dict] = {
    "open":    {"desc": "啟動伺服器"},
    "stop":    {"desc": "停止伺服器", "danger": "線上玩家會被斷線"},
    "restart": {"desc": "重啟伺服器", "danger": "線上玩家會被短暫斷線"},
}

_TIMEOUT = httpx.Timeout(20.0, connect=5.0)
# 單飛:實例級全域鎖——任一控制動作在飛就 409(stop 與 restart 同時到=終態不確定,
# 審查確認項:不能只按 action 字串去重)。進程內 set,單 worker 有效;
# uvicorn 若加 --workers 需改共享鎖(現行 Dockerfile 單進程)。
_inflight: set[str] = set()
_LOCK = "instance"  # 只管一個實例,固定鍵=全域互斥


class GameCtrlError(Exception):
    """帶 HTTP 狀態碼的控制錯誤,main.py 統一折成 {error,hint}。"""

    def __init__(self, status: int, error: str, hint: str = ""):
        super().__init__(error)
        self.status, self.error, self.hint = status, error, hint


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def enabled() -> bool:
    """控制功能是否已配置(mock 恆 true;live 需 MCSM_CTRL_KEY)。"""
    return MODE == "mock" or bool(MCSM_CTRL_KEY)


def allowed(remote_user: str | None, client_ip: str | None) -> bool:
    """本請求可否操作:portal.hl(Remote-User)或 PC40 來源 IP(Q2 裁決+審查修正)。"""
    if MODE == "mock":
        return True
    return bool(remote_user) or (client_ip in ALLOW_IPS)


def control_info(remote_user: str | None, client_ip: str | None) -> dict:
    """前端能力探測(零上游呼叫);併入 /api/game 回應。"""
    return {
        "enabled": enabled(),
        "allowed": enabled() and allowed(remote_user, client_ip),
        "actions": {k: {"desc": v["desc"], **({"danger": v["danger"]} if v.get("danger") else {})}
                    for k, v in ACTIONS.items()},
        "generated_at": _now(),
    }


async def _resolve_instance(client: httpx.AsyncClient) -> tuple[str, str]:
    """向 MCSM 解析受指派實例的 (instanceUuid, daemonId)——不吃前端傳入。"""
    r = await client.get(f"{MCSM_URL}/api/auth/",
                         params={"advanced": "true", "apikey": MCSM_CTRL_KEY},
                         headers={"X-Requested-With": "XMLHttpRequest"})
    if r.status_code in (401, 403):
        raise GameCtrlError(502, "MCSM 憑證失效(401/403)", "輪替 MCSM_CTRL_KEY(見 finish 腳本)")
    if r.status_code != 200:
        raise GameCtrlError(502, f"MCSM 回應異常(HTTP {r.status_code})", "檢查 CT201→MCSM :23333")
    insts = (r.json().get("data") or {}).get("instances") or []
    # 控制路徑嚴格認 nickname,不退回 insts[0]——面板改名/帳號被多指派時,
    # 靜默 fallback 會對非預期實例開停(審查確認項;唯讀路徑 live.py 保留寬鬆)
    inst = next((i for i in insts if i.get("nickname") == MCSM_INSTANCE), None)
    if inst is None:
        raise GameCtrlError(502, f"MCSM 無暱稱為 {MCSM_INSTANCE} 的實例指派",
                            "面板指派該實例給控制帳號;改過暱稱則同步 MCSM_INSTANCE_NICK")
    uuid, daemon = inst.get("instanceUuid"), inst.get("daemonId")
    if not uuid or not daemon:
        raise GameCtrlError(502, "MCSM 實例缺 uuid/daemonId", str(inst)[:120])
    return uuid, daemon


async def _mock_result(action: str, spec: dict) -> dict:
    """mock 模擬(PORTAL_MOCK_GAME_ACTION=ok|fail|offline)——UI 走查用。"""
    await asyncio.sleep(0.6)
    if MOCK_ACTION == "fail":
        raise GameCtrlError(502, "MCSM 動作未成功", f"mock:{spec['desc']}")
    if MOCK_ACTION == "offline":
        raise GameCtrlError(504, "MCSM 失聯(timeout)", "mock;動作可能仍在執行,見 MCSM 面板")
    return {"ok": True, "action": action, "desc": spec["desc"], "mock": True, "generated_at": _now()}


async def run(body: dict, remote_user: str | None, client_ip: str | None,
              xrw: str | None) -> tuple[int, dict]:
    """POST /api/game/action 主流程;回 (status, payload)。"""
    if not xrw:
        # 自訂 header 強制 CORS preflight——跨站惡意頁的簡單請求到不了這裡(CSRF 防護)
        raise GameCtrlError(403, "缺 X-Requested-With header", "請經 portal 頁面操作")
    if not allowed(remote_user, client_ip):
        raise GameCtrlError(403, "僅限 portal.hl 認證或 PC40 來源",
                            f"來源 {client_ip} 不在放行清單;手機請走 portal.hl")
    action = str(body.get("action", ""))
    spec = ACTIONS.get(action)
    if spec is None:
        raise GameCtrlError(403, "動作不在白名單", "僅 open/stop/restart(不含 kill/檔案/設定)")
    if not enabled():
        raise GameCtrlError(503, "控制功能未配置",
                            "portal.env 補 MCSM_CTRL_KEY 後 force-recreate portal")
    if _inflight:
        raise GameCtrlError(409, "已有控制動作執行中", "等前一發完成(實例級互斥)")
    _inflight.add(_LOCK)
    try:
        if MODE == "mock":
            return 200, await _mock_result(action, spec)
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            uuid, daemon = await _resolve_instance(client)
            try:
                r = await client.get(f"{MCSM_URL}/api/protected_instance/{action}",
                                     params={"apikey": MCSM_CTRL_KEY, "uuid": uuid,
                                             "daemonId": daemon},
                                     headers={"X-Requested-With": "XMLHttpRequest"})
            except httpx.TimeoutException:
                raise GameCtrlError(504, "MCSM 無回應(timeout)",
                                    "動作可能仍在執行,見 MCSM 面板或稍後重整")
            except httpx.HTTPError as e:
                raise GameCtrlError(504, "MCSM 連線失敗",
                                    f"{type(e).__name__};檢查 CT201→MCSM :23333")
        return _map_response(r, action, spec)
    finally:
        _inflight.discard(_LOCK)


def _map_response(r: httpx.Response, action: str, spec: dict) -> tuple[int, dict]:
    try:
        body = r.json()
    except ValueError:
        body = {}
    # MCSM 9.x 成功:HTTP 200 + {"status":200,"data":...}
    if r.status_code == 200 and body.get("status") == 200:
        return 200, {"ok": True, "action": action, "desc": spec["desc"], "generated_at": _now()}
    if r.status_code in (401, 403):
        raise GameCtrlError(502, "MCSM 拒絕請求",
                            "MCSM_CTRL_KEY 帳號需可操作實例(面板指派 Fabric-MC 並允許操作)")
    # MCSM 也可能 HTTP 200 但 status=500 帶錯誤字串
    msg = str(body.get("data") or body.get("message") or body)[:200]
    raise GameCtrlError(502, f"MCSM 動作未成功(HTTP {r.status_code})", msg or spec["desc"])
