#!/usr/bin/env python3
"""dibao-ingest: 邸報抓取歸納(待辦49 0.19.0)——FreshRSS → DeepSeek 批次歸納評分
→ archive-svc /ingest。靈感=林亦「三省六部」影片裡未開源的自動聚合管線。

一次 DeepSeek call 批 10 條,兼任:
  中書省=擬題(≤28 字去標題黨)+一句話摘要;分部=六部 topicId;
  門下省=重要性 1-10(同事件多篇只給一篇正常分,其餘壓低);
  0.19.1 加導讀 brief(80-160 字,節選只剩連結時用背景知識補脈絡)——
  閱讀器 full_text 不再只丟連結(使用者回饋)。
score ≥ DIBAO_MIN_SCORE(預設 5)才入庫呈御覽,其餘駁回只留計數;
晨報(homelab-notify --write-brief 06:00)自行查 /list?origin=rss&sort=score 取 top-7。

游標檔記 FreshRSS crawl 時間高水位,不動 FreshRSS 已讀態(不干擾使用者閱讀進度)。
cron:05:20 / 17:20 台北(flock 防重入,見 finish-dibao.sh)。

設定:~/.config/homelab/{archive.env,freshrss.env,deepseek.env}
  archive.env 可加:DIBAO_MIN_SCORE(5)/ DIBAO_MAX_ITEMS(120)/ DIBAO_BATCH(10)
用法:dibao-ingest.py [--dry-run] [--limit N](--dry-run 抓+歸納但不入庫,印結果)
"""
import html as htmllib
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
CONFIG_FILES = [
    HOME / ".config/homelab/archive.env",
    HOME / ".config/homelab/freshrss.env",
    HOME / ".config/homelab/deepseek.env",
]
STATE_DIR = HOME / ".local/state/archive-svc"
CURSOR_FILE = STATE_DIR / "dibao-cursor.json"
LOG_FILE = STATE_DIR / "dibao.log"

LLM_TIMEOUT = 90
SNIPPET_LEN = 300

TOPICS = ("officials", "treasury", "rites", "military", "justice", "works")

SYSTEM_PROMPT = """你是「邸報」編輯,兼任中書省與門下省。對輸入的每一條 RSS 訊息:
1. 中書省:擬繁體中文(zh-TW)標題(≤28 字,去標題黨、去驚嘆號)與一句話摘要
   (≤60 字,只基於提供的標題與節選,禁止腦補;摘要內禁用半形分號)。
2. 分部:從六部選最合適的 topicId:
   - officials(吏·名籍):人物、人事任免、組織、帳號身分
   - treasury(戶·府庫):財經、市場、消費、資產、價格
   - rites(禮·典章):科學、文化、知識、教育、藝文
   - military(兵·行令):時事行動、衝突、政策執行、賽事
   - justice(刑·稽核):資安、法規、司法、事故、風險
   - works(工·營造):科技、工程、產品、軟硬體開發
3. 門下省:重要性評分 1-10 整數(10=重大必知、8=值得一讀、5=一般、3 以下=雞肋/
   廣告/標題黨/純促銷)。同一事件多篇來源:只給資訊最完整的一篇正常分,其餘壓到 3 以下。
4. 導讀 brief:2-4 句繁中導讀,約 80-160 字——這在講什麼、核心內容或主張、為何值得注意。
   節選若資訊太少(例如只有連結),就用你對該主題的背景知識解釋名詞與脈絡,
   但不得虛構原文的具體數據與結論,背景推測以「(背景)」標明。
只返回嚴格 JSON 陣列,不要 markdown、不要解釋、不要額外欄位:
[{"i": <輸入編號>, "topicId": "...", "title": "...", "summary": "...", "score": <int>, "brief": "..."}]"""


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


def _strip_html(s: str) -> str:
    s = re.sub(r"<[^>]+>", " ", s or "")
    return re.sub(r"\s+", " ", htmllib.unescape(s)).strip()


# ---------- FreshRSS(greader API;client 寫法照 homelab-notify.py fetch_rss_unread) ----------
def fetch_new_items(since_epoch: int, limit: int) -> list[dict]:
    """拉 crawl 時間 > since 的項目(不分已讀未讀);回 [{feed,title,snippet,link,published,crawl}]。"""
    base = CFG["FRESHRSS_URL"].rstrip("/") + "/api/greader.php"
    q = urllib.parse.urlencode({"Email": CFG["FRESHRSS_USER"],
                                "Passwd": CFG["FRESHRSS_API_PASSWORD"]})
    r = urllib.request.urlopen(base + "/accounts/ClientLogin?" + q, timeout=15).read().decode()
    auth = dict(line.split("=", 1) for line in r.strip().splitlines())["Auth"]
    req = urllib.request.Request(
        base + "/reader/api/0/stream/contents/user/-/state/com.google/reading-list?"
        # r=o 舊到新:限量分頁時高水位=本頁最大 crawl 才不會跳過中間積壓
        + urllib.parse.urlencode({"ot": str(since_epoch), "n": str(limit),
                                  "r": "o", "output": "json"}),
        headers={"Authorization": "GoogleLogin auth=" + auth})
    d = json.loads(urllib.request.urlopen(req, timeout=30).read().decode())
    out = []
    for it in d.get("items", []):
        link = ""
        for k in ("canonical", "alternate"):
            arr = it.get(k) or []
            if arr and arr[0].get("href"):
                link = arr[0]["href"]
                break
        body = ((it.get("summary") or {}).get("content")
                or (it.get("content") or {}).get("content") or "")
        crawl_ms = int(it.get("crawlTimeMsec") or 0)
        out.append({
            "feed": _strip_html((it.get("origin") or {}).get("title") or "?")[:60],
            "title": _strip_html(it.get("title") or "")[:200],
            "snippet": _strip_html(body)[:SNIPPET_LEN],
            "link": link,
            "published": int(it.get("published") or 0),
            "crawl": crawl_ms // 1000 if crawl_ms else int(it.get("published") or 0),
        })
    return out


# ---------- DeepSeek 批次歸納(嚴格 JSON 陣列;v4-flash reasoning 吃預算→大上限+重試) ----------
def _deepseek(system: str, user: str, max_tokens: int = 9000) -> tuple[str, str]:
    base = (CFG.get("DEEPSEEK_BASE_URL") or "").rstrip("/")
    key = CFG.get("DEEPSEEK_API_KEY")
    model = CFG.get("DIBAO_MODEL") or CFG.get("DEEPSEEK_MODEL_FAST") or CFG.get("DEEPSEEK_MODEL")
    if not (base and key and model):
        raise RuntimeError("DeepSeek 未配置")
    body = json.dumps({"model": model,
                       "messages": [{"role": "system", "content": system},
                                    {"role": "user", "content": user}],
                       "max_tokens": max_tokens, "temperature": 0.3, "stream": False}).encode()
    req = urllib.request.Request(f"{base}/chat/completions", data=body, headers={
        "Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=LLM_TIMEOUT) as r:
        j = json.loads(r.read().decode("utf-8", "replace"))
    return str(j["choices"][0]["message"]["content"] or ""), model


def extract_json_array(text: str) -> list:
    """括號深度抽第一個完整 JSON 陣列(考慮字串/跳脫;剝 ``` 圍欄)。"""
    t = re.sub(r"```(?:json)?", "", text)
    start = t.find("[")
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
                elif ch == "[":
                    depth += 1
                elif ch == "]":
                    depth -= 1
                    if depth == 0:
                        try:
                            arr = json.loads(t[start:i + 1])
                            if isinstance(arr, list):
                                return arr
                        except ValueError:
                            pass
                        break
            i += 1
        start = t.find("[", start + 1)
    raise ValueError("模型輸出中找不到合法 JSON 陣列")


def classify_batch(batch: list[dict]) -> dict[int, dict]:
    """回 {批內編號: {topicId,title,summary,score}};單批失敗拋出讓上層記帳跳過。"""
    payload = json.dumps([{"i": n, "feed": it["feed"], "title": it["title"],
                           "snippet": it["snippet"]} for n, it in enumerate(batch)],
                         ensure_ascii=False)
    content, model = _deepseek(SYSTEM_PROMPT, payload)
    if not content.strip():  # reasoning 吃光預算回空 content(notify 踩坑)→重試一次
        content, model = _deepseek(SYSTEM_PROMPT, payload)
    out = {}
    for row in extract_json_array(content):
        if not isinstance(row, dict):
            continue
        n, topic, score = row.get("i"), row.get("topicId"), row.get("score")
        # 模型偶回 8.0(float):整數值浮點收下轉 int;bool 拒(審查修正)
        if isinstance(score, float) and score.is_integer():
            score = int(score)
        if isinstance(score, bool):
            score = None
        title = re.sub(r"\s+", " ", str(row.get("title") or "")).strip()[:60]
        summary = re.sub(r"\s+", " ", str(row.get("summary") or "")).strip()[:200]
        # brief 缺省不整筆拒(full_text 退回原題+節選,summary 才是硬需求)
        brief = re.sub(r"\s+", " ", str(row.get("brief") or "")).strip()[:600]
        if (isinstance(n, int) and 0 <= n < len(batch) and topic in TOPICS
                and isinstance(score, int) and 1 <= score <= 10 and title and summary):
            out[n] = {"topicId": topic, "title": title, "summary": summary,
                      "score": score, "brief": brief, "model": model}
    return out


def _fmt_epoch(sec: int) -> str:
    """epoch→本地 'YYYY-MM-DD HH:MM';0/損毀值(如 ms 級誤植)回 '?'——
    fromtimestamp 對超界值丟 ValueError,不設防會整輪崩潰且游標卡死(審查修正)。"""
    if not sec:
        return "?"
    try:
        return datetime.fromtimestamp(sec, tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")
    except (ValueError, OverflowError, OSError):
        return "?"


def _clean_snippet(snippet: str) -> str:
    """去 URL 後字母(含 CJK)不足 40 的節選視為無資訊(如 HN 只有連結串)→ 省略。"""
    s = re.sub(r"https?://\S+", "", snippet or "")
    s = re.sub(r"\s+", " ", s).strip(" ,;|·-")
    return s if sum(1 for ch in s if ch.isalpha()) >= 40 else ""


def build_full_text(orig_title: str, snippet: str, brief: str, published: str) -> str:
    """閱讀器正文:導讀在前,原題次之,節選有料才附(backfill 腳本共用本函式)。
    published 未知(''/'?')時省略發布段(bootstrap 舊件無此資訊)。"""
    parts = []
    if brief:
        parts.append(f"【AI 導讀】{brief}")
    parts.append(f"原題:{orig_title}")
    snip = _clean_snippet(snippet)
    if snip:
        parts.append(snip)
    pub = f"原文發布 {published};" if published and published != "?" else ""
    parts.append(f"(邸報存 AI 導讀與節選,非全文;{pub}全文見原文連結)")
    return "\n\n".join(parts)


# ---------- archive-svc /ingest ----------
def post_ingest(items: list[dict]) -> dict:
    port = CFG.get("ARCHIVE_PORT", "5003")
    body = json.dumps({"items": items}, ensure_ascii=False).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/ingest", data=body, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {CFG['ARCHIVE_TOKEN']}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def main():
    dry = "--dry-run" in sys.argv
    # env 空字串防呆:`or "預設"` 讓 int('') 不炸(審查修正)
    max_items = int(CFG.get("DIBAO_MAX_ITEMS") or "120")
    if "--limit" in sys.argv:
        try:
            max_items = int(sys.argv[sys.argv.index("--limit") + 1])
        except (IndexError, ValueError):
            print("用法:dibao-ingest.py [--dry-run] [--limit N]", file=sys.stderr)
            sys.exit(2)
    batch_size = max(1, min(20, int(CFG.get("DIBAO_BATCH") or "10")))
    min_score = max(1, min(10, int(CFG.get("DIBAO_MIN_SCORE") or "5")))
    for k in ("ARCHIVE_TOKEN", "FRESHRSS_URL", "FRESHRSS_API_PASSWORD", "DEEPSEEK_API_KEY"):
        if not CFG.get(k):
            log(f"missing {k}; aborting")
            sys.exit(1)

    try:
        cursor = int(json.loads(CURSOR_FILE.read_text()).get("ot", 0))
    except Exception:
        cursor = 0
    if not cursor:
        cursor = int(time.time()) - 86400  # 首跑:只看近 24h,不回灌整庫

    try:
        items = fetch_new_items(cursor, max_items)
    except Exception as e:  # noqa: BLE001
        log(f"freshrss 拉取失敗 {type(e).__name__}: {str(e)[:120]}")
        sys.exit(1)
    items = [it for it in items if it["link"] and it["title"]]
    if not items:
        log(f"no new items (cursor={cursor})")
        return

    # 游標語意(審查 P1 修正):批次失敗即停,游標只推進到失敗批之前——
    # 失敗批與其後的項目下輪重抓(已入庫者 dup-skip),不再靜默永久遺失
    kept, low, ai_fail = [], 0, 0
    stopped_at = None
    for off in range(0, len(items), batch_size):
        batch = items[off:off + batch_size]
        try:
            verdicts = classify_batch(batch)
        except Exception as e:  # noqa: BLE001
            ai_fail += len(items) - off
            stopped_at = batch[0]["crawl"]
            log(f"batch@{off} 歸納失敗 {type(e).__name__}: {str(e)[:120]}——本輪就此打住,游標停在失敗批前")
            break
        for n, it in enumerate(batch):
            v = verdicts.get(n)
            if v is None:
                ai_fail += 1
                continue
            if v["score"] < min_score:
                low += 1
                continue
            kept.append({
                "source_url": it["link"],
                "feed": it["feed"],
                "title": v["title"],
                "summary": v["summary"],
                "topic_id": v["topicId"],
                "score": v["score"],
                "model": v["model"],
                # created_at 由 svc 蓋入庫時間(邸報「當日」=送達日;原文發布時間僅留正文註記)
                "full_text": build_full_text(
                    it["title"], it["snippet"], v["brief"], _fmt_epoch(it["published"])),
            })

    if dry:
        log(f"DRY fetched={len(items)} kept={len(kept)} low={low} ai_fail={ai_fail}")
        print(json.dumps(kept, ensure_ascii=False, indent=1))
        return

    result = {"inserted": 0, "skipped": 0, "purged": 0}
    if kept:
        try:
            result = post_ingest(kept)
        except Exception as e:  # noqa: BLE001
            log(f"ingest 失敗 {type(e).__name__}: {str(e)[:120]}")
            sys.exit(1)  # 不推游標:下輪重抓這批
    new_cursor = max(cursor, (stopped_at - 1) if stopped_at is not None
                     else max(it["crawl"] for it in items))
    # 同一 crawl 秒項目數 > 抓取上限時 ot 卡死原地(審查修正):跨過該秒,接受秒內少量漏抓;
    # 僅在本輪無批次失敗時才跨(失敗停等 ≠ 卡死)
    if stopped_at is None and new_cursor <= cursor and len(items) >= max_items:
        log(f"cursor 卡在同秒滿頁(crawl={cursor}),強制 +1 跨過")
        new_cursor = cursor + 1
    CURSOR_FILE.parent.mkdir(parents=True, exist_ok=True)
    CURSOR_FILE.write_text(json.dumps({"ot": new_cursor}))
    log(f"fetched={len(items)} kept={len(kept)} low={low} ai_fail={ai_fail} "
        f"inserted={result.get('inserted')} dup={result.get('skipped')} "
        f"purged={result.get('purged')} cursor={new_cursor}")


if __name__ == "__main__":
    main()
