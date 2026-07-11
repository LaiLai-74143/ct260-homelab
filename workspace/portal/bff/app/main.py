"""Portal BFF —— 《入口大廳設計報告-3》§8 API 契約(+M2 補充,見 docs/M2-架構.md §3)。

M0:PORTAL_MODE=mock,端點回 fixtures(generated_at 即時蓋章)。
M1:PORTAL_MODE=live,overview/alerts 查 Prometheus/Alertmanager,brief 讀 data/brief.json。
M2:services/security/game/host 接真數據;life 讀 CT260 推送檔;power 於 exporter 就緒前回 pending。
唯讀原則:本服務不持有任何寫入能力;/api 之外一律回 SPA 靜態檔(history 路由 fallback)。
"""
import asyncio
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import actions, game_ctrl, grafana_proxy, life_chat, providers

BASE = Path(__file__).resolve().parent
STATIC_DIR = Path(os.environ.get("PORTAL_STATIC", BASE.parent.parent / "frontend" / "dist"))
SSE_INTERVAL = int(os.environ.get("PORTAL_SSE_INTERVAL", "15"))

app = FastAPI(title="portal-bff", version="0.13.0", docs_url=None, redoc_url=None)


def _err(status: int, error: str, hint: str = "") -> JSONResponse:
    return JSONResponse({"error": error, "hint": hint}, status_code=status)


@app.get("/api/health")
async def health():
    return {"ok": True, "mode": providers.MODE, "time": datetime.now(timezone.utc).isoformat()}


@app.get("/api/overview")
async def overview():
    try:
        return await providers.get_overview()
    except providers.UpstreamError as e:
        return _err(502, "上游查詢失敗", str(e))


@app.get("/api/alerts")
async def alerts():
    try:
        return await providers.get_alerts()
    except providers.UpstreamError as e:
        return _err(502, "上游查詢失敗", str(e))


@app.get("/api/brief")
async def brief(d: str = "today"):
    try:
        return await providers.get_brief(d)
    except FileNotFoundError:
        return _err(404, "該期晨報不存在", "等 CT260 06:00 投遞,或手動 --write-brief")
    except providers.UpstreamError as e:
        return _err(502, "晨報讀取失敗", str(e))


@app.get("/api/services")
async def services():
    # M2 §3:靜態表永遠可回;Kuma 失聯只反映在 kuma_ok=null + kuma_note
    try:
        return await providers.get_services()
    except providers.UpstreamError as e:
        return _err(502, "服務目錄組裝失敗", str(e))


@app.get("/api/security")
async def security():
    try:
        return await providers.get_security()
    except providers.UpstreamError as e:
        return _err(502, "上游查詢失敗", str(e))


@app.get("/api/power")
async def power():
    try:
        return await providers.get_power()
    except providers.UpstreamError as e:
        return _err(502, "上游查詢失敗", str(e))


@app.get("/api/game")
async def game(request: Request):
    try:
        data = await providers.get_game()
        # control 能力(env-static,零上游)併入;不污染 get_game 快取本體
        return {**data, "control": game_ctrl.control_info(
            request.headers.get("Remote-User"),
            request.client.host if request.client else None)}
    except providers.UpstreamError as e:
        return _err(502, "上游查詢失敗", str(e))


@app.post("/api/game/action")
async def game_action(request: Request):
    # 走 MCSM protected_instance 優雅開/停/重啟(非殺 Java 進程);uuid 由 BFF 自解析
    try:
        body = await request.json()
        if not isinstance(body, dict):
            raise ValueError("body 非物件")
    except Exception:  # noqa: BLE001
        return _err(400, "body 須為 JSON 物件", '{"action": "open|stop|restart"}')
    try:
        status, payload = await game_ctrl.run(
            body,
            request.headers.get("Remote-User"),
            request.client.host if request.client else None,
            request.headers.get("X-Requested-With"))
        return JSONResponse(payload, status_code=status)
    except game_ctrl.GameCtrlError as e:
        return _err(e.status, e.error, e.hint)


@app.get("/api/life")
async def life(request: Request):
    # 兩層詳略:portal.hl 經 Caddy forward_auth 會帶 Remote-User;直達 :8088 無此 header
    # → 只回時間+件數。非認證鐵律(直達者可偽造 header),僅調內容詳略,portal 不做存取控管。
    authed = bool(request.headers.get("Remote-User"))
    try:
        return await providers.get_life(authed)
    except providers.UpstreamError as e:
        return _err(502, "生活數據讀取失敗", str(e))


@app.get("/api/host/{slug}")
async def host(slug: str):
    try:
        return await providers.get_host(slug)
    except KeyError:
        return _err(404, f"無此主機:{slug}", "見 /api/overview hosts[].slug")
    except providers.UpstreamError as e:
        return _err(502, "上游查詢失敗", str(e))


@app.get("/api/stream")
async def stream():
    """SSE:每 SSE_INTERVAL 秒推 overview,alerts 變化即推(§4)。"""
    async def gen():
        last_alerts = ""
        while True:
            try:
                ov = await providers.get_overview()
                yield f"event: overview\ndata: {json.dumps(ov, ensure_ascii=False)}\n\n"
                al = await providers.get_alerts()
                key = json.dumps(al.get("firing"), ensure_ascii=False, sort_keys=True)
                if key != last_alerts:
                    last_alerts = key
                    yield f"event: alerts\ndata: {json.dumps(al, ensure_ascii=False)}\n\n"
            except providers.UpstreamError:
                yield "event: lag\ndata: {}\n\n"
            await asyncio.sleep(SSE_INTERVAL)
    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# ---- M3 動作(待辦49;唯一寫入方向端點,轉發 CT260 webhook 白名單,見 actions.py) ----

@app.get("/api/actions")
async def actions_info(request: Request):
    return actions.actions_info(request.headers.get("Remote-User"))


@app.post("/api/action")
async def action(request: Request):
    # body 手動驗(不用 Pydantic 模型):維持全站 {error,hint} 錯誤格式,不引入 422
    try:
        body = await request.json()
        if not isinstance(body, dict):
            raise ValueError("body 非物件")
    except Exception:  # noqa: BLE001
        return _err(400, "body 須為 JSON 物件", '{"action": "...", "param": "..."}')
    try:
        status, payload = await actions.run(body, request.headers.get("Remote-User"))
        return JSONResponse(payload, status_code=status)
    except actions.ActionError as e:
        return _err(e.status, e.error, e.hint)


# ---- 生活助理(待辦49;Sonnet 5 唯讀工具+提案單→確認執行,見 life_chat.py) ----

@app.get("/api/life/chat")
async def life_chat_info(request: Request):
    return life_chat.info(request.headers.get("Remote-User"))


@app.post("/api/life/chat")
async def life_chat_post(request: Request):
    try:
        body = await request.json()
        if not isinstance(body, dict):
            raise ValueError("body 非物件")
    except Exception:  # noqa: BLE001
        return _err(400, "body 須為 JSON 物件", '{"messages": [{"role": "user", "content": "..."}]}')
    try:
        status, payload = await life_chat.chat(body, request.headers.get("Remote-User"))
        return JSONResponse(payload, status_code=status)
    except life_chat.ChatError as e:
        return _err(e.status, e.error, e.hint)


@app.post("/api/life/confirm")
async def life_confirm(request: Request):
    try:
        body = await request.json()
        if not isinstance(body, dict):
            raise ValueError("body 非物件")
    except Exception:  # noqa: BLE001
        return _err(400, "body 須為 JSON 物件", "提案五欄位原樣帶回:action/args/summary/ts/sig")
    try:
        status, payload = await life_chat.confirm(body, request.headers.get("Remote-User"))
        return JSONResponse(payload, status_code=status)
    except life_chat.ChatError as e:
        return _err(e.status, e.error, e.hint)


# ---- guest-portal 帳號管理(待辦50;生活頁面板,僅 portal.hl 經 Remote-User) ----

@app.get("/api/life/guest")
async def life_guest_list(request: Request):
    try:
        status, payload = await life_chat.guest({"op": "list"}, request.headers.get("Remote-User"))
        return JSONResponse(payload, status_code=status)
    except life_chat.ChatError as e:
        return _err(e.status, e.error, e.hint)


@app.post("/api/life/guest")
async def life_guest_op(request: Request):
    try:
        body = await request.json()
        if not isinstance(body, dict):
            raise ValueError("body 非物件")
    except Exception:  # noqa: BLE001
        return _err(400, "body 須為 JSON 物件", '{"op": "add", "login_id": "...", "person": "...", "password": "..."}')
    try:
        status, payload = await life_chat.guest(body, request.headers.get("Remote-User"))
        return JSONResponse(payload, status_code=status)
    except life_chat.ChatError as e:
        return _err(e.status, e.error, e.hint)


@app.get("/api/{rest:path}")
async def api_404(rest: str):
    return _err(404, f"無此端點:/api/{rest}")


# ---- Grafana 同源反代(0.8.1;圖表嵌入走 portal 網域,見 grafana_proxy.py) ----
#      放在 /api 之後、SPA 靜態之前;GET(頁面/資產)+POST(/api/ds/query 面板查詢)
@app.api_route("/grafana/{path:path}", methods=["GET", "POST"])
async def grafana(request: Request, path: str):
    return await grafana_proxy.proxy(request, path)


# ---- SPA 靜態檔(必須放在 /api 之後註冊) ----
if STATIC_DIR.is_dir():
    app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")

    @app.get("/{path:path}")
    async def spa(path: str):
        # 路徑穿越防護:resolve 後必須仍在 STATIC_DIR 下,否則一律回 SPA index
        base = STATIC_DIR.resolve()
        f = (STATIC_DIR / path).resolve()
        if path and f.is_relative_to(base) and f.is_file():
            return FileResponse(f)
        return FileResponse(STATIC_DIR / "index.html")
