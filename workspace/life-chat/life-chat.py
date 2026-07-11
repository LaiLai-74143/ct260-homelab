#!/usr/bin/env python3
"""life-chat: 生活助理服務(:5002,Bearer 驗證)——待辦49 生活頁對話框後端。

portal BFF 轉發使用者訊息進來,本服務起 claude -p(Sonnet 5,吃 CT260 已登入的
訂閱,不用 API key)回答行事曆/記帳問題:
  - 模型只掛 life-ro MCP(唯讀 7 工具,見 life-ro-mcp.py),寫入能力物理不存在。
  - 模型要寫入時只能在回覆末尾開「提案單」(```proposal JSON 塊);本服務驗
    schema 白名單→HMAC 簽名→回給前端出確認卡;使用者按確認,前端帶簽名打
    /confirm,本服務驗簽後才由確定性程式碼執行 life-ops 函式(import 本尊)。
  - 對話無伺服器端 session:前端每輪帶完整歷史(使用者裁決 2026-07-09)。

安全邊界:Bearer token(BFF 專用)、寫入白名單 6 動作、HMAC 防提案竄改、
提案 15 分鐘過期、單飛+6/分限速、執行後 TG 留痕+審計 log。

設定(chmod 600):~/.config/homelab/life-chat.env
  LIFE_CHAT_TOKEN / LIFE_CHAT_SIGNING_KEY / LIFE_CHAT_PORT(5002) /
  LIFE_CHAT_MODEL(claude-sonnet-5) / CLAUDE_BIN
  ~/.config/homelab/notify-telegram.env(留痕回發,沿用)

端點:
  GET  /health                     免驗證(Kuma/BFF 探活)
  POST /chat    Bearer  {"messages":[{"role":"user|assistant","content":str},...]}
  POST /confirm Bearer  {"action":str,"args":{},"summary":str,"ts":int,"sig":str}
  POST /clawd   Bearer  {"question":str}  ——吉祥物問答(portal 0.16.0,右鍵 Clawd):
    Plan 型唯讀(Read 限 ~/workspace/ForAI + Glob/Grep,零 MCP、禁 Bash/寫入),
    API 就不收歷史=每問全新無記憶;與 /chat 共用單飛鎖+6/分限速(訂閱保護)。
"""
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import urllib.request

try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo("Asia/Taipei")
except Exception:
    TZ = timezone(timedelta(hours=8))

HOME = Path(os.path.expanduser("~"))
CONFIG_FILES = [
    HOME / ".config/homelab/life-chat.env",
    HOME / ".config/homelab/notify-telegram.env",
]
LOG_FILE = HOME / ".local/state/life-chat/life-chat.log"
WORK_DIR = HOME / ".local/state/life-chat/work"  # claude -p 的 cwd:空目錄,無專案 CLAUDE.md
MCP_CONFIG = HOME / ".config/homelab/mcp-life-ro.json"

# 寫入動作白名單:鏡像自 life-ops server.py TOOLS(SoT=那邊;改 schema 必同步這裡)
WRITE_ACTIONS = {
    "calendar_add": {"req": ("title", "start"),
                     "opt": ("end", "all_day", "location", "description", "remind_min")},
    "calendar_update": {"req": ("id",),
                        "opt": ("title", "start", "end", "all_day", "location",
                                "description", "remind_min")},
    "calendar_delete": {"req": ("id",), "opt": ()},
    "add_transaction": {"req": ("counterparty", "direction", "kind"),
                        "opt": ("amount", "item", "currency", "date", "due_date",
                                "summary", "notes")},
    "update_transaction": {"req": ("id",),
                           "opt": ("amount", "currency", "item", "date", "due_date",
                                   "summary", "notes")},
    "settle_transaction": {"req": ("id",), "opt": ("settled_date",)},
    "add_person": {"req": ("name",), "opt": ("aliases", "relation", "contact", "notes")},
}

RO_TOOL_NAMES = ["calendar_agenda", "calendar_conflicts", "prep_check", "find_person",
                 "list_debts", "balance_by_person", "overdue_debts"]

PROPOSAL_RE = re.compile(r"```proposal\s*\n(.*?)```", re.DOTALL)
PROPOSAL_TTL = 900          # 提案 15 分鐘過期
CHAT_TIMEOUT = 110          # claude -p 上限(BFF httpx 150s,留餘裕)
MAX_BODY = 131072
RATE_MAX = 6                # 每 60s 最多 N 次 chat(訂閱額度保護;/confirm 不計)

_rate_lock = threading.Lock()
_rate_window: list[float] = []
_chat_lock = threading.Lock()   # 單飛:一次一個 claude -p


def log(msg):
    ts = datetime.now(TZ).strftime("%Y-%m-%d %H:%M:%S")
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
MODEL = CFG.get("LIFE_CHAT_MODEL", "claude-sonnet-5")
CLAUDE_BIN = CFG.get("CLAUDE_BIN", str(HOME / ".npm-global/bin/claude"))
# 服務版本標記(/health 回報):finish 腳本靠它判定「跑著的程序」要不要重啟——
# 檔案 diff 判不了半途狀態、端點探測判不了行為修正,每次改本檔就 bump
SERVICE_REV = "0160b"


def tg_send(text):
    token = CFG.get("TELEGRAM_BOT_TOKEN")
    chat = CFG.get("TELEGRAM_CHAT_ID")
    if not token or not chat:
        return
    data = json.dumps({"chat_id": chat, "text": text,
                       "disable_web_page_preview": True}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=data, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=20).read()
    except Exception as e:  # noqa: BLE001
        log(f"tg send failed: {type(e).__name__}: {str(e)[:120]}")


def rate_ok():
    now = time.time()
    with _rate_lock:
        while _rate_window and now - _rate_window[0] > 60:
            _rate_window.pop(0)
        if len(_rate_window) >= RATE_MAX:
            return False
        _rate_window.append(now)
        return True


# ---------- 提案簽名 ----------
def _canon(payload: dict) -> bytes:
    return json.dumps(payload, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode()


def sign_proposal(action, args, summary, ts):
    key = CFG["LIFE_CHAT_SIGNING_KEY"].encode()
    return hmac.new(key, _canon({"action": action, "args": args,
                                 "summary": summary, "ts": ts}),
                    hashlib.sha256).hexdigest()


def _scalar_ok(v):
    return isinstance(v, (str, int, float, bool)) and (not isinstance(v, str) or len(v) <= 500)


def validate_proposal(raw: dict):
    """回 (action, args, summary) 或丟 ValueError。"""
    action = raw.get("action")
    spec = WRITE_ACTIONS.get(action)
    if spec is None:
        raise ValueError(f"動作不在白名單: {action!r}")
    args = raw.get("args")
    if not isinstance(args, dict):
        raise ValueError("args 須為物件")
    allowed = set(spec["req"]) | set(spec["opt"])
    for k, v in args.items():
        if k not in allowed:
            raise ValueError(f"{action} 不收欄位 {k!r}")
        if not _scalar_ok(v):
            raise ValueError(f"欄位 {k!r} 型別/長度不合法")
    for k in spec["req"]:
        if k not in args:
            raise ValueError(f"{action} 缺必填欄位 {k!r}")
    summary = raw.get("summary")
    if not (isinstance(summary, str) and 0 < len(summary) <= 200):
        raise ValueError("summary 須為 1–200 字元字串")
    return action, args, summary


# ---------- claude -p ----------
def _system_prompt() -> str:
    now = datetime.now(TZ)
    wd = "一二三四五六日"[now.weekday()]
    return f"""你是家庭入口網站「生活頁」的生活助理,只負責兩件事:行事曆(Google Calendar)與記帳(NocoDB 借貸)。今天是 {now.strftime('%Y-%m-%d')}(週{wd}),時區 Asia/Taipei。

規則:
1. 一律用繁體中文(zh-TW)回覆,口吻簡潔。
2. 查詢類問題直接用工具(calendar_agenda/calendar_conflicts/prep_check/find_person/list_debts/balance_by_person/overdue_debts)取數後回答,不要憑空猜。
3. 你沒有任何寫入工具。需要新增/修改/刪除行程或記帳/銷帳時,先用讀取工具確認必要上下文(例如 calendar_update/delete 需先 calendar_agenda 拿事件 id;settle_transaction 需先 list_debts 拿紀錄 id),然後在回覆「最後」為每個寫入動作輸出一個提案塊,格式:

```proposal
{{"action": "<動作名>", "args": {{...}}, "summary": "<一句話人話描述,給確認卡顯示>"}}
```

   可用動作與欄位(其餘動作一律拒絕):
   - calendar_add: title*, start*(ISO 如 2026-07-11T14:00), end, all_day, location, description, remind_min
   - calendar_update: id*, title, start, end, all_day, location, description, remind_min
   - calendar_delete: id*
   - add_transaction: counterparty*, direction*(我借出|我欠), kind*(金錢|物品), amount, item, currency, date, due_date, summary, notes
   - update_transaction: id*(整數), amount, currency, item, date, due_date, summary, notes——部分動支/餘額變動用這個:改 amount 並在 notes 追記緣由,勿用「結清+開新筆」
   - settle_transaction: id*(整數), settled_date
   - add_person: name*, aliases, relation, contact, notes
4. 提案塊外的正文要說清楚你「打算」做什麼,等使用者按確認;絕不聲稱已執行。
5. 使用者要求範圍外的事(系統操作、其他資料、寫程式等)一律婉拒:「這裡只管行事曆與記帳」。
6. 日期解讀:「明天」「下週五」等相對日期以今天為基準換算;沒給時間的行程先問清楚或合理假設並在正文說明。
7. 人名核對(重要):記帳前一律先 find_person 查對象。若查無此名,先用姓氏或部分字再查一次;查到「名稱不同但發音相同/形近」的既有人物(例:于/宇、翔/祥、明/銘),不要逕自當成新人物——先在正文問使用者是否打錯字、指的是不是既有那位,等下一輪回覆確認後才提案。確定是全新對象才走 add_transaction(它會自動建人物)。"""


FORAI_DIR = HOME / "workspace/ForAI"


def _clawd_system_prompt() -> str:
    now = datetime.now(TZ)
    wd = "一二三四五六日"[now.weekday()]
    try:
        docs = "\n".join(f"  - {FORAI_DIR}/{n}" for n in sorted(os.listdir(FORAI_DIR))
                         if n.endswith(".txt"))
    except OSError:
        docs = "  (文件目錄暫不可讀)"
    return f"""你是 Clawd,家庭入口網站 portal 的像素吉祥物(橘色小傢伙,平時在頁面右下角值班)。使用者在網站上對你按了右鍵問問題。今天是 {now.strftime('%Y-%m-%d')}(週{wd}),時區 Asia/Taipei。

規則:
1. 一律用繁體中文(zh-TW)回覆,簡潔有點吉祥物的俏皮,但內容要準確。
2. 你是唯讀的:沒有任何寫入/執行能力,只能讀文件回答。使用者要求改設定、跑指令、部署等,一律婉拒:「我只出一張嘴,動手要找 Claude Code 本尊。」
3. 關於這個 homelab 的問題(網路拓樸、服務、監控、備份、待辦……),先讀 {FORAI_DIR}/00_索引.txt 定位,再讀對應文件取答;可用 Grep 快速找關鍵字。只讀 ~/workspace/ForAI 下的文件,不要試圖讀其他路徑。現有文件:
{docs}
4. 通識問題(不需查文件的)直接回答即可,不用硬翻文件。
5. 每次對話都是全新的:你沒有上一輪的記憶,也不會記住這一輪——需要延續脈絡的事請使用者一次講全。
6. 回覆保持精簡(通常 3–8 句內),不用 markdown 標題,不要輸出大段文件原文。"""


def run_clawd(question: str):
    """吉祥物問答:一次性 claude -p,Plan 型唯讀。回 (reply_text, meta) 或丟 RuntimeError。"""
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [
        CLAUDE_BIN, "-p",
        "--model", MODEL,
        "--output-format", "json",
        "--strict-mcp-config",  # 不帶 --mcp-config=零 MCP,連 life-ro 也不掛
        # 權限規則:單斜線開頭=相對專案根,絕對路徑必須雙斜線 //(0160b 修正:
        # 原 Read(/home/…) 被解讀為 <cwd>/home/… 永不匹配 → 唯讀全拒)
        "--allowedTools", f"Read(/{FORAI_DIR}/**),Glob,Grep",
        "--disallowedTools", "Bash,Edit,Write,WebFetch,WebSearch,"
                             "Task,NotebookEdit,TodoWrite,KillShell,BashOutput",
        "--append-system-prompt", _clawd_system_prompt(),
    ]
    env = dict(os.environ)
    env.setdefault("HOME", str(HOME))
    env["PATH"] = f"{HOME}/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
    t0 = time.time()
    try:
        r = subprocess.run(cmd, input=question, text=True,
                           capture_output=True, timeout=CHAT_TIMEOUT,
                           cwd=str(WORK_DIR), env=env)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"claude timeout {CHAT_TIMEOUT}s")
    dt = time.time() - t0
    if r.returncode != 0:
        raise RuntimeError(f"claude rc={r.returncode}: {(r.stderr or r.stdout)[:300]}")
    try:
        j = json.loads(r.stdout)
    except ValueError:
        raise RuntimeError(f"claude 輸出非 JSON: {r.stdout[:200]!r}")
    if j.get("is_error"):
        raise RuntimeError(f"claude is_error: {str(j.get('result'))[:300]}")
    return str(j.get("result") or ""), {"turns": j.get("num_turns"), "secs": round(dt, 1)}


def _transcript(messages) -> str:
    lines = ["以下是與使用者的對話,請接著回覆最後一則:", ""]
    for m in messages:
        who = "使用者" if m["role"] == "user" else "助理"
        lines.append(f"{who}: {m['content']}")
    lines.append("助理:")
    return "\n".join(lines)


def run_claude(messages):
    """回 (reply_text, meta) 或丟 RuntimeError。"""
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [
        CLAUDE_BIN, "-p",
        "--model", MODEL,
        "--output-format", "json",
        "--strict-mcp-config", "--mcp-config", str(MCP_CONFIG),
        "--allowedTools", ",".join(f"mcp__life__{t}" for t in RO_TOOL_NAMES),
        "--disallowedTools", "Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch,"
                             "Task,NotebookEdit,TodoWrite,KillShell,BashOutput",
        # 此版 CLI 的 -p 無 --max-turns;迴圈上限由 CHAT_TIMEOUT 兜底
        "--append-system-prompt", _system_prompt(),
    ]
    env = dict(os.environ)
    env.setdefault("HOME", str(HOME))
    env["PATH"] = f"{HOME}/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
    t0 = time.time()
    try:
        r = subprocess.run(cmd, input=_transcript(messages), text=True,
                           capture_output=True, timeout=CHAT_TIMEOUT,
                           cwd=str(WORK_DIR), env=env)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"claude timeout {CHAT_TIMEOUT}s")
    dt = time.time() - t0
    if r.returncode != 0:
        raise RuntimeError(f"claude rc={r.returncode}: {(r.stderr or r.stdout)[:300]}")
    try:
        j = json.loads(r.stdout)
    except ValueError:
        raise RuntimeError(f"claude 輸出非 JSON: {r.stdout[:200]!r}")
    if j.get("is_error"):
        raise RuntimeError(f"claude is_error: {str(j.get('result'))[:300]}")
    return str(j.get("result") or ""), {"turns": j.get("num_turns"), "secs": round(dt, 1)}


def extract_proposals(text):
    """抽出並簽名提案塊;回 (清掉提案塊的正文, proposals, 被拒清單)。"""
    proposals, rejected = [], []
    ts = int(time.time())
    for m in PROPOSAL_RE.finditer(text):
        blob = m.group(1).strip()
        try:
            action, args, summary = validate_proposal(json.loads(blob))
        except (ValueError, json.JSONDecodeError) as e:
            rejected.append(str(e))
            log(f"proposal REJECT: {e} blob={blob[:160]!r}")
            continue
        proposals.append({"action": action, "args": args, "summary": summary,
                          "ts": ts, "sig": sign_proposal(action, args, summary, ts)})
    reply = PROPOSAL_RE.sub("", text).strip()
    return reply, proposals, rejected


# ---------- 確認執行(import life-ops 本尊,確定性執行,不經模型) ----------
sys.path.insert(0, "/home/codex/life-ops-mcp")
import server as lifeops  # noqa: E402


def execute(action, args):
    return lifeops.DISPATCH[action](args)


# ---------- HTTP ----------
class Handler(BaseHTTPRequestHandler):
    server_version = "life-chat/1.0"
    protocol_version = "HTTP/1.1"
    timeout = 180

    def _reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, {"ok": True, "model": MODEL, "rev": SERVICE_REV})
        else:
            self._reply(404, {"ok": False, "error": "not found"})

    def _auth_body(self):
        src = self.client_address[0]
        auth = self.headers.get("Authorization", "")
        tok = CFG.get("LIFE_CHAT_TOKEN", "")
        if not (tok and hmac.compare_digest(auth, "Bearer " + tok)):
            log(f"DENY auth src={src} path={self.path}")
            self._reply(401, {"ok": False, "error": "unauthorized"})
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
            log(f"DENY bad-body src={src} path={self.path}")
            self._reply(400, {"ok": False, "error": "bad request"})
            return None

    def do_POST(self):
        if self.path == "/chat":
            self._chat()
        elif self.path == "/confirm":
            self._confirm()
        elif self.path == "/guest":
            self._guest()
        elif self.path == "/clawd":
            self._clawd()
        else:
            self._reply(404, {"ok": False, "error": "not found"})

    def _clawd(self):
        # 吉祥物問答:單一 question、無歷史(每問全新);限速/單飛與 /chat 共池
        body = self._auth_body()
        if body is None:
            return
        q = body.get("question")
        if not (isinstance(q, str) and 0 < len(q.strip()) <= 2000):
            self._reply(400, {"ok": False, "error": "question 須為 1–2000 字元字串"})
            return
        if not rate_ok():
            self._reply(429, {"ok": False, "error": "rate limited(6 次/分)"})
            return
        if not _chat_lock.acquire(blocking=False):
            self._reply(409, {"ok": False, "error": "上一輪對話仍在處理中"})
            return
        try:
            log(f"CLAWD q={q.strip()[:80]!r}")
            reply, meta = run_clawd(q.strip())
            log(f"CLAWD DONE turns={meta['turns']} {meta['secs']}s")
            self._reply(200, {"ok": True, "reply": reply, "meta": meta})
        except RuntimeError as e:
            log(f"CLAWD FAIL: {e}")
            self._reply(502, {"ok": False, "error": str(e)[:300]})
        finally:
            _chat_lock.release()

    def _guest(self):
        # guest-portal 帳號管理(待辦50;portal 生活頁面板 → 這裡 → hl-guest svc → NocoDB)。
        # 密碼/身分證字號經 stdin 交 hl-guest,不進 argv;log 只記 op+person,絕不記 secrets。
        body = self._auth_body()
        if body is None:
            return
        op = body.get("op")
        if op not in ("list", "add", "passwd", "enable", "disable", "rm"):
            self._reply(400, {"ok": False, "error": "op 不在白名單"})
            return
        try:
            r = subprocess.run(
                [str(HOME / ".local/bin/hl-guest"), "svc"],
                input=json.dumps(body), text=True, capture_output=True, timeout=140)
        except Exception as e:  # noqa: BLE001
            log(f"GUEST op={op} ERR {type(e).__name__}")
            self._reply(502, {"ok": False, "error": f"hl-guest 執行失敗:{type(e).__name__}"})
            return
        log(f"GUEST op={op} person={body.get('person', '')} rc={r.returncode}")
        try:
            out = json.loads((r.stdout or "").strip() or "{}")
        except Exception:  # noqa: BLE001
            out = {"ok": False, "error": "hl-guest 輸出異常"}
        self._reply(200 if out.get("ok") else 400, out)

    def _chat(self):
        body = self._auth_body()
        if body is None:
            return
        msgs = body.get("messages")
        if not (isinstance(msgs, list) and 0 < len(msgs) <= 40
                and all(isinstance(m, dict) and m.get("role") in ("user", "assistant")
                        and isinstance(m.get("content"), str) and 0 < len(m["content"]) <= 4000
                        for m in msgs)
                and msgs[-1]["role"] == "user"):
            self._reply(400, {"ok": False, "error": "messages 形狀不合法(≤40 則,末則須為 user)"})
            return
        if not rate_ok():
            self._reply(429, {"ok": False, "error": "rate limited(6 次/分)"})
            return
        if not _chat_lock.acquire(blocking=False):
            self._reply(409, {"ok": False, "error": "上一輪對話仍在處理中"})
            return
        try:
            log(f"CHAT n={len(msgs)} last={msgs[-1]['content'][:80]!r}")
            reply, meta = run_claude(msgs)
            reply, proposals, rejected = extract_proposals(reply)
            if not reply and proposals:
                reply = "以下動作待你確認:"
            log(f"DONE turns={meta['turns']} {meta['secs']}s "
                f"proposals={[p['action'] for p in proposals]} rejected={len(rejected)}")
            self._reply(200, {"ok": True, "reply": reply, "proposals": proposals,
                              "rejected": rejected, "meta": meta})
        except RuntimeError as e:
            log(f"CHAT FAIL: {e}")
            self._reply(502, {"ok": False, "error": str(e)[:300]})
        finally:
            _chat_lock.release()

    def _confirm(self):
        body = self._auth_body()
        if body is None:
            return
        action, args = body.get("action"), body.get("args")
        summary, ts, sig = body.get("summary"), body.get("ts"), body.get("sig")
        try:
            action, args, summary = validate_proposal(
                {"action": action, "args": args, "summary": summary})
        except ValueError as e:
            self._reply(403, {"ok": False, "error": f"提案不合法: {e}"})
            return
        if not isinstance(ts, int) or not isinstance(sig, str):
            self._reply(400, {"ok": False, "error": "缺 ts/sig"})
            return
        if not hmac.compare_digest(sig, sign_proposal(action, args, summary, ts)):
            log(f"DENY bad-sig action={action}")
            self._reply(403, {"ok": False, "error": "簽名不符(提案可能被竄改)"})
            return
        if time.time() - ts > PROPOSAL_TTL:
            self._reply(410, {"ok": False, "error": "提案已過期(15 分鐘),請重新對話產生"})
            return
        log(f"EXEC {action} args={json.dumps(args, ensure_ascii=False)[:300]}")
        try:
            result = execute(action, args)
        except Exception as e:  # noqa: BLE001
            log(f"EXEC FAIL {action}: {type(e).__name__}: {e}")
            tg_send(f"🤖 生活助理:執行失敗 {summary}\n❌ {type(e).__name__}: {str(e)[:200]}")
            self._reply(502, {"ok": False, "error": f"執行失敗: {str(e)[:200]}"})
            return
        log(f"EXEC OK {action}: {result[:160]!r}")
        tg_send(f"🤖 生活助理:已執行 {summary}\n✅ {result[:300]}")
        self._reply(200, {"ok": True, "result": result})


def main():
    for k in ("LIFE_CHAT_TOKEN", "LIFE_CHAT_SIGNING_KEY"):
        if not CFG.get(k):
            log(f"missing {k} in ~/.config/homelab/life-chat.env; aborting")
            sys.exit(1)
    if not MCP_CONFIG.exists():
        log(f"missing {MCP_CONFIG}; aborting")
        sys.exit(1)
    port = int(CFG.get("LIFE_CHAT_PORT", "5002"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    log(f"life-chat listening :{port} model={MODEL} ro_tools={len(RO_TOOL_NAMES)} "
        f"write_whitelist={len(WRITE_ACTIONS)}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
