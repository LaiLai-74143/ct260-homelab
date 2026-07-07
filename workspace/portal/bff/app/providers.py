"""數據提供層:mock(fixtures)/ live(Prometheus + Alertmanager + brief.json)。

live 模式 M1 實作;快取 3–10s(§8),十個裝置同開,上游只被打一次。
"""
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

MODE = os.environ.get("PORTAL_MODE", "mock")
BASE = Path(__file__).resolve().parent
FIXTURES = BASE / "fixtures"
DATA_DIR = Path(os.environ.get("PORTAL_DATA", BASE.parent / "data"))

CACHE_TTL = float(os.environ.get("PORTAL_CACHE_TTL", "5"))
_cache: dict[str, tuple[float, dict]] = {}


class UpstreamError(Exception):
    pass


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _cached(key: str):
    hit = _cache.get(key)
    if hit and time.monotonic() - hit[0] < CACHE_TTL:
        return hit[1]
    return None


def _store(key: str, val: dict) -> dict:
    _cache[key] = (time.monotonic(), val)
    return val


def _fixture(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


async def get_overview() -> dict:
    if (c := _cached("overview")) is not None:
        return c
    if MODE == "mock":
        d = _fixture("overview")
        d["generated_at"] = _now()
        return _store("overview", d)
    from . import live
    return _store("overview", await live.overview())


async def get_alerts() -> dict:
    if (c := _cached("alerts")) is not None:
        return c
    if MODE == "mock":
        d = _fixture("alerts")
        d["generated_at"] = _now()
        return _store("alerts", d)
    from . import live
    return _store("alerts", await live.alerts())


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
