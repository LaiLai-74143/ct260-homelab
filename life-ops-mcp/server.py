#!/usr/bin/env python3
"""Life-Ops MCP server (zero-dependency, stdio JSON-RPC).

Calendar = Google Calendar (two-way, read+write) so it stays in sync with the
phone. Debts / people / notes = NocoDB base "Life-Ops" on CT270.

Config:
  ~/.config/homelab/nocodb.env  -> NC_URL, NC_TOKEN, optional NC_BASE
  ~/.config/homelab/gcal.env    -> GCAL_CLIENT_ID, GCAL_CLIENT_SECRET,
                                   GCAL_REFRESH_TOKEN, optional GCAL_CALENDAR_ID
"""
import sys, os, json, urllib.request, urllib.parse, datetime

# ---------- config ----------
def load_env(path):
    env = {}
    for line in open(os.path.expanduser(path)):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k] = v.strip().strip('"').strip("'")
    return env

CFG = load_env("~/.config/homelab/nocodb.env")
URL = CFG["NC_URL"].rstrip("/")
TOK = CFG["NC_TOKEN"]
BASE = CFG.get("NC_BASE", "ppralaha4e76q5o")

# ---------- NocoDB HTTP ----------
def api(method, path, body=None, params=None):
    if params:
        path += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method,
        headers={"xc-token": TOK, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as f:
        raw = f.read()
    return json.loads(raw) if raw else {}

_META = None
def meta():
    global _META
    if _META is None:
        m = {}
        for t in api("GET", f"/api/v1/db/meta/projects/{BASE}/tables")["list"]:
            det = api("GET", f"/api/v1/db/meta/tables/{t['id']}")
            links = {c["title"]: c["id"] for c in det["columns"]
                     if c["uidt"] in ("Links", "LinkToAnotherRecord")}
            m[t["title"]] = {"id": t["id"], "links": links}
        _META = m
    return _META

def tid(name): return meta()[name]["id"]

def allrecs(name):
    out, page = [], 0
    while True:
        r = api("GET", f"/api/v2/tables/{tid(name)}/records",
                params={"limit": 200, "offset": page * 200})
        out += r.get("list", [])
        if len(r.get("list", [])) < 200:
            break
        page += 1
    return out

def insert(name, fields):
    return api("POST", f"/api/v2/tables/{tid(name)}/records", fields)

def update(name, rid, fields):
    f = dict(fields); f["Id"] = rid
    return api("PATCH", f"/api/v2/tables/{tid(name)}/records", f)

def link(name, link_title, rid, rel_ids):
    cid = meta()[name]["links"][link_title]
    return api("POST", f"/api/v2/tables/{tid(name)}/links/{cid}/records/{rid}",
               [{"Id": i} for i in rel_ids])

def linked(name, link_title, rid):
    cid = meta()[name]["links"][link_title]
    r = api("GET", f"/api/v2/tables/{tid(name)}/links/{cid}/records/{rid}",
            params={"limit": 50})
    return r.get("list", [])

# ---------- Google Calendar ----------
_GCFG = None
def gcfg():
    global _GCFG
    if _GCFG is None:
        _GCFG = load_env("~/.config/homelab/gcal.env")
    return _GCFG

CAL = gcfg().get("GCAL_CALENDAR_ID", "primary")
TZ = "Asia/Taipei"
TZI = datetime.timezone(datetime.timedelta(hours=8))
_AT = {"tok": None, "exp": 0.0}

def gtoken():
    import time
    if _AT["tok"] and time.time() < _AT["exp"] - 60:
        return _AT["tok"]
    c = gcfg()
    data = urllib.parse.urlencode({
        "client_id": c["GCAL_CLIENT_ID"], "client_secret": c["GCAL_CLIENT_SECRET"],
        "refresh_token": c["GCAL_REFRESH_TOKEN"], "grant_type": "refresh_token"}).encode()
    r = json.loads(urllib.request.urlopen(
        urllib.request.Request("https://oauth2.googleapis.com/token", data=data), timeout=20).read())
    _AT["tok"] = r["access_token"]; _AT["exp"] = time.time() + r.get("expires_in", 3600)
    return _AT["tok"]

def gcal(method, path, body=None, params=None):
    u = "https://www.googleapis.com/calendar/v3" + path
    if params:
        u += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(u, data=data, method=method,
        headers={"Authorization": "Bearer " + gtoken(), "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as f:
        raw = f.read()
    return json.loads(raw) if raw else {}

def lnow(): return datetime.datetime.now(TZI)

def _iso(s):
    """Normalize a user time string to RFC3339 (assume +08:00 if no offset)."""
    s = s.strip().replace(" ", "T")
    if len(s) == 16:            # YYYY-MM-DDTHH:MM
        s += ":00"
    if s.endswith("Z"):
        return s
    if "+" not in s[10:] and "-" not in s[10:]:
        s += "+08:00"
    return s

def _range(a, default_days=7):
    fr, to = a.get("from"), a.get("to")
    if fr:
        tmin = _iso(fr + "T00:00:00" if len(fr) == 10 else fr)
    else:
        tmin = lnow().isoformat()
    if to:
        tmax = _iso(to + "T23:59:59" if len(to) == 10 else to)
    else:
        tmax = (lnow() + datetime.timedelta(days=a.get("days", default_days))).isoformat()
    return tmin, tmax

def _gevents(tmin, tmax, q=None):
    p = {"timeMin": tmin, "timeMax": tmax, "singleEvents": "true",
         "orderBy": "startTime", "maxResults": 100}
    if q: p["q"] = q
    return gcal("GET", f"/calendars/{urllib.parse.quote(CAL)}/events", params=p).get("items", [])

def _ev_dt(e, key):
    d = e.get(key, {})
    v = d.get("dateTime") or d.get("date")
    if not v: return None
    if len(v) == 10: v += "T00:00:00+08:00"
    if v.endswith("Z"): v = v[:-1] + "+00:00"
    try:
        return datetime.datetime.fromisoformat(v)
    except Exception:
        return None

def _ev_label(e):
    st = e.get("start", {})
    if "date" in st:
        return st["date"][5:] + " 整天"
    dt = _ev_dt(e, "start")
    return dt.astimezone(TZI).strftime("%m/%d %H:%M") if dt else "?"

PREP_RULES = [
    (("空腹", "禁食", "抽血", "體檢", "健檢", "健康檢查", "斷食"), "需空腹：前一晚起禁食、當天勿進食"),
    (("體檢", "健檢", "看診", "門診", "回診", "就醫", "掛號", "牙醫"), "帶健保卡＋身分證"),
    (("面試", "報到", "報名"), "帶證件/履歷，提前到場"),
    (("護照", "出國", "機場", "登機", "出境"), "帶護照，提前 2–3 小時到機場"),
    (("繳費", "帳單", "繳款", "罰單", "保費"), "備妥款項/卡，確認金額與期限"),
    (("預約", "訂位", "取貨"), "確認預約時間/編號"),
    (("生日", "婚禮", "結婚", "滿月", "彌月"), "準備禮物/紅包"),
    (("開會", "會議", "報告", "簡報", "提案"), "準備資料/簡報"),
    (("繳交", "截止", "期限", "deadline"), "確認繳交內容是否備妥"),
]
def _prep_lines(evs):
    out = []
    for e in evs:
        blob = " ".join(str(e.get(k) or "") for k in ("summary", "description", "location")).lower()
        hits = []
        for keys, tip in PREP_RULES:
            if any(k.lower() in blob for k in keys) and tip not in hits:
                hits.append(tip)
        if hits:
            out.append(f"{_ev_label(e)} {e.get('summary', '(行程)')}｜" + "；".join(hits))
    return out

# ---------- shared helpers ----------
def today(): return datetime.date.today().isoformat()
def dpart(s): return (s or "")[:10]

def resolve_person(query):
    q = (query or "").lower()
    rows = allrecs("People")
    hits = [p for p in rows if q in (p.get("name") or "").lower()
            or q in (p.get("aliases") or "").lower()]
    return hits

def person_of(txn):
    cp = txn.get("counterparty")
    if isinstance(cp, list) and cp:
        return cp[0].get("name") or "?"
    ls = linked("Transactions", "counterparty", txn["Id"])
    return ls[0].get("name") if ls else "?"

# ---------- calendar tools ----------
def t_calendar_agenda(a):
    tmin, tmax = _range(a, 7)
    evs = _gevents(tmin, tmax, a.get("q"))
    if not evs: return "該範圍內沒有行程。"
    return "\n".join(f"[{e['id']}] {_ev_label(e)} {e.get('summary', '(無標題)')}"
                     + (f" @{e['location']}" if e.get("location") else "") for e in evs)

def t_calendar_add(a):
    body = {"summary": a["title"]}
    if a.get("location"): body["location"] = a["location"]
    if a.get("description"): body["description"] = a["description"]
    if a.get("all_day"):
        body["start"] = {"date": a["start"][:10]}
        end = (a.get("end") or a["start"])[:10]
        # Google all-day end date is exclusive; if same day, push +1
        if end == a["start"][:10]:
            end = (datetime.date.fromisoformat(end) + datetime.timedelta(days=1)).isoformat()
        body["end"] = {"date": end}
    else:
        st = _iso(a["start"])
        if a.get("end"):
            en = _iso(a["end"])
        else:
            en = (datetime.datetime.fromisoformat(st) + datetime.timedelta(hours=1)).isoformat()
        body["start"] = {"dateTime": st, "timeZone": TZ}
        body["end"] = {"dateTime": en, "timeZone": TZ}
    if a.get("remind_min") is not None:
        body["reminders"] = {"useDefault": False,
            "overrides": [{"method": "popup", "minutes": int(a["remind_min"])}]}
    r = gcal("POST", f"/calendars/{urllib.parse.quote(CAL)}/events", body)
    return f"已建立 [{r.get('id')}] {a['title']} @ {a['start']}（已同步到手機）。"

def t_calendar_update(a):
    body = {}
    if a.get("title"): body["summary"] = a["title"]
    if a.get("location") is not None: body["location"] = a["location"]
    if a.get("description") is not None: body["description"] = a["description"]
    if a.get("start"):
        body["start"] = {"date": a["start"][:10]} if a.get("all_day") \
            else {"dateTime": _iso(a["start"]), "timeZone": TZ}
    if a.get("end"):
        body["end"] = {"date": a["end"][:10]} if a.get("all_day") \
            else {"dateTime": _iso(a["end"]), "timeZone": TZ}
    if a.get("remind_min") is not None:
        body["reminders"] = {"useDefault": False,
            "overrides": [{"method": "popup", "minutes": int(a["remind_min"])}]}
    r = gcal("PATCH", f"/calendars/{urllib.parse.quote(CAL)}/events/{a['id']}", body)
    return f"已更新 [{a['id']}] {r.get('summary', '')}。"

def t_calendar_delete(a):
    gcal("DELETE", f"/calendars/{urllib.parse.quote(CAL)}/events/{a['id']}")
    return f"已刪除行程 [{a['id']}]。"

def t_calendar_conflicts(a):
    tmin, tmax = _range(a, 30)
    evs = [e for e in _gevents(tmin, tmax) if "dateTime" in e.get("start", {})]
    out = []
    for i in range(len(evs)):
        si, ei = _ev_dt(evs[i], "start"), _ev_dt(evs[i], "end")
        for j in range(i + 1, len(evs)):
            sj, ej = _ev_dt(evs[j], "start"), _ev_dt(evs[j], "end")
            if si and ei and sj and ej and sj < ei and si < ej:
                out.append(f"衝突：{evs[i].get('summary')}({_ev_label(evs[i])}) × "
                           f"{evs[j].get('summary')}({_ev_label(evs[j])})")
    return "\n".join(out) if out else "指定範圍內無時間衝突。"

def t_prep_check(a):
    tmin, tmax = _range(a, 3)
    lines = _prep_lines(_gevents(tmin, tmax))
    return "\n".join(lines) if lines else "近期行程沒有偵測到需特別準備的事項。"

# ---------- people tools ----------
def t_find_person(a):
    hits = resolve_person(a["query"])
    if not hits: return f"找不到符合「{a['query']}」的人。"
    return "\n".join(f"[{p['Id']}] {p.get('name')} ({p.get('relation') or '-'}) "
                     f"別名:{p.get('aliases') or '-'} 聯絡:{p.get('contact') or '-'}"
                     for p in hits)

def t_add_person(a):
    f = {"name": a["name"]}
    for k in ("aliases", "relation", "contact", "notes"):
        if a.get(k): f[k] = a[k]
    r = insert("People", f)
    return f"已新增人物 [{r['Id']}] {a['name']}。"

# ---------- debt tools ----------
def t_list_debts(a):
    rows = allrecs("Transactions")
    d, person, settled = a.get("direction"), a.get("person"), a.get("settled", False)
    pset = None
    if person:
        pset = {p["Id"] for p in resolve_person(person)}
    out = []
    for x in rows:
        if bool(x.get("settled")) != bool(settled): continue
        if d and x.get("direction") != d: continue
        cp = person_of(x)
        if pset is not None:
            ls = linked("Transactions", "counterparty", x["Id"])
            if not any(l["Id"] in pset for l in ls): continue
        amt = f"{x.get('amount')} {x.get('currency') or ''}" if x.get("kind") == "金錢" else (x.get("item") or "?")
        out.append(f"[{x['Id']}] {x.get('direction')} {cp}: {amt} "
                   f"{'(到期 '+x['due_date']+')' if x.get('due_date') else ''} "
                   f"{'已結' if x.get('settled') else '未結'}")
    return "\n".join(out) if out else "沒有符合的借貸紀錄。"

def t_balance_by_person(a):
    rows = [x for x in allrecs("Transactions") if not x.get("settled") and x.get("kind") == "金錢"]
    bal, items = {}, {}
    for x in rows:
        cp = person_of(x)
        amt = float(x.get("amount") or 0)
        sign = 1 if x.get("direction") == "我借出" else -1
        bal[cp] = bal.get(cp, 0) + sign * amt
    for x in allrecs("Transactions"):
        if x.get("settled") or x.get("kind") != "物品": continue
        cp = person_of(x)
        items.setdefault(cp, []).append(f"{x.get('direction')} {x.get('item')}")
    lines = []
    for p, v in sorted(bal.items(), key=lambda kv: -abs(kv[1])):
        if abs(v) < 1e-9: continue
        lines.append(f"{p}: {'對方欠你' if v>0 else '你欠對方'} {abs(v):g}")
    for p, its in items.items():
        lines.append(f"{p} (物品): " + "; ".join(its))
    return "\n".join(lines) if lines else "目前沒有未結清的金錢/物品往來。"

def t_add_transaction(a):
    f = {"summary": a.get("summary") or f"{a['direction']} {a.get('amount') or a.get('item') or ''}".strip(),
         "direction": a["direction"], "kind": a["kind"]}
    for k in ("item", "amount", "currency", "date", "due_date", "notes"):
        if a.get(k) is not None: f[k] = a[k]
    if a["kind"] == "金錢" and not f.get("currency"): f["currency"] = "TWD"
    if not f.get("date"): f["date"] = today()
    r = insert("Transactions", f)
    hits = resolve_person(a["counterparty"])
    if not hits:
        p = insert("People", {"name": a["counterparty"]}); hits = [p]
    link("Transactions", "counterparty", r["Id"], [hits[0]["Id"]])
    return f"已記錄 [{r['Id']}] {f['summary']} ↔ {hits[0].get('name', a['counterparty'])}。"

def t_settle_transaction(a):
    update("Transactions", a["id"], {"settled": True, "settled_date": a.get("settled_date") or today()})
    return f"借貸 [{a['id']}] 已結清。"

def t_overdue_debts(a):
    td = today()
    out = []
    for x in allrecs("Transactions"):
        if x.get("settled") or not x.get("due_date"): continue
        if dpart(x["due_date"]) < td:
            out.append(f"[{x['Id']}] 逾期 {x['due_date']} {x.get('direction')} {person_of(x)}: "
                       f"{x.get('amount') or x.get('item')}")
    return "\n".join(out) if out else "沒有逾期未結的借貸。"

# ---------- note tools ----------
def t_find_note(a):
    q = a["query"].lower()
    typ = a.get("type")
    out = []
    for n in allrecs("Notes"):
        if typ and n.get("type") != typ: continue
        blob = " ".join(str(n.get(k) or "") for k in ("title", "location", "body")).lower()
        if q in blob:
            out.append(f"[{n['Id']}] ({n.get('type')}) {n.get('title')} "
                       f"{'放:'+n['location'] if n.get('location') else ''} {n.get('body') or ''}".strip())
    return "\n".join(out) if out else f"找不到含「{a['query']}」的紀錄。"

def t_add_note(a):
    f = {"title": a["title"], "type": a.get("type", "備忘")}
    for k in ("location", "body"):
        if a.get(k): f[k] = a[k]
    r = insert("Notes", f)
    return f"已新增 [{r['Id']}] ({f['type']}) {a['title']}。"

def t_list_todos(a):
    done = a.get("done", False)
    out = [f"[{n['Id']}] {'✓' if n.get('done') else '☐'} {n.get('title')}"
           for n in allrecs("Notes")
           if n.get("type") == "待辦" and bool(n.get("done")) == bool(done)]
    return "\n".join(out) if out else "沒有符合的待辦。"

# ---------- daily brief ----------
WD_STATE = "/var/tmp/wd-ct201.state"  # watchdog-ct201.sh 心跳（cron */2 分，待辦#4）

def _watchdog_line():
    try:
        kv = {}
        for ln in open(WD_STATE):
            if "=" in ln:
                k, v = ln.strip().split("=", 1)
                kv[k] = v
        age = datetime.datetime.now().timestamp() - int(kv.get("LAST_RUN", "0"))
        if age > 600:
            return f"⚠ 看門狗停擺：最後心跳 {int(age // 60)} 分鐘前（檢查 CT260 cron）"
        if kv.get("LAST_STATUS") == "OK":
            return "✅ 看門狗存活，CT201 四項檢查正常"
        return f"⚠ 看門狗存活，但 CT201 檢查失敗中（{kv.get('FAIL_DETAIL', '?')}）"
    except OSError:
        return "⚠ 看門狗狀態檔不存在（watchdog-ct201 未運行？）"
    except Exception as e:
        return f"⚠ 看門狗狀態讀取失敗：{type(e).__name__}"

def t_daily_brief(a):
    td = today()
    evs = _gevents(td + "T00:00:00+08:00", td + "T23:59:59+08:00")
    todos = [n for n in allrecs("Notes") if n.get("type") == "待辦" and not n.get("done")]
    s = [f"== 今日早報 {td} =="]
    if evs:
        s.append("【行程】\n" + "\n".join(f"  {_ev_label(e)} {e.get('summary', '(無標題)')}" for e in evs))
    else:
        s.append("【行程】 無")
    prep = _prep_lines(evs)
    if prep:
        s.append("【提醒準備】\n" + "\n".join("  " + p for p in prep))
    s.append("【待辦】" + ("\n" + "\n".join(f"  ☐ {n.get('title')}" for n in todos) if todos else " 無"))
    s.append("【逾期借貸】\n" + t_overdue_debts({}))
    s.append("【看門狗】 " + _watchdog_line())
    return "\n".join(s)

DISPATCH = {
    "calendar_agenda": t_calendar_agenda, "calendar_add": t_calendar_add,
    "calendar_update": t_calendar_update, "calendar_delete": t_calendar_delete,
    "calendar_conflicts": t_calendar_conflicts, "prep_check": t_prep_check,
    "find_person": t_find_person, "add_person": t_add_person,
    "list_debts": t_list_debts, "balance_by_person": t_balance_by_person,
    "add_transaction": t_add_transaction, "settle_transaction": t_settle_transaction,
    "overdue_debts": t_overdue_debts,
    "find_note": t_find_note, "add_note": t_add_note,
    "list_todos": t_list_todos, "daily_brief": t_daily_brief,
}

# ---------- tool schemas ----------
def S(props=None, req=None):
    return {"type": "object", "properties": props or {}, "required": req or []}
STR = {"type": "string"}
INT = {"type": "integer"}
BOOL = {"type": "boolean"}
TOOLS = [
    {"name": "calendar_agenda",
     "description": "讀 Google 日曆行程。預設未來7天；可給 from/to(YYYY-MM-DD 或 ISO)、days、q(關鍵字)。",
     "inputSchema": S({"from": STR, "to": STR, "days": INT, "q": STR})},
    {"name": "calendar_add",
     "description": "在 Google 日曆新增行程(會同步到手機)。start/end 用 ISO 本地時間(如 2026-07-06T09:00)；all_day=true 時用日期；remind_min=提前幾分鐘提醒。",
     "inputSchema": S({"title": STR, "start": STR, "end": STR, "all_day": BOOL,
        "location": STR, "description": STR, "remind_min": INT}, ["title", "start"])},
    {"name": "calendar_update",
     "description": "修改日曆行程。id 為事件 id；只帶要改的欄位。",
     "inputSchema": S({"id": STR, "title": STR, "start": STR, "end": STR, "all_day": BOOL,
        "location": STR, "description": STR, "remind_min": INT}, ["id"])},
    {"name": "calendar_delete", "description": "刪除日曆行程(用事件 id)。",
     "inputSchema": S({"id": STR}, ["id"])},
    {"name": "calendar_conflicts",
     "description": "找日曆中時間重疊的行程。預設未來30天；可給 from/to/days。",
     "inputSchema": S({"from": STR, "to": STR, "days": INT})},
    {"name": "prep_check",
     "description": "掃描近期行程(預設3天)找需要提前準備的事(空腹、帶證件、預約、禮物等)。",
     "inputSchema": S({"from": STR, "to": STR, "days": INT})},
    {"name": "find_person", "description": "依姓名/別名模糊搜尋人物。",
     "inputSchema": S({"query": STR}, ["query"])},
    {"name": "add_person", "description": "新增人物。",
     "inputSchema": S({"name": STR, "aliases": STR, "relation": STR, "contact": STR, "notes": STR}, ["name"])},
    {"name": "list_debts", "description": "列借貸；direction(我借出/我欠)、person、settled(預設false)。",
     "inputSchema": S({"direction": STR, "person": STR, "settled": BOOL})},
    {"name": "balance_by_person", "description": "彙總每人未結清淨額(誰欠你/你欠誰)與物品往來。",
     "inputSchema": S()},
    {"name": "add_transaction",
     "description": "記一筆借貸。direction=我借出|我欠, kind=金錢|物品；金錢給 amount，物品給 item；counterparty 為對象姓名(不存在自動建)。",
     "inputSchema": S({"counterparty": STR, "direction": STR, "kind": STR, "amount": {"type": "number"},
        "item": STR, "currency": STR, "date": STR, "due_date": STR, "summary": STR, "notes": STR},
        ["counterparty", "direction", "kind"])},
    {"name": "settle_transaction", "description": "把借貸標記結清。",
     "inputSchema": S({"id": INT, "settled_date": STR}, ["id"])},
    {"name": "overdue_debts", "description": "列出過了 due_date 仍未結清的借貸。", "inputSchema": S()},
    {"name": "find_note", "description": "搜尋瑣事/物品位置(標題/位置/內容)；type 可選 物品位置/備忘/想法/待辦。",
     "inputSchema": S({"query": STR, "type": STR}, ["query"])},
    {"name": "add_note", "description": "新增瑣事/物品位置。type=物品位置時用 location 記放哪。",
     "inputSchema": S({"title": STR, "type": STR, "location": STR, "body": STR}, ["title"])},
    {"name": "list_todos", "description": "列待辦(type=待辦)；done 預設 false。",
     "inputSchema": S({"done": BOOL})},
    {"name": "daily_brief", "description": "今日早報：日曆行程+要準備的事+待辦+逾期借貸。", "inputSchema": S()},
]

# ---------- JSON-RPC stdio loop ----------
def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue
        m, mid = req.get("method"), req.get("id")
        if m == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "life-ops", "version": "2.0"}}})
        elif m == "notifications/initialized":
            pass
        elif m == "ping":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif m == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
        elif m == "tools/call":
            name = req["params"]["name"]
            args = req["params"].get("arguments", {}) or {}
            try:
                text = DISPATCH[name](args)
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"content": [{"type": "text", "text": text}]}})
            except Exception as e:
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"content": [{"type": "text", "text": f"ERROR: {e}"}], "isError": True}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid,
                  "error": {"code": -32601, "message": f"method not found: {m}"}})

if __name__ == "__main__":
    main()
