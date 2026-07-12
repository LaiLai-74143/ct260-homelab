#!/usr/bin/env python3
"""archive-svc: 拾遺歸檔服務(:5003,Bearer 驗證)——待辦49 拾遺板塊後端。

概念移植自 LYiHub/labs-ArchiveAssistant(GPL-3.0 Android app;本移植私有部署不散布):
六部分類(吏戶禮兵刑工)個人剪藏——portal BFF 轉發「URL 或純文字」進來:
  URL  → 抓網頁正文(stdlib HTMLParser;og:title 優先序+雜訊節點剔除+12000 字截斷)
  純文字 → 直接歸納
→ DeepSeek(DEEPSEEK_MODEL_FAST)單發歸納:限定六部 topicId+title≤28+summary≤96,
  嚴格 JSON 輸出(括號深度計數抽取,對抗 markdown 圍欄/前後綴)
→ SQLite 落地 ~/.local/state/archive-svc/archive.db(CT260 rootfs 隨 pve24 夜間 vzdump)。

安全邊界:Bearer token(BFF 專用,獨立於 life-chat 可獨立輪替)、/create 限速 6/分+單飛
(DeepSeek 保護)、URL 只收 http/https。使用者=屋主本人(PC40 直達+portal.hl Authelia),
內網 URL 抓取(SSRF 面)屬屋主自用工具,接受;真邊界=防火牆 host-scoped 放行+token。

設定(chmod 600):~/.config/homelab/archive.env
  ARCHIVE_TOKEN / ARCHIVE_PORT(5003) / ARCHIVE_MODEL(選填,預設 DEEPSEEK_MODEL_FAST)
  另讀 ~/.config/homelab/deepseek.env(DEEPSEEK_API_KEY/BASE_URL/MODEL_FAST,notifier 同源)

0190:邸報(auto RSS 呈報)——items 加 origin(manual=手動剪藏/rss=邸報)、score(門下省
重要性 1-10)、feed(來源名)三欄;dibao-ingest.py(FreshRSS→DeepSeek 批次歸納評分)
經 /ingest 批次寫入;晨報 top-7 由 homelab-notify.py 查 /list?origin=rss&sort=score。
rss 舊件 /ingest 時順手清(ARCHIVE_RSS_RETENTION_DAYS,預設 14 天;已「准」收編成
manual 的不清)。

端點:
  GET  /health                      免驗證(Kuma/BFF 探活;回 rev+count)
  GET  /list?topic=&q=&limit=&origin=&sort=&since_hours=  Bearer  摘要列表(不含 full_text)
  GET  /item?id=               Bearer  單篇全文
  GET  /stats                  Bearer  L0 卡片(manual_total/rss_today/by_topic/last)
  POST /create                 Bearer  {"input": str, "source_url"?: str}(手動剪藏)
  POST /ingest                 Bearer  {"items": [{source_url,feed,title,summary,topic_id,score,...}]}
  POST /update                 Bearer  {"id", "topic_id"?/"title"?/"summary"?/"origin"?="manual"(准)}
  POST /delete                 Bearer  {"id": str}
"""
import hmac
import json
import os
import re
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HOME = Path(os.path.expanduser("~"))
CONFIG_FILES = [
    HOME / ".config/homelab/archive.env",
    HOME / ".config/homelab/deepseek.env",
]
STATE_DIR = HOME / ".local/state/archive-svc"
LOG_FILE = STATE_DIR / "archive-svc.log"
DB_FILE = STATE_DIR / "archive.db"

# 服務版本標記(/health 回報):finish 腳本靠它判定跑著的程序要不要重啟(照 life-chat)
SERVICE_REV = "0190b"

# 六部(概念沿用原 app SixMinistry;收錄範圍改為個人/homelab 導向)
TOPICS = {
    "officials": "吏·名籍",
    "treasury": "戶·府庫",
    "rites": "禮·典章",
    "military": "兵·行令",
    "justice": "刑·稽核",
    "works": "工·營造",
}
TOPIC_SCOPE = {
    "officials": "人物、帳號身分、組織、聯絡、人事",
    "treasury": "財務、帳單、購物比價、資產、優惠",
    "rites": "知識文章、教學、文化、閱讀、典藏",
    "military": "行動計畫、任務、攻略、操作步驟",
    "justice": "資安、稽核、法規、風險、故障覆盤",
    "works": "工程、程式、硬體、家居、DIY",
}
# 模型答非所問時的保底(原 app resolveTopicId fallback=戶;個人剪藏多為文章,改禮·典章)
FALLBACK_TOPIC = "rites"

MAX_INPUT = 60000        # 純文字輸入/正文存檔上限(原 app MAX_EXTRACTED_CHARS)
MAX_PAGE_TEXT = 12000    # 網頁正文截斷(原 app MAX_BODY_TEXT_LENGTH)
MAX_PROMPT_CTX = 8000    # 送進 prompt 的內容上限(fast 模型,節制)
MAX_HTML_BYTES = 2_000_000
FETCH_TIMEOUT = 15
LLM_TIMEOUT = 60
MAX_BODY = 262144        # HTTP body 上限(60k 中文 UTF-8≈180KB,留餘裕)
RATE_MAX = 6             # /create 每 60s 上限

_rate_lock = threading.Lock()
_rate_window: list[float] = []
_create_lock = threading.Lock()  # 單飛:一次一筆抓取+歸納
_db_lock = threading.Lock()
_conn: sqlite3.Connection | None = None


def log(msg):
    ts = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass
    print(line, file=sys.stderr)


def load_config():
    cfg = {}
    for cf in CONFIG_FILES:
        if not cf.exists():
            continue
        for raw in cf.read_text().splitlines():
            raw = raw.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                continue
            k, v = raw.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


CFG = load_config()


def rate_ok():
    now = time.time()
    with _rate_lock:
        while _rate_window and now - _rate_window[0] > 60:
            _rate_window.pop(0)
        if len(_rate_window) >= RATE_MAX:
            return False
        _rate_window.append(now)
        return True


def rate_refund():
    """退還一個限速名額:限速護的是 DeepSeek,抓取失敗(422)沒花到模型就不該計費。"""
    with _rate_lock:
        if _rate_window:
            _rate_window.pop()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# ---------- SQLite ----------
SCHEMA = """CREATE TABLE IF NOT EXISTS items(
  id TEXT PRIMARY KEY, topic_id TEXT NOT NULL, content_type TEXT NOT NULL,
  title TEXT NOT NULL, summary TEXT NOT NULL, full_text TEXT NOT NULL,
  source_url TEXT, source_title TEXT, truncated INTEGER NOT NULL DEFAULT 0,
  model TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)"""

# 0190 邸報三欄:對既有庫用 ALTER 遷移(見 _migrate),新庫由 ALTER 同樣補上
MIGRATE_COLS = (
    ("origin", "TEXT NOT NULL DEFAULT 'manual'"),  # manual=手動剪藏 rss=邸報
    ("score", "INTEGER"),                          # 門下省重要性 1-10(rss 才有)
    ("feed", "TEXT"),                              # 來源名(rss 才有)
)

BRIEF_COLS = ("id", "topic_id", "content_type", "title", "summary", "source_url",
              "created_at", "origin", "score", "feed")
FULL_COLS = BRIEF_COLS + ("source_title", "full_text", "truncated", "model", "updated_at")

VALID_ORIGINS = ("manual", "rss")


def _row_full(iid: str) -> dict | None:
    with _db_lock:
        r = _conn.execute(f"SELECT {','.join(FULL_COLS)} FROM items WHERE id=?", (iid,)).fetchone()
    if r is None:
        return None
    d = dict(zip(FULL_COLS, r))
    d["truncated"] = bool(d["truncated"])
    return d


# ---------- 網頁抓取(語意照原 app WebPageContentFetcher,stdlib 重寫) ----------
SKIP_TAGS = {"script", "style", "noscript", "nav", "header", "footer", "aside",
             "form", "svg", "iframe", "template"}
BLOCK_TAGS = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5",
              "section", "article", "blockquote", "pre"}


class _Extract(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.skip = 0
        self.parts: list[str] = []
        self.title = ""
        self.h1 = ""
        self._in_title = False
        self._in_h1 = False
        self.meta: dict[str, str] = {}

    def handle_starttag(self, tag, attrs):
        if tag in SKIP_TAGS:
            self.skip += 1
        elif tag == "meta":
            a = dict(attrs)
            key = (a.get("property") or a.get("name") or "").lower()
            if key and a.get("content"):
                self.meta.setdefault(key, a["content"])
        elif tag == "title":
            self._in_title = True
        elif tag == "h1" and not self.h1:
            self._in_h1 = True
        if tag in BLOCK_TAGS and not self.skip:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in SKIP_TAGS and self.skip:
            self.skip -= 1
        elif tag == "title":
            self._in_title = False
        elif tag == "h1":
            self._in_h1 = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        elif self._in_h1:
            self.h1 += data
        if not self.skip:
            self.parts.append(data)


def _squeeze(s: str) -> str:
    return re.sub(r"\s+", " ", s or "").strip()


def _norm_text(s: str) -> str:
    s = re.sub(r"[ \t\r\f\v]+", " ", s)
    s = re.sub(r" ?\n ?", "\n", s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()


def fetch_page(url: str) -> dict:
    """回 {title, description, body, final_url, truncated};失敗丟 ValueError(422 級)。"""
    if urlsplit(url).scheme not in ("http", "https"):
        raise ValueError("只收 http/https URL")
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) ShiYi/1.0",
        "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5",
        "Accept-Language": "zh-TW,zh;q=0.9,en;q=0.6",
    })
    try:
        with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as r:
            ctype = r.headers.get("Content-Type", "")
            if "html" not in ctype.lower():
                raise ValueError(f"非 HTML 內容(Content-Type: {ctype.split(';')[0] or '?'})")
            raw = r.read(MAX_HTML_BYTES)
            final_url = r.geturl()
    except urllib.error.HTTPError as e:
        raise ValueError(f"抓取失敗:HTTP {e.code}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise ValueError(f"抓取失敗:{str(getattr(e, 'reason', e))[:120]}")
    m = re.search(r"charset=([\w-]+)", ctype)
    charset = m.group(1) if m else None
    if not charset:
        head = raw[:4096].decode("ascii", "ignore")
        m = re.search(r'charset=["\']?([\w-]+)', head, re.I)
        charset = m.group(1) if m else "utf-8"
    try:
        html = raw.decode(charset, "replace")
    except LookupError:
        html = raw.decode("utf-8", "replace")
    p = _Extract()
    try:
        p.feed(html)
        p.close()
    except Exception:  # noqa: BLE001 — 壞 HTML:能抽多少算多少
        pass
    body = _norm_text("".join(p.parts))
    meta = p.meta
    title = _squeeze(meta.get("og:title") or meta.get("twitter:title") or p.title or p.h1)
    desc = _squeeze(meta.get("description") or meta.get("og:description")
                    or meta.get("twitter:description"))
    return {"title": title[:300], "description": desc[:500],
            "body": body[:MAX_PAGE_TEXT], "final_url": final_url,
            "truncated": len(body) > MAX_PAGE_TEXT}


# ---------- DeepSeek 歸納(prompt 樣板沿原 app RemoteApiSmartSummarizer) ----------
def _prompt(kind: str, text: str, page: dict | None, source_url: str | None) -> str:
    six = "\n".join(f"- id={tid};{TOPICS[tid]};收錄:{TOPIC_SCOPE[tid]}" for tid in TOPICS)
    parts = ["你是歸檔助手,請歸納以下內容並分類。topicId 必須是下列六部 ID 之一,"
             "禁止創建新主題或返回主題名稱。", ""]
    if kind == "web":
        cut = page["truncated"] or len(page["body"]) > MAX_PROMPT_CTX
        parts += [f"原始 URL:{source_url}",
                  f"網頁標題:{page['title'] or '(無)'}",
                  f"網頁描述:{page['description'] or '(無)'}",
                  f"網頁正文{'(已截斷,禁止腦補未提供內容)' if cut else ''}:",
                  page["body"][:MAX_PROMPT_CTX] or "(抽不到正文)", "",
                  "要求:title 與 summary 必須基於正文/標題/描述,禁止只根據 URL 猜測。"]
    else:
        cut = len(text) > MAX_PROMPT_CTX
        parts += [f"使用者純文字輸入{'(已截斷,只能基於可見節選總結)' if cut else ''}:",
                  text[:MAX_PROMPT_CTX]]
    parts += ["", "六部主題:", six, "",
              "title ≤ 28 個中文字;summary ≤ 96 個中文字;一律使用繁體中文(zh-TW)。",
              "只返回嚴格 JSON 物件,不要 Markdown、不要解釋、不要額外欄位:",
              '{"topicId":"...","title":"...","summary":"..."}']
    return "\n".join(parts)


def extract_json_object(text: str) -> dict:
    """括號深度計數抽第一個完整 JSON 物件(考慮字串/跳脫;先剝 ``` 圍欄)——原 app 同款防呆。"""
    t = re.sub(r"```(?:json)?", "", text)
    start = t.find("{")
    while start != -1:
        depth, i, in_str, esc = 0, start, False, False
        while i < len(t):
            ch = t[i]
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
            else:
                if ch == '"':
                    in_str = True
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        try:
                            obj = json.loads(t[start:i + 1])
                            if isinstance(obj, dict):
                                return obj
                        except ValueError:
                            pass
                        break
            i += 1
        start = t.find("{", start + 1)
    raise ValueError("模型輸出中找不到合法 JSON 物件")


def _deepseek(prompt: str) -> tuple[str, str, float]:
    base = (CFG.get("DEEPSEEK_BASE_URL") or "").rstrip("/")
    key = CFG.get("DEEPSEEK_API_KEY")
    model = CFG.get("ARCHIVE_MODEL") or CFG.get("DEEPSEEK_MODEL_FAST") or CFG.get("DEEPSEEK_MODEL")
    if not (base and key and model):
        raise RuntimeError("DeepSeek 未配置(檢查 ~/.config/homelab/deepseek.env)")
    # max_tokens 需含 reasoning 預算:v4-flash 思考會吃掉太小的上限回空 content
    # (homelab-notify 踩坑 2026-07-09/10;單篇輸出小,2000 綽綽有餘)
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": 2000, "temperature": 0.3, "stream": False}).encode()
    req = urllib.request.Request(f"{base}/chat/completions", data=body, headers={
        "Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=LLM_TIMEOUT) as r:
            j = json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read(300).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            pass
        raise RuntimeError(f"DeepSeek HTTP {e.code}: {detail[:200]}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise RuntimeError(f"DeepSeek 連線失敗:{str(getattr(e, 'reason', e))[:120]}")
    try:
        content = j["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise RuntimeError(f"DeepSeek 回應形狀異常:{str(j)[:200]}")
    return str(content), model, round(time.time() - t0, 1)


def classify(kind: str, text: str, page: dict | None, source_url: str | None):
    content, model, secs = _deepseek(_prompt(kind, text, page, source_url))
    obj = extract_json_object(content)
    topic = obj.get("topicId")
    if topic not in TOPICS:
        log(f"classify fallback: topicId={str(topic)[:40]!r} -> {FALLBACK_TOPIC}")
        topic = FALLBACK_TOPIC
    title = _squeeze(str(obj.get("title") or ""))[:60]
    summary = _squeeze(str(obj.get("summary") or ""))[:200]
    if not title:  # 模型漏欄位:退回來源標題/原文開頭,不擺空
        title = _squeeze((page and page["title"]) or text)[:28] or "(未命名)"
    if not summary:
        summary = _squeeze((page and page["description"]) or text)[:96]
    return topic, title, summary, model, secs


# ---------- HTTP ----------
class Handler(BaseHTTPRequestHandler):
    server_version = "archive-svc/1.0"
    protocol_version = "HTTP/1.1"
    timeout = 30  # socket 讀 timeout(body 最大 256KB 內網秒到;處理耗時不吃這個)

    def _reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass

    def _authed(self) -> bool:
        auth = self.headers.get("Authorization", "")
        tok = CFG.get("ARCHIVE_TOKEN", "")
        if tok and hmac.compare_digest(auth, "Bearer " + tok):
            return True
        # keep-alive 下 body 沒讀就早退會汙染同連線下一請求 → 直接關連線
        self.close_connection = True
        log(f"DENY auth src={self.client_address[0]} path={self.path.split('?')[0]}")
        self._reply(401, {"ok": False, "error": "unauthorized"})
        return False

    def _auth_body(self):
        if not self._authed():
            return None
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n < 0 or n > MAX_BODY:
                raise ValueError("bad content-length")
            body = json.loads(self.rfile.read(n).decode() or "{}")
            if not isinstance(body, dict):
                raise ValueError("body 非物件")
            return body
        except Exception:  # noqa: BLE001
            self.close_connection = True  # body 可能沒讀完,同上不留髒連線
            log(f"DENY bad-body src={self.client_address[0]} path={self.path}")
            self._reply(400, {"ok": False, "error": "bad request"})
            return None

    # ---- GET ----
    def do_GET(self):
        path, _, query = self.path.partition("?")
        qs = parse_qs(query)
        if path == "/health":
            with _db_lock:
                n = _conn.execute("SELECT COUNT(*) FROM items").fetchone()[0]
            self._reply(200, {"ok": True, "rev": SERVICE_REV, "count": n})
        elif path == "/list":
            if self._authed():
                self._list(qs)
        elif path == "/item":
            if self._authed():
                self._item(qs)
        elif path == "/stats":
            if self._authed():
                self._stats()
        else:
            self.close_connection = True  # 404 早退可能沒讀 body,同 401/400 關連線
            self._reply(404, {"ok": False, "error": "not found"})

    def _list(self, qs):
        topic = (qs.get("topic") or [None])[0]
        q = (qs.get("q") or [None])[0]
        origin = (qs.get("origin") or [None])[0]
        sort = (qs.get("sort") or ["created"])[0]
        try:
            limit = min(500, max(1, int((qs.get("limit") or ["200"])[0])))
        except ValueError:
            limit = 200
        try:
            # 上限一年:無界大值會讓 fromtimestamp 下溢 year<1 拋 ValueError 斷線(審查修正)
            since_hours = max(0, min(24 * 366, int((qs.get("since_hours") or ["0"])[0])))
        except ValueError:
            since_hours = 0
        if topic and topic not in TOPICS:
            self._reply(400, {"ok": False, "error": "topic 不在六部"})
            return
        if origin and origin not in VALID_ORIGINS:
            self._reply(400, {"ok": False, "error": "origin 須為 manual|rss"})
            return
        if sort not in ("created", "score"):
            self._reply(400, {"ok": False, "error": "sort 須為 created|score"})
            return
        where, args = [], []
        if topic:
            where.append("topic_id=?")
            args.append(topic)
        if origin:
            where.append("origin=?")
            args.append(origin)
        if since_hours:
            cutoff = datetime.fromtimestamp(time.time() - since_hours * 3600,
                                            tz=timezone.utc).isoformat()
            where.append("created_at>=?")
            args.append(cutoff)
        if q:
            # 字面 substring 比對(% _ 逃逸),與 BFF mock 語意一致
            esc = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            where.append(r"(title LIKE ? ESCAPE '\' OR summary LIKE ? ESCAPE '\')")
            args += [f"%{esc}%", f"%{esc}%"]
        sql = f"SELECT {','.join(BRIEF_COLS)} FROM items"
        if where:
            sql += " WHERE " + " AND ".join(where)
        order = ("score DESC, created_at DESC" if sort == "score" else "created_at DESC")
        sql += f" ORDER BY {order} LIMIT ?"
        args.append(limit)
        # total/by_topic 跟隨 origin 篩選(邸報/剪藏各算各的);未給 origin=全庫
        cnt_where = " WHERE origin=?" if origin else ""
        cnt_args = [origin] if origin else []
        with _db_lock:
            rows = _conn.execute(sql, args).fetchall()
            total = _conn.execute(f"SELECT COUNT(*) FROM items{cnt_where}", cnt_args).fetchone()[0]
            by = dict(_conn.execute(
                f"SELECT topic_id, COUNT(*) FROM items{cnt_where} GROUP BY topic_id", cnt_args).fetchall())
        self._reply(200, {"ok": True, "items": [dict(zip(BRIEF_COLS, r)) for r in rows],
                          "total": total, "by_topic": {t: by.get(t, 0) for t in TOPICS}})

    def _item(self, qs):
        iid = (qs.get("id") or [""])[0]
        d = _row_full(iid) if iid else None
        if d is None:
            self._reply(404, {"ok": False, "error": "無此條目"})
            return
        self._reply(200, {"ok": True, "item": d})

    def _stats(self):
        today = datetime.fromtimestamp(time.time() - 24 * 3600, tz=timezone.utc).isoformat()
        with _db_lock:
            manual_total = _conn.execute(
                "SELECT COUNT(*) FROM items WHERE origin='manual'").fetchone()[0]
            rss_today = _conn.execute(
                "SELECT COUNT(*) FROM items WHERE origin='rss' AND created_at>=?", (today,)).fetchone()[0]
            by = dict(_conn.execute(
                "SELECT topic_id, COUNT(*) FROM items WHERE origin='manual' GROUP BY topic_id").fetchall())
            last = _conn.execute(
                "SELECT title, created_at FROM items WHERE origin='manual' "
                "ORDER BY created_at DESC LIMIT 1").fetchone()
        self._reply(200, {"ok": True, "manual_total": manual_total, "rss_today": rss_today,
                          "by_topic": {t: by.get(t, 0) for t in TOPICS},
                          "last": {"title": last[0], "created_at": last[1]} if last else None})

    # ---- POST ----
    def do_POST(self):
        if self.path == "/create":
            self._create()
        elif self.path == "/ingest":
            self._ingest()
        elif self.path == "/update":
            self._update()
        elif self.path == "/delete":
            self._delete()
        else:
            self.close_connection = True  # 未知路徑 body 未讀,關連線防汙染(審查修正)
            self._reply(404, {"ok": False, "error": "not found"})

    def _ingest(self):
        """邸報批次寫入(dibao-ingest.py 專用):項目已在 ingest 端歸納+評分完畢,
        這裡只驗形+source_url 去重+落地;順手清過期 rss 舊件(已收編 manual 的不清)。"""
        body = self._auth_body()
        if body is None:
            return
        items = body.get("items")
        if not (isinstance(items, list) and 0 < len(items) <= 200):
            self._reply(400, {"ok": False, "error": "items 須為 1–200 筆陣列"})
            return
        now = _now()
        inserted, skipped, rejected = 0, 0, []
        with _db_lock:
            for idx, it in enumerate(items):
                if not isinstance(it, dict):
                    rejected.append(f"#{idx}: 非物件")
                    continue
                url = it.get("source_url")
                topic = it.get("topic_id")
                score = it.get("score")
                title = _squeeze(str(it.get("title") or ""))[:60]
                summary = _squeeze(str(it.get("summary") or ""))[:200]
                feed = _squeeze(str(it.get("feed") or ""))[:60]
                if not (isinstance(url, str) and url.startswith(("http://", "https://"))):
                    rejected.append(f"#{idx}: source_url 非 http(s)")
                    continue
                if topic not in TOPICS or not isinstance(score, int) \
                        or isinstance(score, bool) or not 1 <= score <= 10 \
                        or not title or not summary:
                    rejected.append(f"#{idx}: 欄位不合法")
                    continue
                if _conn.execute("SELECT 1 FROM items WHERE source_url=?", (url,)).fetchone():
                    skipped += 1
                    continue
                # created_at=入庫時間(邸報「當日」=這班送達的;原文 published 可能是
                # 舊文新貼,拿來當 created_at 會讓晨報 since_hours=24 誤殺高分件)
                _conn.execute(
                    "INSERT INTO items(id,topic_id,content_type,title,summary,full_text,"
                    "source_url,source_title,truncated,model,created_at,updated_at,"
                    "origin,score,feed) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (uuid.uuid4().hex[:12], topic, "web", title, summary,
                     str(it.get("full_text") or summary)[:MAX_INPUT], url, title, 0,
                     str(it.get("model") or "")[:60] or None, now, now, "rss", score, feed))
                inserted += 1
            days = max(1, int(CFG.get("ARCHIVE_RSS_RETENTION_DAYS", "14")))
            cutoff = datetime.fromtimestamp(time.time() - days * 86400, tz=timezone.utc).isoformat()
            purged = _conn.execute(
                "DELETE FROM items WHERE origin='rss' AND created_at<?", (cutoff,)).rowcount
            _conn.commit()
        log(f"INGEST inserted={inserted} skipped={skipped} rejected={len(rejected)} purged={purged}")
        self._reply(200, {"ok": True, "inserted": inserted, "skipped": skipped,
                          "rejected": rejected[:20], "purged": purged})

    def _create(self):
        body = self._auth_body()
        if body is None:
            return
        raw = body.get("input")
        if not (isinstance(raw, str) and raw.strip()):
            self._reply(400, {"ok": False, "error": "input 須為非空字串"})
            return
        raw = raw.strip()
        if len(raw) > MAX_INPUT:
            self._reply(400, {"ok": False, "error": f"input 過長(>{MAX_INPUT} 字)"})
            return
        src = body.get("source_url")
        if src is not None and not isinstance(src, str):
            self._reply(400, {"ok": False, "error": "source_url 須為字串"})
            return
        url = None
        if src and src.strip():
            url = src.strip()
        elif re.fullmatch(r"https?://\S+", raw):
            url = raw  # 輸入本身就是一條 URL → 走網頁剪藏
        if not _create_lock.acquire(blocking=False):
            self._reply(409, {"ok": False, "error": "上一筆收藏仍在歸檔中"})
            return
        try:
            if not rate_ok():  # 鎖後才計費:409 不吃名額
                self._reply(429, {"ok": False, "error": "rate limited(6 次/分)"})
                return
            page, kind = None, "text"
            if url:
                kind = "web"
                try:
                    page = fetch_page(url)
                except ValueError as e:
                    rate_refund()  # 沒碰到 DeepSeek,退還名額
                    self._reply(422, {"ok": False, "error": str(e)})
                    return
            try:
                topic, title, summary, model, secs = classify(kind, raw, page, url)
            except (RuntimeError, ValueError) as e:
                log(f"CREATE FAIL classify: {e}")
                self._reply(502, {"ok": False, "error": f"AI 歸納失敗:{str(e)[:200]}"})
                return
            now = _now()
            iid = uuid.uuid4().hex[:12]
            full_text = (page["body"] if page else raw)[:MAX_INPUT]
            with _db_lock:
                _conn.execute(
                    "INSERT INTO items(id,topic_id,content_type,title,summary,full_text,"
                    "source_url,source_title,truncated,model,created_at,updated_at) "
                    "VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                    (iid, topic, kind, title, summary, full_text, url,
                     page["title"] if page else None,
                     int(bool(page and page["truncated"])), model, now, now))
                _conn.commit()
            log(f"CREATE {iid} kind={kind} topic={topic} secs={secs} title={title[:40]!r}")
            self._reply(200, {"ok": True, "item": _row_full(iid)})
        finally:
            _create_lock.release()

    def _update(self):
        body = self._auth_body()
        if body is None:
            return
        iid = body.get("id")
        if not (isinstance(iid, str) and iid):
            self._reply(400, {"ok": False, "error": "缺 id"})
            return
        sets, args = [], []
        topic = body.get("topic_id")
        if topic is not None:
            if topic not in TOPICS:
                self._reply(400, {"ok": False, "error": "topic_id 不在六部"})
                return
            sets.append("topic_id=?")
            args.append(topic)
        origin = body.get("origin")
        if origin is not None:
            if origin != "manual":  # 只開放「准」:rss 收編入庫;不提供反向降級
                self._reply(400, {"ok": False, "error": "origin 只收 manual(准=收編)"})
                return
            sets.append("origin=?")
            args.append(origin)
        for k, cap in (("title", 120), ("summary", 300)):
            v = body.get(k)
            if v is not None:
                if not (isinstance(v, str) and 0 < len(v.strip()) <= cap):
                    self._reply(400, {"ok": False, "error": f"{k} 須為 1–{cap} 字元字串"})
                    return
                sets.append(f"{k}=?")
                args.append(v.strip())
        if not sets:
            self._reply(400, {"ok": False, "error": "沒有可更新欄位(topic_id/title/summary/origin)"})
            return
        sets.append("updated_at=?")
        args += [_now(), iid]
        with _db_lock:
            cur = _conn.execute(f"UPDATE items SET {','.join(sets)} WHERE id=?", args)
            _conn.commit()
        if cur.rowcount == 0:
            self._reply(404, {"ok": False, "error": "無此條目"})
            return
        log(f"UPDATE {iid} fields={[s.split('=')[0] for s in sets[:-1]]}")
        self._reply(200, {"ok": True, "item": _row_full(iid)})

    def _delete(self):
        body = self._auth_body()
        if body is None:
            return
        iid = body.get("id")
        if not (isinstance(iid, str) and iid):
            self._reply(400, {"ok": False, "error": "缺 id"})
            return
        with _db_lock:
            cur = _conn.execute("DELETE FROM items WHERE id=?", (iid,))
            _conn.commit()
        if cur.rowcount == 0:
            self._reply(404, {"ok": False, "error": "無此條目"})
            return
        log(f"DELETE {iid}")
        self._reply(200, {"ok": True})


def main():
    global _conn
    if not CFG.get("ARCHIVE_TOKEN"):
        log("missing ARCHIVE_TOKEN in ~/.config/homelab/archive.env; aborting")
        sys.exit(1)
    if not (CFG.get("DEEPSEEK_API_KEY") and CFG.get("DEEPSEEK_BASE_URL")):
        log("missing DEEPSEEK_API_KEY/BASE_URL(deepseek.env); aborting")
        sys.exit(1)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    _conn = sqlite3.connect(DB_FILE, check_same_thread=False)
    _conn.execute(SCHEMA)
    have = {r[1] for r in _conn.execute("PRAGMA table_info(items)")}
    for name, decl in MIGRATE_COLS:  # 0190 邸報遷移:冪等,舊庫補欄不動資料
        if name not in have:
            _conn.execute(f"ALTER TABLE items ADD COLUMN {name} {decl}")
            log(f"migrate: items ADD COLUMN {name}")
    _conn.commit()
    port = int(CFG.get("ARCHIVE_PORT", "5003"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    model = CFG.get("ARCHIVE_MODEL") or CFG.get("DEEPSEEK_MODEL_FAST") or CFG.get("DEEPSEEK_MODEL")
    log(f"archive-svc listening :{port} rev={SERVICE_REV} model={model} db={DB_FILE}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
