"""數據提供層:mock(fixtures)/ live(Prometheus/AM/Loki/Kuma + 檔案投遞)。

快取照報告 §4/§8 全部 3–10s(逐端點 TTL);失敗 negative cache 30s
——上游持續失聯時不逐 tick 重打吃滿 timeout(M2 §3)。
life/brief 為 CT260 推送的本地檔(推不是拉);power 於 nut_exporter 部署前回 pending 誠實態。
"""
import asyncio
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

MODE = os.environ.get("PORTAL_MODE", "mock")
BASE = Path(__file__).resolve().parent
FIXTURES = BASE / "fixtures"
DATA_DIR = Path(os.environ.get("PORTAL_DATA", BASE.parent / "data"))

# 逐端點 TTL(秒):全部落在報告規定的 3–10s
TTL = {"overview": 5, "alerts": 5, "services": 10, "security": 10,
       "game": 10, "host": 10, "life": 5, "power": 10}
NEG_TTL = float(os.environ.get("PORTAL_NEG_TTL", "30"))

_cache: dict[str, tuple[float, dict]] = {}
_neg: dict[str, tuple[float, str]] = {}
_inflight: dict[str, "asyncio.Task"] = {}


class UpstreamError(Exception):
    pass


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _cached(key: str):
    hit = _cache.get(key)
    ttl = TTL.get(key.split(":")[0], 5)
    if hit and time.monotonic() - hit[0] < ttl:
        return hit[1]
    return None


def _store(key: str, val: dict) -> dict:
    _cache[key] = (time.monotonic(), val)
    _neg.pop(key, None)
    return val


def _neg_check(key: str) -> None:
    hit = _neg.get(key)
    if hit and time.monotonic() - hit[0] < NEG_TTL:
        raise UpstreamError(hit[1])
    if hit:
        _neg.pop(key, None)


def _neg_store(key: str, err: Exception) -> None:
    _neg[key] = (time.monotonic(), str(err))


def _fixture(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


async def _get(key: str, live_call, fixture: str | None = None):
    """快取 + negative cache + single-flight 統一入口;mock 模式讀 fixture。

    TTL(3–10s,報告 §8)刻意小於 SSE_INTERVAL(15s):SSE tick 本身就是刷新器,
    快取+single-flight 服務的是「多裝置同時開」——同 key 併發只打上游一次。
    """
    if (c := _cached(key)) is not None:
        return c
    if MODE == "mock":
        d = _fixture(fixture or key)
        d["generated_at"] = _now()
        return _store(key, d)
    _neg_check(key)
    if (fut := _inflight.get(key)) is not None:
        return await asyncio.shield(fut)  # 跟隨者共享同一次上游呼叫
    fut = asyncio.ensure_future(live_call())
    _inflight[key] = fut
    try:
        return _store(key, await fut)
    except UpstreamError as e:
        _neg_store(key, e)
        raise
    finally:
        _inflight.pop(key, None)


async def get_overview() -> dict:
    async def _build() -> dict:
        from . import live
        ov = await live.overview()
        ov["modules"] = await _modules()
        ov["services_ok"] = _services_ok()
        return ov
    return await _get("overview", _build)


async def get_alerts() -> dict:
    from . import live
    return await _get("alerts", live.alerts)


async def get_services() -> dict:
    from . import live
    return await _get("services", live.services)


async def get_security() -> dict:
    from . import live
    return await _get("security", live.security)


async def get_game() -> dict:
    from . import live
    return await _get("game", live.game)


async def get_host(slug: str) -> dict:
    from . import live
    if MODE == "mock":
        d = _fixture("host")
        d["slug"], d["generated_at"] = slug, _now()
        return d
    return await _get(f"host:{slug}", lambda: live.host_detail(slug), fixture="host")


async def get_power() -> dict:
    # 電力(待辦49 決策2 落地 2026-07-08):pve24 upsc→textfile→Prometheus;
    # 指標缺席/過期由 live.power 回 pending 誠實態,不隱藏、不擺假數據
    if MODE == "mock":
        d = _fixture("power")
        d["generated_at"] = _now()
        return d
    from . import live
    return await _get("power", live.power)


def _life_file() -> Path:
    return DATA_DIR / "life.json"


def _redact_life(d: dict) -> dict:
    """兩層詳略(待辦49 決策:生活隱私):未經 portal.hl Authelia 的請求
    只回時間+件數,不露行程標題與借貸淨額——降低 :8088 無認證面的個資暴露。
    非安全邊界(直達者仍可偽造 header),但把「隨手瀏覽/掃描」擋在標題外。"""
    out = dict(d)
    if isinstance(d.get("calendar_today"), list):
        out["calendar_today"] = [{"time": e.get("time", ""), "title": None}
                                 for e in d["calendar_today"] if isinstance(e, dict)]
    if isinstance(d.get("calendar_upcoming"), list):
        out["calendar_upcoming"] = [{"date": e.get("date", ""), "time": e.get("time", ""), "title": None}
                                    for e in d["calendar_upcoming"] if isinstance(e, dict)]
    if isinstance(d.get("debts_open"), dict):
        # 未認證只露件數:淨額抹除、逐人明細(對象/金額)整組不出
        out["debts_open"] = {"count": d["debts_open"].get("count", 0), "total": None,
                             "persons": None}
    out["redacted"] = True
    return out


async def get_life(authed: bool = False) -> dict:
    if MODE == "mock":
        d = _fixture("life")
        d["generated_at"] = _now()
        return d if authed else _redact_life(d)
    f = _life_file()
    if not f.is_file():
        return {"pending": True,
                "hint": "等 CT260 投遞 life.json(hl-write-life cron),或手動觸發",
                "generated_at": _now()}
    try:
        d = json.loads(f.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise UpstreamError(f"life.json 損壞: {e}") from e
    # 誠實面對舊資料:超過 2h 標 stale,由前端顯示「資料時間」而非裝新
    try:
        gen = datetime.fromisoformat(d.get("generated_at", "").replace("Z", "+00:00"))
        d["stale_seconds"] = max(0, int((datetime.now(timezone.utc) - gen).total_seconds()))
    except ValueError:
        d["stale_seconds"] = None
    return d if authed else _redact_life(d)


async def get_brief(d: str = "today") -> dict:
    if MODE == "mock":
        return _fixture("brief")
    name = "brief.json" if d == "today" else f"brief-{d.replace('-', '')}.json"
    f = DATA_DIR / name
    if not f.is_file():
        raise FileNotFoundError(name)
    try:
        return json.loads(f.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise UpstreamError(f"brief.json 損壞: {e}") from e


# ---------------- L0 卡面聚合(M2 §2:重用各端點快取,逐源 timeout,單源慢不拖垮 overview) ----------------

def _services_ok() -> dict | None:
    """從 services 快取(含 TTL 檢查)算綠燈比例;Kuma 未接/快取過期時 None(卡面誠實待接)。"""
    hit = _cached("services")
    if hit is None:
        return None
    vals = [i["kuma_ok"] for g in hit["groups"] for i in g["items"] if i["kuma_ok"] is not None]
    if not vals:
        return None
    return {"ok": sum(1 for v in vals if v), "total": len(vals)}


async def _one_module(key: str, coro) -> dict:
    """單卡聚合:3s 上限,取數與組裝任何一步失敗都回誠實 unk 卡,不拖垮 overview
    (life.json 屬外部投遞檔,形狀不可信——組裝也必須在防護傘內)。"""
    try:
        d = await asyncio.wait_for(coro, timeout=3.0)
        return _render_module(key, d)
    except Exception:  # noqa: BLE001
        return {"key": key, "big": "—", "sub": "讀取失敗", "state": "unk"}


def _render_module(key: str, d: dict) -> dict:
    if key == "services":
        ok = _services_ok()
        if ok is None:
            return {"key": key, "big": "—", "sub": d.get("kuma_note") or "綠燈待接", "state": "unk"}
        st = "ok" if ok["ok"] == ok["total"] else "warn"
        return {"key": key, "big": str(ok["ok"]), "bigUnit": f"/{ok['total']}",
                "sub": "Kuma 綠燈", "state": st}
    if key == "security":
        cow = d["cowrie"]
        cow_txt = "Cowrie 源停機" if cow.get("offline") else f"Cowrie 今日 {cow.get('count', 0)}"
        trip = d["tripwire"]
        st = "warn" if trip["today"] > 0 else "ok"
        return {"key": key, "big": str(d["autoban_today"]), "bigUnit": " 封鎖",
                "sub": f"絆線今日 {trip['today']} · {cow_txt}", "state": st}
    if key == "game":
        stt = "ok" if d["server_up"] else ("unk" if d["instance_state"] == "stopped" else "warn")
        big = "—" if d["players_online"] is None else str(d["players_online"])
        unit = "" if d["players_online"] is None else " 在線"
        sub = ("MC " + ("運行中" if d["server_up"] else d["instance_state"])
               + (" · 玩家數待接" if d["players_online"] is None else ""))
        return {"key": key, "big": big, "bigUnit": unit, "sub": sub, "state": stt}
    if key == "life":
        if d.get("pending"):
            return {"key": key, "big": "—", "sub": "待 CT260 投遞", "state": "unk"}
        n = len(d.get("calendar_today") or [])
        debts = d.get("debts_open") or {}
        stale = d.get("stale_seconds")
        # 投遞中斷(>2h)不裝正常:卡面降級 warn 並帶時戳,呼應 Life 頁 stale banner
        if isinstance(stale, (int, float)) and stale > 7200:
            hrs = int(stale // 3600)
            return {"key": key, "big": str(n), "bigUnit": " 行程",
                    "sub": f"資料 {hrs}h 前——投遞可能中斷", "state": "warn"}
        return {"key": key, "big": str(n), "bigUnit": " 行程",
                "sub": f"借貸未結 {debts.get('count', 0)} 筆", "state": "ok"}
    if key == "power":
        if d.get("pending"):
            return {"key": key, "big": "—", "sub": "數據源未接(nut_exporter)", "state": "unk"}
        st = "crit" if d.get("on_battery") else "ok"
        return {"key": key, "big": "電池" if d.get("on_battery") else "市電",
                "sub": f"電池 {d.get('charge', '—')}% · 負載 {d.get('load', '—')}%", "state": st}
    return {"key": key, "big": "—", "sub": "?", "state": "unk"}


async def _modules() -> list[dict]:
    return list(await asyncio.gather(
        _one_module("services", get_services()),
        _one_module("security", get_security()),
        _one_module("power", get_power()),
        _one_module("game", get_game()),
        _one_module("life", get_life()),
    ))
