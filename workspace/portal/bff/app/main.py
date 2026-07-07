"""Portal BFF —— 《入口大廳設計報告-3》§8 API 契約。

M0:PORTAL_MODE=mock,端點回 fixtures(generated_at 即時蓋章)。
M1:PORTAL_MODE=live,overview/alerts 改查 Prometheus/Alertmanager,brief 讀 data/brief.json。
唯讀原則:本服務不持有任何寫入能力;/api 之外一律回 SPA 靜態檔(history 路由 fallback)。
"""
import asyncio
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import providers

BASE = Path(__file__).resolve().parent
STATIC_DIR = Path(os.environ.get("PORTAL_STATIC", BASE.parent.parent / "frontend" / "dist"))
SSE_INTERVAL = int(os.environ.get("PORTAL_SSE_INTERVAL", "15"))

app = FastAPI(title="portal-bff", version="0.1.0", docs_url=None, redoc_url=None)


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


# M2 之後的端點:先出誠實的 stub(§11「留好路由與 stub」)
for _p in ("security", "power", "services", "game", "life"):
    async def _stub(_p=_p):
        return _err(501, f"/{_p} 屬 M2 範圍", "見入口大廳設計報告 §11")
    app.get(f"/api/{_p}")(_stub)


@app.get("/api/{rest:path}")
async def api_404(rest: str):
    return _err(404, f"無此端點:/api/{rest}")


# ---- SPA 靜態檔(必須放在 /api 之後註冊) ----
if STATIC_DIR.is_dir():
    app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")

    @app.get("/{path:path}")
    async def spa(path: str):
        f = STATIC_DIR / path
        if path and f.is_file():
            return FileResponse(f)
        return FileResponse(STATIC_DIR / "index.html")
