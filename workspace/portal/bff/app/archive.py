"""拾遺歸檔轉發層(0.18.0 待辦49 拾遺板塊,2026-07-11)。

六部(吏戶禮兵刑工)個人剪藏——概念移植自 LYiHub/labs-ArchiveAssistant。
GET/POST /api/archive* → CT260 archive-svc(:5003,SQLite+網頁抓取+DeepSeek 歸納)。
本層不做抓取、不呼叫模型、不落地任何資料(唯讀 BFF 原則不破);
半徑受 archive-svc 端 Bearer token+限速 6/分+單飛封頂。
權限照 game_ctrl 先例(使用者裁決 2026-07-08 同款):PC40 直達與 portal.hl 皆可寫
(剪藏非破壞性動作;PC40 放行為 host-scoped、portal.hl 有 Authelia),
ARCHIVE_AUTH=remote-user 可收緊回「僅 portal.hl」。
"""
import asyncio
import os
import uuid
from datetime import datetime, timezone

import httpx

MODE = os.environ.get("PORTAL_MODE", "mock")
ARCHIVE_AUTH = os.environ.get("ARCHIVE_AUTH", "open")  # open | remote-user
ARCHIVE_URL = os.environ.get("ARCHIVE_URL", "")
ARCHIVE_TOKEN = os.environ.get("ARCHIVE_TOKEN", "")

_READ_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
_WRITE_TIMEOUT = httpx.Timeout(20.0, connect=5.0)
# stats 必須 < providers._one_module 的 3s:讓「svc 掛住」以 ArchiveError 收場
# → UpstreamError → 負快取生效;否則 wait_for 取消不進負快取,每個 overview 白等 3s
_STATS_TIMEOUT = httpx.Timeout(2.5, connect=1.5)
# create=抓取 15s+LLM 60s 串行,對齊 life_chat 的 150s 上限(前端 postJson 130s 先斷)
_CREATE_TIMEOUT = httpx.Timeout(150.0, connect=5.0)

# 六部字典(SoT=CT260 archive-svc TOPICS;此處僅 mock 與提示用,勿加第七部)
TOPICS = {
    "officials": "吏·名籍", "treasury": "戶·府庫", "rites": "禮·典章",
    "military": "兵·行令", "justice": "刑·稽核", "works": "工·營造",
}


class ArchiveError(Exception):
    def __init__(self, status: int, error: str, hint: str = ""):
        super().__init__(error)
        self.status, self.error, self.hint = status, error, hint


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def enabled() -> bool:
    return MODE == "mock" or bool(ARCHIVE_URL and ARCHIVE_TOKEN)


def allowed(remote_user: str | None) -> bool:
    return ARCHIVE_AUTH != "remote-user" or bool(remote_user)


def _gate(remote_user: str | None, write: bool) -> None:
    if write and not allowed(remote_user):
        raise ArchiveError(403, "僅限經 portal.hl 認證的請求", "此部署已收緊 ARCHIVE_AUTH=remote-user")
    if MODE != "mock" and not enabled():
        raise ArchiveError(503, "拾遺歸檔未配置",
                           "portal.env 補 ARCHIVE_URL/ARCHIVE_TOKEN 後 force-recreate")


async def _req(method: str, path: str, *, params: dict | None = None,
               payload: dict | None = None, timeout: httpx.Timeout) -> httpx.Response:
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            return await client.request(
                method, f"{ARCHIVE_URL}{path}", params=params, json=payload,
                headers={"Authorization": f"Bearer {ARCHIVE_TOKEN}"})
    except httpx.TimeoutException:
        raise ArchiveError(504, "archive-svc 無回應(timeout)",
                           "抓取+AI 歸納可能仍在跑;或檢查 CT260 :5003")
    except httpx.HTTPError as e:
        raise ArchiveError(504, "archive-svc 連線失敗",
                           f"{type(e).__name__};檢查 CT260 :5003 或 OpenWrt Allow-Monitor-To-CT260-Archive-5003")


def _map(r: httpx.Response, fallback: str) -> dict:
    try:
        body = r.json()
    except ValueError:
        body = {}
    if r.status_code == 200 and body.get("ok"):
        return body
    if r.status_code == 401:
        raise ArchiveError(502, "archive-svc 拒絕(token 不符)", "檢查 portal.env ARCHIVE_TOKEN")
    if r.status_code in (400, 404, 409, 422, 429):
        raise ArchiveError(r.status_code, str(body.get("error") or fallback)[:200],
                           "稍候一分鐘再試" if r.status_code == 429 else "")
    raise ArchiveError(502, f"{fallback}(HTTP {r.status_code})",
                       str(body.get("error") or "")[:200])


def _decorate(body: dict, remote_user: str | None) -> dict:
    return {**body, "enabled": enabled(), "allowed": allowed(remote_user),
            "generated_at": _now()}


async def list_items(topic: str | None, q: str | None, origin: str | None,
                     sort: str | None, remote_user: str | None) -> dict:
    _gate(remote_user, write=False)
    if topic is not None and topic not in TOPICS:  # 與 svc 行為對齊,mock 也 400
        raise ArchiveError(400, "topic 不在六部", "")
    if origin is not None and origin not in ("manual", "rss"):
        raise ArchiveError(400, "origin 須為 manual|rss", "")
    if sort is not None and sort not in ("created", "score"):
        raise ArchiveError(400, "sort 須為 created|score", "")
    if MODE == "mock":
        return _decorate(_mock_list(topic, q, origin, sort), remote_user)
    params: dict = {}
    if topic:
        params["topic"] = topic
    if q:
        params["q"] = q
    if origin:
        params["origin"] = origin
    if sort:
        params["sort"] = sort
    r = await _req("GET", "/list", params=params, timeout=_READ_TIMEOUT)
    return _decorate(_map(r, "列表讀取異常"), remote_user)


async def get_item(item_id: str, remote_user: str | None) -> dict:
    _gate(remote_user, write=False)
    if MODE == "mock":
        return _decorate(_mock_item(item_id), remote_user)
    r = await _req("GET", "/item", params={"id": item_id}, timeout=_READ_TIMEOUT)
    return _decorate(_map(r, "條目讀取異常"), remote_user)


async def create(body: dict, remote_user: str | None) -> dict:
    _gate(remote_user, write=True)
    raw = body.get("input")
    if not (isinstance(raw, str) and 0 < len(raw.strip()) <= 60000):
        raise ArchiveError(400, "input 須為 1–60000 字元字串", "貼 URL 或一段文字")
    src = body.get("source_url")
    if src is not None and not isinstance(src, str):
        raise ArchiveError(400, "source_url 須為字串", "")
    if MODE == "mock":
        await asyncio.sleep(0.8)
        return _decorate(_mock_create(raw.strip()), remote_user)
    payload = {"input": raw.strip()}
    if src and src.strip():
        payload["source_url"] = src.strip()
    r = await _req("POST", "/create", payload=payload, timeout=_CREATE_TIMEOUT)
    return _decorate(_map(r, "收藏歸檔異常"), remote_user)


async def update(item_id: str, body: dict, remote_user: str | None) -> dict:
    # origin 只收 manual(准=邸報收編入庫),svc 端同樣把關
    _gate(remote_user, write=True)
    fields = {k: body[k] for k in ("topic_id", "title", "summary", "origin") if k in body}
    if not fields:
        raise ArchiveError(400, "沒有可更新欄位(topic_id/title/summary/origin)", "")
    if MODE == "mock":
        return _decorate(_mock_update(item_id, fields), remote_user)
    r = await _req("POST", "/update", payload={"id": item_id, **fields}, timeout=_WRITE_TIMEOUT)
    return _decorate(_map(r, "更新異常"), remote_user)


async def delete(item_id: str, remote_user: str | None) -> dict:
    _gate(remote_user, write=True)
    if MODE == "mock":
        return _decorate(_mock_delete(item_id), remote_user)
    r = await _req("POST", "/delete", payload={"id": item_id}, timeout=_WRITE_TIMEOUT)
    return _decorate(_map(r, "刪除異常"), remote_user)


async def stats() -> dict:
    """L0 卡片用(providers._modules);未配置回 pending 誠實態,不丟例外。"""
    if MODE == "mock":
        return _mock_stats()
    if not enabled():
        return {"pending": True}
    r = await _req("GET", "/stats", timeout=_STATS_TIMEOUT)
    return _map(r, "統計讀取異常")


# ---------------- mock(UI 走查;程序記憶體態,重啟即還原) ----------------

def _mk(iid, topic, kind, title, summary, url, days_ago, full,
        origin="manual", score=None, feed=None):
    ts = datetime.now(timezone.utc).timestamp() - days_ago * 86400
    iso = datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()
    return {"id": iid, "topic_id": topic, "content_type": kind, "title": title,
            "summary": summary, "source_url": url, "created_at": iso,
            "source_title": title if url else None, "full_text": full,
            "truncated": False, "model": "mock", "updated_at": iso,
            "origin": origin, "score": score, "feed": feed}


_mock_items: list[dict] = [
    _mk("m01", "works", "web", "LXC 裡跑 Docker 的 keyctl 坑",
        "unprivileged CT 需開 features: keyctl=1,nesting=1;否則 dockerd 起不來。附 pct set 範例。",
        "https://example.com/lxc-docker", 0.2,
        "在 Proxmox unprivileged LXC 內跑 Docker,需要 keyctl 與 nesting 兩個 feature……(mock 正文)"),
    _mk("m02", "rites", "web", "SQLite WAL 模式白皮書重點",
        "WAL 讓讀寫不互鎖,checkpoint 時機與 busy_timeout 是兩個關鍵旋鈕;單機服務幾乎無腦開。",
        "https://example.com/sqlite-wal", 1.5,
        "SQLite WAL(Write-Ahead Logging)模式……(mock 正文)"),
    _mk("m03", "justice", "text", "CtdmzGateDown 告警覆盤筆記",
        "閘門表載入失敗已封成 fail-closed;殘餘窗口=運行中手動刪表,靠 ctdmz_gate_up 兜底。",
        None, 3,
        "2026-07-10 之後 ctdmz-nft 與 tailscaled 綁定……(mock 正文)"),
    _mk("m04", "treasury", "web", "UPS 電池更換價格盤點",
        "CP1500 原廠電池 RBP0086 行情約 NT$2,200;副廠 12V9Ah×2 約半價,注意端子規格 F2。",
        "https://example.com/ups-battery", 6,
        "CyberPower CP1500 系列電池更換選項……(mock 正文)"),
    _mk("m05", "military", "text", "DXP 斷電關機 10 分鐘驗證步驟",
        "UGOS UI 改 10 分後,拔線 10 秒微測,回讀 ups_tool.log 應出現 seconds: 600 才算數。",
        None, 8,
        "1. UGOS UI 電源管理改自動關機延遲……(mock 正文)"),
    _mk("m06", "officials", "web", "Authelia 使用者檔案格式備忘",
        "users.yml 的 argon2id 雜湊生成命令與 displayname/groups 欄位;改完要 restart 才生效。",
        "https://example.com/authelia-users", 12,
        "Authelia file backend 的 users.yml……(mock 正文)"),
    # 邸報樣本(0.19.0:origin=rss,score=門下省評分,feed=來源;created_at=送達時間;
    # 0.19.1 起 full_text 帶【AI 導讀】——r01 照 dibao-ingest v2 格式供走查)
    _mk("r01", "justice", "web", "GhostLock:潛伏 15 年的 Linux 漏洞",
        "所有主流發行版受影響的堆疊釋放後使用漏洞,已有 PoC,修補程式陸續釋出。",
        "https://example.com/ghostlock", 0.05,
        "【AI 導讀】GhostLock 是 glibc 一處存在 15 年的堆疊釋放後使用漏洞,影響所有主流"
        "發行版,已有公開 PoC。(背景)此類 UAF 可被用於本地提權,建議儘速套用發行版修補。"
        "\n\n原題:GhostLock: a 15-year-old use-after-free in glibc\n\n"
        "(邸報存 AI 導讀與節選,非全文;原文發布 2026-07-12 03:10;全文見原文連結)",
        "rss", 9, "Hacker News"),
    _mk("r02", "works", "web", "OpenAI 推語音模型 GPT-Live",
        "新一代語音模型可即時聆聽回應並適時插話,對話更接近真人交流。",
        "https://example.com/gpt-live", 0.1,
        "GPT-Live 發表……(mock 節選)", "rss", 8, "TechNews"),
    _mk("r03", "treasury", "web", "記憶體短缺恐推高手機售價",
        "元件供應緊張,多家品牌下一代旗艦機價格看漲。",
        "https://example.com/dram-price", 0.2,
        "記憶體市況……(mock 節選)", "rss", 6, "TechNews"),
    _mk("r04", "rites", "web", "青銅時代晚期崩潰簡史",
        "多重壓力如何在數十年內終結地中海文明圈的一篇概論。",
        "https://example.com/bronze-age", 0.3,
        "青銅時代晚期……(mock 節選)", "rss", 5, "Hacker News"),
]

_MOCK_KEYWORDS = [  # 極簡假分類器(照原 app MockKnowledgeClassifier 思路)
    (("密碼", "帳號", "人物", "聯絡"), "officials"),
    (("價", "買", "帳單", "資產"), "treasury"),
    (("計畫", "步驟", "任務", "攻略"), "military"),
    (("安全", "漏洞", "稽核", "風險"), "justice"),
    (("程式", "硬體", "DIY", "工程", "docker", "Docker"), "works"),
]


def _brief(d: dict) -> dict:
    return {k: d[k] for k in ("id", "topic_id", "content_type", "title",
                              "summary", "source_url", "created_at",
                              "origin", "score", "feed")}


def _mock_list(topic: str | None, q: str | None, origin: str | None,
               sort: str | None) -> dict:
    pool = [i for i in _mock_items if not origin or i["origin"] == origin]
    items = [i for i in pool
             if (not topic or i["topic_id"] == topic)
             and (not q or q.lower() in (i["title"] + i["summary"]).lower())]
    if sort == "score":
        items.sort(key=lambda i: (i["score"] or 0, i["created_at"]), reverse=True)
    else:
        items.sort(key=lambda i: i["created_at"], reverse=True)
    by: dict[str, int] = {t: 0 for t in TOPICS}
    for i in pool:
        by[i["topic_id"]] += 1
    return {"ok": True, "items": [_brief(i) for i in items],
            "total": len(pool), "by_topic": by}


def _mock_item(item_id: str) -> dict:
    for i in _mock_items:
        if i["id"] == item_id:
            return {"ok": True, "item": dict(i)}
    raise ArchiveError(404, "無此條目", "")


def _mock_create(raw: str) -> dict:
    topic = "rites"
    for keys, t in _MOCK_KEYWORDS:
        if any(k in raw for k in keys):
            topic = t
            break
    is_url = raw.startswith(("http://", "https://")) and " " not in raw
    item = _mk(uuid.uuid4().hex[:12], topic, "web" if is_url else "text",
               (raw.replace("https://", "").replace("http://", "")[:28] or "(未命名)"),
               f"(mock)已歸入{TOPICS[topic]};live 模式由 DeepSeek 歸納標題與摘要。",
               raw if is_url else None, 0, raw)
    _mock_items.append(item)
    return {"ok": True, "item": dict(item), "mock": True}


def _mock_update(item_id: str, fields: dict) -> dict:
    for i in _mock_items:
        if i["id"] == item_id:
            for k, v in fields.items():
                if k == "topic_id" and v not in TOPICS:
                    raise ArchiveError(400, "topic_id 不在六部", "")
                if k == "origin" and v != "manual":
                    raise ArchiveError(400, "origin 只收 manual(准=收編)", "")
                if isinstance(v, str) and v.strip():
                    i[k] = v.strip()
            i["updated_at"] = _now()
            return {"ok": True, "item": dict(i), "mock": True}
    raise ArchiveError(404, "無此條目", "")


def _mock_delete(item_id: str) -> dict:
    for i in list(_mock_items):
        if i["id"] == item_id:
            _mock_items.remove(i)
            return {"ok": True, "mock": True}
    raise ArchiveError(404, "無此條目", "")


def _mock_stats() -> dict:
    manual = [i for i in _mock_items if i["origin"] == "manual"]
    by: dict[str, int] = {t: 0 for t in TOPICS}
    for i in manual:
        by[i["topic_id"]] += 1
    newest = max(manual, key=lambda i: i["created_at"], default=None)
    day_ago = datetime.fromtimestamp(datetime.now(timezone.utc).timestamp() - 86400,
                                     tz=timezone.utc).isoformat()
    return {"ok": True, "manual_total": len(manual),
            "rss_today": sum(1 for i in _mock_items
                             if i["origin"] == "rss" and i["created_at"] >= day_ago),
            "by_topic": by,
            "last": {"title": newest["title"], "created_at": newest["created_at"]} if newest else None}
