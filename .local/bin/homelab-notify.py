#!/usr/bin/env python3
"""
homelab-notify: poll CT201 Alertmanager (via pve24 -> pct exec, since CT260 cannot
reach VLAN80 directly), diff against saved state, push new/resolved alerts to Telegram,
optionally enriched by DeepSeek. Designed to run one-shot from cron every minute.

Config (KEY=VALUE) read from, in order (later overrides earlier):
  ~/.config/homelab/notify-telegram.env   (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
  ~/.config/homelab/deepseek.env          (optional: DEEPSEEK_API_KEY, ...)

Optional keys:
  NOTIFY_SEVERITIES   default "warning,critical"  (comma list; alerts outside this are ignored)
  DEEPSEEK_API_KEY    if set, enables AI enrichment of FIRING alerts
  DEEPSEEK_MODEL      default "deepseek-chat"
  DEEPSEEK_BASE_URL   default "https://api.deepseek.com"

Secrets are read from files only; never printed.
"""
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.request
import urllib.error
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo("Asia/Taipei")
except Exception:
    TZ = timezone.utc

HOME = Path(os.path.expanduser("~"))
CONFIG_FILES = [
    HOME / ".config/homelab/notify-telegram.env",
    HOME / ".config/homelab/deepseek.env",
    HOME / ".config/homelab/ntfy.env",          # 待辦19c：ntfy 互動推播
    HOME / ".config/homelab/ntfy-webhook.env",  # 待辦19c：按鈕要嵌 webhook Bearer
    HOME / ".config/homelab/freshrss.env",      # 待辦30:晨報「今日訊息」RSS 來源
]
STATE_FILE = HOME / ".local/state/homelab-notify/state.json"
COUNTS_FILE = HOME / ".local/state/homelab-notify/daily_counts.json"
LOG_FILE = HOME / ".local/state/homelab-notify/notify.log"

# --- DeepSeek prompting -------------------------------------------------------
# Compact topology so the model can map instance/job -> real role and judge precisely.
TOPOLOGY = """[環境拓樸 — 用來把 IP/instance/job 精準對應到 VLAN/主機/CT/VM/服務]

VLAN 網段（gateway 一律 OpenWrt）:
- VLAN1  Legacy/rescue 192.168.31.0/24（僅剩 .1 OpenWrt /.2 RouterPVE /.5 24BayPVE 純救援位址, 零服務依賴）
- VLAN10 Infra        192.168.10.0/24（.1 OpenWrt /.2 N95 Router-PVE /.21 Switch3F）
- VLAN20 Servers      192.168.20.0/24（.1 OpenWrt /.5 24Bay PVE 管理 /.50 CT250 /.60 CT260）
- VLAN30 Storage      192.168.30.0/24（.1 OpenWrt /.3 DXP4800 NAS）
- VLAN40 Trusted      192.168.40.0/24（.1 OpenWrt /.4 PC）
- VLAN50 IoT/AP       192.168.50.0/24（.41/.42 AP）
- VLAN70 Game/MC      10.70.70.0/24（.1 OpenWrt /.10 CT102 /.11 CT201 /.20 CT100）
- VLAN80 觀測面        10.80.80.0/24（.1 OpenWrt /.11 CT201）— observation plane, 非管理面
- VLAN100 10G storage 192.168.100.0/24（無 gateway, .1 PC /.2 NAS /.3 24BayPVE /.10 CT100）— 純儲存非管理
- VLAN666 Honeypot    10.66.66.0/24（.1 OpenWrt /.10 VM300）— Cowrie 蜜罐, 對外曝險

主機/節點:
- OpenWrt (VM101, 跑在 N95 Router-PVE 上): 唯一主路由/防火牆/DNS/DHCP/NAT/portscan-autoban/cowrie-quarantine。
    是所有 VLAN 的 gateway。metrics 在 10.80.80.1:9105。它掛 = 全網路由/防火牆受影響。
- N95 Router PVE (192.168.10.2 / .31.2, router-pve.home.arpa): 跑 OpenWrt VM 的小主機, CPU 平時 ~40% 屬正常。
- 24Bay PVE (192.168.20.5 / .31.5 / .100.3, pve24-server.home.arpa): 主虛擬化宿主, CT100/102/201/250/260 + VM300 都在這。
- DXP4800 NAS (192.168.30.3 / .100.2, nas.home.arpa): NAS/Docker/Vaultwarden 正式/備份。某資料掛載點長期 ~88% 滿屬正常。
- CT201 Monitor (10.80.80.11 / 10.70.70.11): Prometheus/Grafana/Gotify/Alertmanager。觀測面。
- CT260 Codex Ops (192.168.20.60): AI 維運節點, 跑這支告警程式。
- CT102 (10.70.70.10 = mc.home.arpa): Minecraft Velocity/Geyser proxy, 磁碟本來就偏緊。
- CT100 (10.70.70.20 = mc-backend.home.arpa / .100.10): Minecraft backend server。
- VM300 (10.66.66.10): Cowrie SSH/Telnet 蜜罐。高流量/掃描/重啟多半是被攻擊不是故障。
- PC (192.168.40.4 trusted / 192.168.100.1 10G), Switch3F 192.168.10.21, AP 192.168.50.41/.42。

Prometheus job -> instance -> 實體:
- monitor-node = node-exporter:9100 = CT201        - pve-node = pve24-server.home.arpa:9100 = 24Bay PVE
- mc-server-node = mc-backend.home.arpa:9100 = CT100 - ct102-mc-proxy-node = 10.70.70.10:9100 = CT102
- ct260-codex-ops-node = 192.168.20.60:9100 = CT260 - n95-router-pve-node = router-pve.home.arpa:9100 = N95 Router PVE
- dxp4800-node = nas.home.arpa:9100 = DXP4800       - vm300-honeypot-node = 10.66.66.10:9100 = VM300
- cowrie-exporter = 10.66.66.10:9116 = VM300        - cowrie-geoip = 10.80.80.11:9117 = CT201
- portscan-geoip = host.docker.internal:9115 = CT201 - openwrt-*(system/portscan-autoban/cowrie-quarantine) = 10.80.80.1:9105 = OpenWrt"""

JUDGE_RULES = """[判斷原則]
- 先區分「故障」與「被攻擊」: 蜜罐/對外節點的異常多半是後者。
- 多個 exporter 同時失聯, 優先懷疑網路/VLAN/OpenWrt/CT201 scrape 路徑, 而非單機。
- OpenWrt 三個 job 共用同一 endpoint: 區分「endpoint 掛(up==0)」與「產生腳本停(metrics stale)」。
- 不臆測沒有根據的數字; 資訊不足就直接說要先看什麼。"""

# Tier 1: fast triage on first fire — one short line, no advice.
FAST_SYSTEM_PROMPT = f"""你是 homelab 維運分流助理。收到一條 Prometheus 告警, 用繁體中文「一句話」(不超過 45 字)講清楚:
哪個節點的什麼東西出了什麼狀況, 並判斷比較像「故障」還是「被攻擊」。
不要給處置建議、不要客套、不要重複數字。只回那一句。

{TOPOLOGY}"""

# Tier 2: deep analysis when an alert persists — reasons over a live metric snapshot + trend.
DEEP_SYSTEM_PROMPT = f"""你是這個家用 homelab 的資深維運 SRE。一條告警已持續一段時間未解除, 現在要做深度診斷。
user 訊息會附上「該節點當下的即時指標快照與近期趨勢」, 請務必依據這些真實數據判斷, 不要只憑告警文字臆測。
若該節點是虛擬化宿主(如 24Bay PVE), user 還會附上「底下各 CT/VM 的即時占用」; 宿主層 CPU/記憶體/IO 出現壓力時,
必須用這些 guest 數據定位是哪一台 CT/VM 造成的, 不要只說宿主整體偏高。(注意: 並非所有 guest 都有 exporter, 例如 CT250 不會出現在清單裡。)
請做完整、有依據的分析, 不要為了簡短而省略推理。

{TOPOLOGY}

{JUDGE_RULES}

[資料可信度 — 非常重要]
- 本環境的 CPU busy / iowait / mem used 百分比都是 avg 正規化過的(理論範圍 0-100%, 非多核總和)。
  因此任何 >100%、負數、剩餘空間 >100% 都是 exporter/規則 bug, 不是真實負載 —— 不要解釋成「多核加總所以可超過100%」, 直接判為數據異常。
- 若數據在物理上不可能, 或與告警矛盾(告警說高但快照正常、iowait 告警但 iowait=0 等),
  必須「明確指出這是 exporter/量測/計算異常或告警延遲」, 不可把不可能的數字當真去硬掰合理原因。先質疑數據, 再談主機。
- 利用上面拓樸把 IP/instance 對應到 VLAN/主機/CT/VM; 多個同網段目標同時異常, 優先懷疑該 VLAN/閘道/OpenWrt/交換器/scrape 路徑, 而非各自故障。

[輸出格式 — 繁體中文, 依序輸出, 內容可詳細]
純文字輸出, 不要用 markdown 反引號(`)或程式碼區塊(```), 指令/路徑/數值直接寫出 —— 訊息以純文字送 Telegram, 反引號會原樣顯示影響閱讀。
數據判讀: 從快照/趨勢看出什麼(緩升/突跳/持平/週期/矛盾), 有沒有可疑或不可能的值。
定位: 對應到哪台主機 / 哪個 VLAN / 哪個 CT/VM / 哪個服務(引用拓樸)。
根因推斷: 列出最多 2-3 個可能根因並排序, 說明依據; 資料不足就明說要再看什麼。
影響範圍: 會波及什麼。
處置步驟: 具體可執行的檢查/動作, 盡量帶指令、路徑、節點。
可信度: 對本次判斷的把握度, 以及若數據可疑該先驗證什麼。"""

BATCH_SYSTEM_PROMPT = f"""你是這個家用 homelab 的資深維運 SRE。以下多條告警在同一時間一起觸發, 可能互相關聯。

{TOPOLOGY}

{JUDGE_RULES}

[輸出格式 — 繁體中文, 嚴格遵守, 總長不超過 6 行]
純文字輸出, 不要用 markdown 反引號(`)或程式碼區塊 —— 訊息以純文字送 Telegram, 反引號會原樣顯示影響閱讀。
共同根因: <它們是否指向同一根因(網路/VLAN/某台機器/備份/掃描爆發…), 還是各自獨立>
先查: <最該優先處理的那一個, 以及為什麼>
其餘: <一句帶過其他項的處置順序>
不要逐條複述告警, 聚焦關聯與優先級。"""

DAILY_REPORT_SYSTEM_PROMPT = f"""你是這個家用 homelab 的維運 SRE。以下是今天各告警「達到閾值的次數」彙整。
請用繁體中文產生一份精簡日報, 幫助使用者一眼看懂今天系統健康狀況。

{TOPOLOGY}

[輸出格式 — 繁體中文, 總長不超過 12 行]
今日總評: <一句, 今天整體穩不穩、有沒有需要擔心的>
重點項目: <挑 1-3 個最值得注意的告警, 各一句講可能原因(結合次數/來源/角色); 蜜罐相關記得區分被攻擊 vs 故障>
需人介入: <有的話列出, 沒有就寫「無, 多為瞬時或可自動恢復」>
不要逐條複述所有告警, 聚焦趨勢與異常。"""

# How we reach CT201's Alertmanager (CT260 has no direct VLAN80 route).
ALERTMANAGER_CMD = [
    "ssh", "pve24-auto",
    "sudo", "pct", "exec", "201", "--",
    "curl", "-s", "--max-time", "10",
    "http://localhost:9093/api/v2/alerts",
]


def log(msg):
    ts = datetime.now(TZ).strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    try:
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


def fetch_alerts():
    out = subprocess.run(ALERTMANAGER_CMD, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(f"alertmanager fetch failed rc={out.returncode}: {out.stderr.strip()[:200]}")
    return json.loads(out.stdout)


def fmt_time(iso):
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(TZ)
        return dt.strftime("%m-%d %H:%M")
    except Exception:
        return iso


def model_fast(cfg):
    return cfg.get("DEEPSEEK_MODEL_FAST") or cfg.get("DEEPSEEK_MODEL") or "deepseek-chat"


def model_deep(cfg):
    return cfg.get("DEEPSEEK_MODEL_DEEP") or "deepseek-reasoner"


def _plain(text):
    """Strip markdown that only clutters plain-text Telegram (we send with no parse_mode,
    so backticks/code fences render literally). Used for the v4-pro deep/batch output."""
    if not text:
        return text
    return text.replace("```", "").replace("`", "")


def deepseek_call(cfg, model, system_prompt, user_content, max_tokens=400, timeout=60):
    """Generic DeepSeek chat call. Returns content str or None (never raises)."""
    key = cfg.get("DEEPSEEK_API_KEY")
    if not key:
        return None
    base = cfg.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com").rstrip("/")
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ],
        "stream": False,
        "max_tokens": max_tokens,
        "temperature": 0.2,
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{base}/chat/completions", data=data,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            resp = json.load(r)
        return resp["choices"][0]["message"]["content"].strip()
    except Exception as e:
        log(f"deepseek call ({model}) failed: {type(e).__name__}: {str(e)[:150]}")
        return None


def alert_to_text(alert):
    labels = alert.get("labels", {})
    ann = alert.get("annotations", {})
    return (
        f"alertname: {labels.get('alertname')}\n"
        f"severity: {labels.get('severity')}\n"
        f"instance: {labels.get('instance')}\n"
        f"job: {labels.get('job')}\n"
        f"summary: {ann.get('summary')}\n"
        f"description: {ann.get('description')}"
    )


def flash_oneliner(cfg, alert):
    """Tier 1: short triage line from the fast model.
    v4 models are reasoning models (reasoning_content consumes tokens before content),
    so max_tokens must leave room for both or content comes back empty."""
    return deepseek_call(cfg, model_fast(cfg), FAST_SYSTEM_PROMPT,
                         alert_to_text(alert), max_tokens=600, timeout=40)


# --- Prometheus context (Tier 2, plan C) -------------------------------------
def prom_query(expr):
    """Instant query against CT201 Prometheus via pve24 -> pct exec. Returns float or None.
    ssh joins argv into one remote shell string, so the (space-containing) expr must be
    shell-quoted as a single token or the remote shell will word-split it."""
    remote = ("sudo pct exec 201 -- curl -s --max-time 8 -G "
              "http://localhost:9090/api/v1/query --data-urlencode "
              + shlex.quote("query=" + expr))
    try:
        out = subprocess.run(["ssh", "pve24-auto", remote], capture_output=True, text=True, timeout=20)
        res = json.loads(out.stdout)["data"]["result"]
        if not res:
            return None
        return float(res[0]["value"][1])
    except Exception:
        return None


# Physical guests per virtualization host (host instance -> [(name, guest instance)]).
# Lets Tier2 see which CT/VM is driving a host-level alert (e.g. 24Bay mem high).
# Only guests that run their own node_exporter appear here (CT250 has none, so it can't be shown).
HOST_GUESTS = {
    "pve24-server.home.arpa:9100": [
        ("CT100 mc-backend", "mc-backend.home.arpa:9100"),
        ("CT102 mc-proxy", "10.70.70.10:9100"),
        ("CT201 monitor", "host.docker.internal:9100"),
        ("CT202 fwdproxy", "10.80.80.10:9100"),
        ("CT203 dmz-proxy", "10.60.60.10:9100"),
        ("CT260 codex-ops", "192.168.20.60:9100"),
        ("CT270 life-ops", "192.168.20.70:9100"),
        ("VM300 honeypot", "10.66.66.10:9100"),
    ],
}


def node_snapshot(instance):
    """Live snapshot + 30m-ago comparison for a node_exporter instance. Text or None."""
    i = instance
    fsx = 'fstype!~"tmpfs|overlay|squashfs|ramfs|devtmpfs|fuse.*|iso9660"'
    q = {
        "cpu":   f'100 - (avg(rate(node_cpu_seconds_total{{instance="{i}",mode="idle"}}[5m]))*100)',
        "iowait": f'avg(rate(node_cpu_seconds_total{{instance="{i}",mode="iowait"}}[5m]))*100',
        "mem":   f'(1 - node_memory_MemAvailable_bytes{{instance="{i}"}}/node_memory_MemTotal_bytes{{instance="{i}"}})*100',
        "load1": f'node_load1{{instance="{i}"}}',
        "disk":  f'min((node_filesystem_avail_bytes{{instance="{i}",{fsx}}}/node_filesystem_size_bytes)*100)',
        "dread": f'sum(rate(node_disk_read_bytes_total{{instance="{i}"}}[5m]))/1048576',
        "dwrite": f'sum(rate(node_disk_written_bytes_total{{instance="{i}"}}[5m]))/1048576',
        "cpu_30m":  f'100 - (avg(rate(node_cpu_seconds_total{{instance="{i}",mode="idle"}}[5m] offset 30m))*100)',
        "iowait_30m": f'avg(rate(node_cpu_seconds_total{{instance="{i}",mode="iowait"}}[5m] offset 30m))*100',
        "mem_30m":   f'(1 - node_memory_MemAvailable_bytes{{instance="{i}"}} offset 30m/node_memory_MemTotal_bytes{{instance="{i}"}} offset 30m)*100',
    }
    v = {k: prom_query(e) for k, e in q.items()}
    if v["cpu"] is None and v["mem"] is None and v["load1"] is None:
        return None  # not a node_exporter target

    def f(x, suf=""):
        return f"{x:.1f}{suf}" if isinstance(x, float) else "n/a"

    def trend(now, old):
        if not isinstance(now, float) or not isinstance(old, float):
            return ""
        d = now - old
        arrow = "↑" if d > 1 else ("↓" if d < -1 else "→")
        return f" (30m前 {old:.1f}, {arrow}{abs(d):.1f})"

    lines = [
        f"[{instance} 即時快照]",
        f"CPU busy: {f(v['cpu'],'%')}{trend(v['cpu'], v['cpu_30m'])}",
        f"iowait: {f(v['iowait'],'%')}{trend(v['iowait'], v['iowait_30m'])}",
        f"mem used: {f(v['mem'],'%')}{trend(v['mem'], v['mem_30m'])}",
        f"load1: {f(v['load1'])}",
        f"min disk free: {f(v['disk'],'%')}",
        f"disk read/write: {f(v['dread'],'MB/s')} / {f(v['dwrite'],'MB/s')}",
    ]
    return "\n".join(lines)


def guest_breakdown(instance):
    """For a virtualization host, snapshot every guest that has a node_exporter, so the
    deep model can localize which CT/VM drives a host-level alert. Text or None."""
    guests = HOST_GUESTS.get(instance)
    if not guests:
        return None
    blocks = []
    for name, gi in guests:
        snap = node_snapshot(gi)
        if snap:
            blocks.append(f"-- {name} ({gi}) --\n{snap}")
    if not blocks:
        return None
    return "[底下各 CT/VM 即時占用]\n" + "\n\n".join(blocks)


# --- Loki log context (Tier 2, 待辦12e) ---------------------------------------
# CT260 -> CT201:3100 走 OpenWrt Allow-CT260-To-Monitor-Loki-3100 直連(非 ssh 跳板)。
LOKI_URL = "http://10.80.80.11:3100"

# instance 對不出 host 時的後備對照(promtail 的 host label)
_INSTANCE_LOKI_HOST = [
    ("mc-backend.home.arpa", "ct100"),
    ("10.70.70.10", "ct102"),
    ("host.docker.internal", "ct201"),
    ("10.80.80.10", "ct202"),
    ("10.60.60.10", "ct203"),
    ("192.168.20.60", "ct260"),
    ("192.168.20.70", "ct270"),
    ("10.66.66.10", "vm300"),
    ("10.80.80.1:9105", "openwrt"),
]


def loki_host_for(alert):
    """Map an alert to its promtail host label (ct100/ct202/.../openwrt/vm300) or None.
    Hosts without promtail (pve24/RouterPVE/DXP/AP) return None and are skipped."""
    labels = alert.get("labels", {}) or {}
    dev = labels.get("device", "") or ""
    m = re.search(r"CT(\d+)", dev)
    if m:
        return "ct" + m.group(1)
    m = re.search(r"VM(\d+)", dev)
    if m:
        return "vm" + m.group(1)
    if "OpenWrt" in dev:
        return "openwrt"
    inst = labels.get("instance", "") or ""
    for key, host in _INSTANCE_LOKI_HOST:
        if key in inst:
            return host
    return None


def loki_context(alert, minutes=15, limit=40):
    """Recent Loki lines for the alerting host, for the Tier2 prompt (待辦12e).
    Any failure returns None — 日誌管線故障不得影響告警本身(鐵則:失敗退回純告警)。"""
    host = loki_host_for(alert)
    if not host:
        return None
    try:
        end = int(datetime.now(timezone.utc).timestamp())
        start = end - minutes * 60
        qs = urllib.parse.urlencode({
            "query": '{host="%s"}' % host,
            "start": str(start * 1_000_000_000),
            "end": str(end * 1_000_000_000),
            "limit": str(limit),
            "direction": "backward",
        })
        req = urllib.request.Request(f"{LOKI_URL}/loki/api/v1/query_range?{qs}")
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.load(r)
        entries = []
        for stream in data.get("data", {}).get("result", []):
            lab = stream.get("stream", {}) or {}
            src = lab.get("container") or lab.get("ident") or lab.get("unit") or lab.get("job") or "?"
            for ts, line in stream.get("values", []):
                entries.append((int(ts), src, line))
        if not entries:
            return None
        entries.sort()
        entries = entries[-limit:]
        out = []
        for ts, src, line in entries:
            t = datetime.fromtimestamp(ts / 1_000_000_000, TZ).strftime("%H:%M:%S")
            line = line.strip()
            if len(line) > 240:
                line = line[:240] + "…"
            out.append(f"{t} [{src}] {line}")
        text = "\n".join(out)
        if len(text) > 6000:
            text = text[-6000:]
        return f"[Loki 近{minutes}分鐘日誌 host={host} 最新{len(out)}行, 時間為台北時區]\n{text}"
    except Exception:
        return None


def deep_analysis(cfg, alert):
    """Tier 2: gather live context and ask the deep/thinking model.
    For a virtualization host, also feed every guest's snapshot so the model can pin down
    which CT/VM caused the host-level pressure instead of just reporting the host total."""
    inst = (alert.get("labels", {}) or {}).get("instance", "")
    snap = node_snapshot(inst) if inst else None
    parts = ["[告警]", alert_to_text(alert)]
    if snap:
        parts += ["", snap]
    else:
        parts += ["", f"(無 node_exporter 快照; {inst} 非標準主機目標, 請依告警類型與拓樸判斷)"]
    gb = guest_breakdown(inst) if inst else None
    if gb:
        parts += ["", gb]
    lk = loki_context(alert)
    if lk:
        parts += ["", lk]
    return _plain(deepseek_call(cfg, model_deep(cfg), DEEP_SYSTEM_PROMPT,
                                "\n".join(parts), max_tokens=3000, timeout=180))


def _tg_post(cfg, text):
    token = cfg["TELEGRAM_BOT_TOKEN"]
    chat = cfg["TELEGRAM_CHAT_ID"]
    data = json.dumps({
        "chat_id": chat,
        "text": text,
        "disable_web_page_preview": True,
    }).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=data, headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        resp = json.load(r)
    if not resp.get("ok"):
        raise RuntimeError(f"telegram error: {resp}")
    return resp


def _split_chunks(text, limit=3900):
    """Split long text on line boundaries to stay under Telegram's 4096-char cap."""
    if len(text) <= limit:
        return [text]
    chunks, cur = [], ""
    for line in text.split("\n"):
        while len(line) > limit:  # a single very long line
            chunks.append(line[:limit]); line = line[limit:]
        if len(cur) + len(line) + 1 > limit:
            if cur:
                chunks.append(cur)
            cur = line
        else:
            cur = cur + "\n" + line if cur else line
    if cur:
        chunks.append(cur)
    return chunks


def telegram_send(cfg, text):
    chunks = _split_chunks(text)
    n = len(chunks)
    resp = None
    for i, c in enumerate(chunks):
        prefix = f"（{i+1}/{n}）\n" if n > 1 else ""
        resp = _tg_post(cfg, prefix + c)
    return resp


# --- 通知路由（2026-07-07 分流改造）：TG=敘事頻道、ntfy=動作頻道 ---------------
# 單一路由表：(事件類型, severity) -> 通道集合；查序 (kind,sev) -> (kind,None) -> {tg}。
# 唯一雙推例外 = critical FIRING（通道互備：外網斷 ntfy 於 LAN 仍達、Tailscale 斷 TG 仍達）。
# ups/approval 為預留項（UPS 電源事件=待辦1f、Claude Code 審批=待辦19構想#7），
# 告警源落地後直接查表接線。管線異常/恢復直發 TG 屬 severity 體系外旁路，不套此表。
CH_TG, CH_NTFY = "tg", "ntfy"
ROUTES = {
    ("firing",   "critical"): frozenset({CH_TG, CH_NTFY}),
    ("firing",   None):       frozenset({CH_TG}),    # warning 及以下 = 閱讀型
    ("resolved", None):       frozenset({CH_TG}),    # 閱讀型（critical 亦同）
    ("analysis", None):       frozenset({CH_TG}),    # Tier1/Tier2/關聯分析
    ("report",   None):       frozenset({CH_TG}),    # 日報/晨報/週報
    ("ups",      None):       frozenset({CH_NTFY}),  # 預留
    ("approval", None):       frozenset({CH_NTFY}),  # 預留
}


def route_channels(kind, severity=None):
    sev = (severity or "").strip().lower() or None
    return ROUTES.get((kind, sev)) or ROUTES.get((kind, None)) or frozenset({CH_TG})


def ntfy_enabled(cfg):
    return bool(cfg.get("NTFY_URL") and cfg.get("NTFY_PUB_TOKEN"))


# --- ntfy 互動推播（待辦19c；2026-07-07 分流後=動作頻道）-----------------------
# 只收 route_channels 含 ntfy 的事件（現行=critical FIRING）；
# 按鈕僅附給 NTFY_ACTION_MAP 有預定義處置的告警，其餘 critical 推純通知。
# 鐵則：ntfy 任何失敗只記 log 不 raise，絕不影響 TG 主鏈。
GRAFANA_URL = "https://grafana.hl.lailai74143.com"
NTFY_PARAM_RE = re.compile(r"^[A-Za-z0-9_:-]{1,64}$")
NTFY_PRIORITY = {"critical": 5, "warning": 4}  # ntfy 數字優先級：5=urgent
# alertname -> 白名單具名處置動作（動作字典見 ntfy-webhook.py ACTIONS）
NTFY_ACTION_MAP = {
    "SquidProxyDown": ("restart-squid", "重啟squid"),
    "CtdmzGateDown": ("restart-ctdmz-nft", "重啟閘門"),
}


def _ntfy_http_action(cfg, label, action, param=None):
    body = {"action": action}
    if param:
        body["param"] = param
    return {
        "action": "http", "label": label,
        "url": cfg.get("WEBHOOK_URL", "http://192.168.20.60:5001/run"),
        "method": "POST",
        "headers": {
            "Authorization": "Bearer " + cfg.get("WEBHOOK_TOKEN", ""),
            "Content-Type": "application/json",
        },
        "body": json.dumps(body, ensure_ascii=False),
        "clear": False,
    }


def ntfy_publish(cfg, title, message, priority=3, actions=None, tags=None):
    """回傳 True=送達 ntfy；False=未設定或失敗（失敗只記 log，鐵則）。"""
    url = cfg.get("NTFY_URL")
    token = cfg.get("NTFY_PUB_TOKEN")
    if not url or not token:
        return False
    payload = {"topic": cfg.get("NTFY_TOPIC", "homelab"),
               "title": title, "message": message, "priority": priority}
    if tags:
        payload["tags"] = tags
    if actions:
        payload["actions"] = actions
    try:
        req = urllib.request.Request(
            url, data=json.dumps(payload, ensure_ascii=False).encode(),
            headers={"Authorization": f"Bearer {token}",
                     "Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10).read()
        return True
    except Exception as e:
        log(f"ntfy publish failed: {type(e).__name__}: {str(e)[:120]}")
        return False


def _ntfy_has_action(name):
    """該 alertname 是否有預定義處置按鈕——TG 註記與 ntfy 附按鈕共用此判定（單一真實來源）。"""
    return bool(name and name in NTFY_ACTION_MAP and NTFY_PARAM_RE.match(name))


def ntfy_publish_firing(cfg, alert):
    labels = alert.get("labels", {}) or {}
    ann = alert.get("annotations", {}) or {}
    name = labels.get("alertname") or "?"
    sev = (labels.get("severity") or "").lower()
    prio = NTFY_PRIORITY.get(sev, 3)
    icon = "🔴" if sev == "critical" else "🟠"
    inst = labels.get("instance")
    title = f"{icon} FIRING [{sev.upper()}] {name}" + (f" @ {inst}" if inst else "")
    lines = [ann.get("summary", "")]
    if inst:
        lines.append(f"instance: {inst}")
    msg = "\n".join(x for x in lines if x)
    # 按鈕僅附給有預定義處置的告警；無對應者推純通知（2026-07-07 分流）
    actions = None
    if _ntfy_has_action(name):
        mapped = NTFY_ACTION_MAP[name]
        actions = [
            _ntfy_http_action(cfg, mapped[1], mapped[0]),
            _ntfy_http_action(cfg, "靜音1h", "silence-1h", name),
            {"action": "view", "label": "開Grafana", "url": GRAFANA_URL},
        ]
    return ntfy_publish(cfg, title, msg, priority=prio, actions=actions)  # ntfy 上限 3 顆


def ntfy_try_publish_firing(cfg, alert):
    """鐵則的結構性保證：任何例外都吞掉只記 log，絕不影響 TG 主鏈。回傳 True=已送達。"""
    try:
        return ntfy_publish_firing(cfg, alert)
    except Exception as e:
        log(f"ntfy publish (firing) failed: {type(e).__name__}: {str(e)[:120]}")
        return False


def ntfy_publish_resolved(cfg, prev_entry):
    sev = (prev_entry.get("severity") or "").upper()
    inst = prev_entry.get("instance") or ""
    title = f"✅ RESOLVED [{sev}] {prev_entry.get('alertname')}"
    ntfy_publish(cfg, title, inst, priority=3, tags=["white_check_mark"])


def build_firing_msg(cfg, alert, flash_line=None, ntfy_ok=None):
    labels = alert.get("labels", {})
    ann = alert.get("annotations", {})
    sev = (labels.get("severity") or "").upper()
    icon = "🟠" if sev == "WARNING" else "🔴" if sev == "CRITICAL" else "⚪"
    lines = [
        f"{icon} FIRING [{sev}] {labels.get('alertname')}",
        ann.get("summary", ""),
    ]
    inst = labels.get("instance")
    if inst:
        lines.append(f"instance: {inst} (job {labels.get('job','-')})")
    desc = ann.get("description")
    if desc and desc != ann.get("summary"):
        lines.append(desc)
    lines.append(f"🕐 {fmt_time(alert.get('startsAt',''))}")
    # ntfy_ok=實際發布結果（None=未路由到 ntfy，不加註記）——註記反映送達事實，不是路由意圖
    if ntfy_ok is True:
        lines.append("📱 已同步 ntfy，處置按鈕請至 ntfy 操作"
                     if _ntfy_has_action(labels.get("alertname"))
                     else "📱 已同步 ntfy（互備通道）")
    elif ntfy_ok is False:
        lines.append("⚠️ ntfy 同步失敗（按鈕不可用，詳 notify.log）")
    if flash_line:
        lines.append("")
        lines.append("⚡ " + flash_line)
    return "\n".join(x for x in lines if x is not None)


def deepseek_batch(cfg, alerts):
    """One combined correlation analysis (deep model) when several alerts fire at once."""
    block = []
    for a in alerts:
        l = a.get("labels", {})
        an = a.get("annotations", {})
        block.append(
            f"- {l.get('alertname')} [{l.get('severity')}] "
            f"{l.get('instance','')} {l.get('job','')}: {an.get('summary','')}"
        )
    # attach a live snapshot (+ guest breakdown for hosts) per distinct instance involved,
    # so the correlation judgement reasons over real numbers, not just alert text.
    seen, snaps = [], []
    for a in alerts:
        i = (a.get("labels", {}) or {}).get("instance", "")
        if not i or i in seen:
            continue
        seen.append(i)
        s = node_snapshot(i)
        if s:
            snaps.append(s)
        gb = guest_breakdown(i)
        if gb:
            snaps.append(gb)
    user_content = "\n".join(block)
    if snaps:
        user_content += "\n\n[相關節點即時快照]\n" + "\n\n".join(snaps)
    return _plain(deepseek_call(cfg, model_deep(cfg), BATCH_SYSTEM_PROMPT,
                                user_content, max_tokens=2500, timeout=150))


def build_resolved_msg(prev):
    sev = (prev.get("severity") or "").upper()
    inst = prev.get("instance") or ""
    base = f"✅ RESOLVED [{sev}] {prev.get('alertname')}"
    return f"{base} — {inst}" if inst else base


def load_state():
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2))


def load_counts():
    if COUNTS_FILE.exists():
        try:
            return json.loads(COUNTS_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_counts(counts):
    COUNTS_FILE.write_text(json.dumps(counts, ensure_ascii=False, indent=2))


# --- alert-pipeline self-check (待辦#4d): consecutive Alertmanager fetch failures ---
FETCH_FAIL_FILE = HOME / ".local/state/homelab-notify/fetch_fail_count"
FETCH_FAIL_ALERT_AFTER = 3


def read_fetch_failures():
    try:
        return int(FETCH_FAIL_FILE.read_text().strip())
    except Exception:
        return 0


def bump_fetch_failures():
    n = read_fetch_failures() + 1
    try:
        FETCH_FAIL_FILE.write_text(str(n))
    except Exception:
        pass
    return n


def reset_fetch_failures():
    try:
        FETCH_FAIL_FILE.write_text("0")
    except Exception:
        pass


def bump_counts(new_alerts):
    """Increment per-alertname daily threshold-hit counters for newly firing alerts."""
    if not new_alerts:
        return
    counts = load_counts()
    for a in new_alerts:
        labels = a.get("labels", {}) or {}
        name = labels.get("alertname") or "?"
        inst = labels.get("instance") or ""
        e = counts.setdefault(name, {"count": 0, "severity": labels.get("severity"), "instances": {}})
        e["count"] += 1
        e["severity"] = labels.get("severity")
        if inst:
            e["instances"][inst] = e["instances"].get(inst, 0) + 1
    save_counts(counts)


def daily_report(cfg):
    """Run at 20:00: if any threshold was hit today, send an AI digest then reset counters."""
    if "--dry-run" in sys.argv:
        log("daily report 必然真發並清空計數器，與 --dry-run 互斥；中止")
        return
    counts = load_counts()
    total = sum(v.get("count", 0) for v in counts.values())
    if total == 0:
        log("daily report: no threshold hits today, skipping")
        return
    if CH_TG not in route_channels("report"):  # report=閱讀型，查路由表；現行僅 TG 發送器
        log("daily report: TG not in route, skipping send")
        return
    rows = []
    for name, v in sorted(counts.items(), key=lambda kv: -kv[1].get("count", 0)):
        insts = ", ".join(f"{i}×{n}" for i, n in v.get("instances", {}).items()) or "-"
        rows.append(f"- {name} [{v.get('severity')}] 共 {v.get('count')} 次; 來源: {insts}")
    user_content = "今日各告警達閾值次數:\n" + "\n".join(rows)
    date = datetime.now(TZ).strftime("%Y-%m-%d")
    header = f"📋 每日告警彙整 {date}（{total} 次 / {len(counts)} 類）"
    analysis = deepseek_call(cfg, model_deep(cfg), DAILY_REPORT_SYSTEM_PROMPT,
                             user_content, max_tokens=2500, timeout=150)
    body = header + "\n\n" + (analysis if analysis else "(AI 報告產生失敗，原始統計:)\n" + "\n".join(rows))
    try:
        telegram_send(cfg, body)
        save_counts({})  # reset only after a successful send
        log(f"daily report sent: total={total} types={len(counts)}")
    except Exception as e:
        log(f"daily report send failed (counters NOT reset): {type(e).__name__}: {str(e)[:150]}")


BRIEF_FILE = HOME / ".local/state/homelab-notify/brief.json"
BRIEF_STATE_FILE = HOME / ".local/state/homelab-notify/brief-state.json"
BRIEF_SYSTEM_PROMPT = """你是這個家用 homelab 的維運 SRE, 為入口大廳寫「今日快報」總評。
根據提供的 targets/告警/安全數據, 輸出繁體中文 2-3 句(不超過 120 字):
第一句講整體穩不穩; 若有異常, 點名最需要注意的一項並給一句建議。不要條列、不要 markdown。"""

RSS_SYSTEM_PROMPT = """你是晨報編輯。從提供的未讀 RSS 標題清單挑 5-8 條最值得知道的,
輸出繁體中文單段文字:每條=「要點(來源)」,條與條之間用「;」分隔,
不換行、不條列、不 markdown,總長不超過 220 字。標題重複或同事件多篇只留一條。"""


def fetch_rss_unread(cfg, limit=40):
    """FreshRSS Google Reader API 拉未讀(待辦30)。回 [(feed, title)];異常拋出讓上層誠實註記。"""
    base = cfg["FRESHRSS_URL"].rstrip("/") + "/api/greader.php"
    q = urllib.parse.urlencode({"Email": cfg["FRESHRSS_USER"],
                                "Passwd": cfg["FRESHRSS_API_PASSWORD"]})
    r = urllib.request.urlopen(base + "/accounts/ClientLogin?" + q, timeout=15).read().decode()
    auth = dict(line.split("=", 1) for line in r.strip().splitlines())["Auth"]
    req = urllib.request.Request(
        base + "/reader/api/0/stream/contents/user/-/state/com.google/reading-list?"
        + urllib.parse.urlencode({"xt": "user/-/state/com.google/read",
                                  "n": str(limit), "output": "json"}),
        headers={"Authorization": "GoogleLogin auth=" + auth})
    d = json.loads(urllib.request.urlopen(req, timeout=20).read().decode())
    return [((it.get("origin") or {}).get("title") or "?", it.get("title") or "?")
            for it in d.get("items", [])]


def rss_section(cfg):
    """晨報「今日訊息」段(待辦30)。未設定=不出段;讀取失敗/無未讀=誠實註記,不擺舊數據。"""
    if not cfg.get("FRESHRSS_URL") or not cfg.get("FRESHRSS_API_PASSWORD"):
        return None
    try:
        items = fetch_rss_unread(cfg, limit=25)
    except Exception as e:
        log(f"brief: freshrss 讀取失敗 {type(e).__name__}")
        return {"h": "今日訊息", "body": "RSS 讀取失敗,本期缺新聞視角(檢查 CT270 FreshRSS)。"}
    if not items:
        return {"h": "今日訊息", "body": "無未讀新訊(訂閱源在 FreshRSS UI 維護)。"}
    ai_in = json.dumps([{"feed": f, "title": t} for f, t in items], ensure_ascii=False)
    # max_tokens 需含 reasoning 預算:v4-flash 思考吃掉太小的上限會回空 content(踩坑 2026-07-09;
    # 1200 實測仍偶爆=2026-07-10 大廳退回原題,拉到 3000 並補一次重試)
    digest = deepseek_call(cfg, model_fast(cfg), RSS_SYSTEM_PROMPT, ai_in,
                           max_tokens=3000, timeout=60)
    if not digest:
        digest = deepseek_call(cfg, model_fast(cfg), RSS_SYSTEM_PROMPT, ai_in,
                               max_tokens=3000, timeout=60)
    if not digest:
        digest = ";".join(t for _, t in items[:5]) + "。(AI 濃縮失敗,列前 5 條原題)"
    return {"h": "今日訊息", "body": digest}


def write_brief(cfg):
    """--write-brief:產出入口大廳晨報 JSON 並投遞 CT201 /opt/portal/data/(待辦49 M1)。
    與 --daily-report 完全解耦:不發 TG、不清 daily_counts、可隨時手動重跑;
    --dry-run 時只寫本地不投遞。個別數據源失敗以誠實註記帶過,不整期失敗。"""
    now = datetime.now(TZ)
    date = now.strftime("%Y-%m-%d")

    # 期號:跨日 +1;同日重跑沿用(手動刷新不灌水)
    try:
        st = json.loads(BRIEF_STATE_FILE.read_text())
    except Exception:
        st = {}
    if st.get("date") == date and st.get("issue_no"):
        issue_no = int(st["issue_no"])
    else:
        issue_no = int(st.get("issue_no", 0)) + 1

    firing = None
    try:
        firing = []
        for a in fetch_alerts():
            stt = a.get("status", {})
            if stt.get("state") != "active" or stt.get("silencedBy") or stt.get("inhibitedBy"):
                continue
            labels = a.get("labels", {})
            firing.append((labels.get("severity") or "?", labels.get("alertname") or "?",
                           labels.get("instance") or ""))
    except Exception as e:
        log(f"brief: alertmanager 讀取失敗 {type(e).__name__}")
    up_total = prom_query("count(up)")
    up_ok = prom_query("count(up == 1)")
    banned = prom_query("portscan_autoban_banned_ips")
    counts = load_counts()
    hits_total = sum(v.get("count", 0) for v in counts.values())

    sections = []
    if up_total:
        t = f"Prometheus {int(up_total)} targets 中 {int(up_ok or 0)} up"
        if firing is None:
            t += ";Alertmanager 讀取失敗,告警視角缺席本期"
        elif not firing:
            t += ";目前無 firing 告警"
        else:
            crit = sum(1 for s, _, _ in firing if s == "critical")
            t += f";firing {len(firing)} 條(critical {crit})"
        sections.append({"h": "全站概況", "body": t + "。"})
    else:
        sections.append({"h": "全站概況", "body": "Prometheus 讀取失敗,本期缺 targets 視角。"})
    if firing:
        rows = ";".join(f"{n}[{s}]" + (f"@{i}" if i else "") for s, n, i in firing[:4])
        more = f" 等共 {len(firing)} 條" if len(firing) > 4 else ""
        sections.append({"h": "告警動態", "body": rows + more + f"。今日達閾值累計 {hits_total} 次。"})
    if banned is not None:
        sections.append({"h": "安全", "body": f"portscan-autoban 目前封鎖 {int(banned)} 個來源;Cowrie/絆線詳見安全面板。"})
    rss = rss_section(cfg)
    if rss:
        sections.append(rss)

    ai_input = json.dumps({"targets": [up_ok, up_total], "firing": firing, "banned": banned,
                           "today_hits": hits_total}, ensure_ascii=False, default=str)
    verdict = deepseek_call(cfg, model_fast(cfg), BRIEF_SYSTEM_PROMPT, ai_input,
                            max_tokens=600, timeout=40)
    model_tag = model_fast(cfg) if verdict else "template"
    if not verdict:
        verdict = ("有告警在燒,進告警中心逐條確認;其餘指標詳見各模塊。" if firing
                   else "全站平靜,無需介入。")
    sections.append({"h": "總評", "body": verdict})

    brief = {"issue_no": issue_no, "date": date, "title": "今日快報", "sections": sections,
             "generated_at": f"generated {now.strftime('%H:%M')} by CT260 notifier · {model_tag}"}
    BRIEF_FILE.parent.mkdir(parents=True, exist_ok=True)
    BRIEF_FILE.write_text(json.dumps(brief, ensure_ascii=False, indent=1))
    BRIEF_STATE_FILE.write_text(json.dumps({"date": date, "issue_no": issue_no}))
    log(f"brief written: 第{issue_no}期 {date} sections={len(sections)}")

    if "--dry-run" in sys.argv:
        log("brief dry-run: 不投遞 CT201")
        return
    # 投遞:hl-push(scp→pve24→pct push→cp-over)+ 日期副本 + 30 期保留
    push = subprocess.run([str(HOME / ".local/bin/hl-push"), "ct201",
                           str(BRIEF_FILE), "/opt/portal/data/brief.json"],
                          capture_output=True, text=True, timeout=90)
    if push.returncode != 0:
        log(f"brief push failed rc={push.returncode}: {push.stderr.strip()[:200]}")
        sys.exit(1)
    housekeeping = ("cp /opt/portal/data/brief.json /opt/portal/data/brief-"
                    + now.strftime("%Y%m%d") + ".json && "
                    "find /opt/portal/data -name 'brief-2*.json' -mtime +30 -delete")
    subprocess.run(["ssh", "pve24-auto", "sudo pct exec 201 -- bash -c " + shlex.quote(housekeeping)],
                   capture_output=True, text=True, timeout=30)
    log("brief pushed -> CT201 /opt/portal/data/ (含日期副本+30期清理)")


def selftest(cfg):
    """--selftest [--critical]：走正式路由驗證分流。warning=只 TG；critical=ntfy(urgent)先發+TG(含註記)。"""
    if "--dry-run" in sys.argv:
        log("selftest 必然真發，與 --dry-run 互斥；中止")
        return
    sev = "critical" if "--critical" in sys.argv else "warning"
    fake = {
        "labels": {"alertname": "NotifySelfTest", "severity": sev,
                   "instance": "ct260.home.arpa", "job": "selftest"},
        "annotations": {"summary": "Notifier self-test",
                        "description": "CT260 -> Telegram path end-to-end check."},
        "startsAt": datetime.now(timezone.utc).isoformat(),
    }
    ch = route_channels("firing", sev)
    ntfy_ok = ntfy_try_publish_firing(cfg, fake) if (CH_NTFY in ch and ntfy_enabled(cfg)) else None
    telegram_send(cfg, build_firing_msg(cfg, fake, ntfy_ok=ntfy_ok))
    log(f"selftest({sev}) sent -> {'+'.join(sorted(ch))}"
        + (f" ntfy_ok={ntfy_ok}" if ntfy_ok is not None else ""))


def main():
    cfg = load_config()
    if "TELEGRAM_BOT_TOKEN" not in cfg or "TELEGRAM_CHAT_ID" not in cfg:
        log("missing TELEGRAM_BOT_TOKEN/CHAT_ID in config; aborting")
        sys.exit(1)

    if "--selftest" in sys.argv:
        selftest(cfg)
        return

    if "--write-brief" in sys.argv:
        write_brief(cfg)
        return

    if "--daily-report" in sys.argv:
        daily_report(cfg)
        return

    sevs = {s.strip() for s in cfg.get("NOTIFY_SEVERITIES", "warning,critical").split(",") if s.strip()}
    dry = "--dry-run" in sys.argv

    try:
        alerts = fetch_alerts()
    except Exception as e:
        log(f"fetch error: {type(e).__name__}: {str(e)[:200]}")
        # dry-run 不動計數器：避免把「恰好第 3 次」的觸發沿吃掉（管線異常告警用等號判定）
        n = bump_fetch_failures() if not dry else read_fetch_failures()
        if n == FETCH_FAIL_ALERT_AFTER and not dry:
            try:
                telegram_send(cfg, "🚨 告警管線異常：CT260 已連續 3 次無法讀取 CT201 Alertmanager"
                                   "（經 pve24→pct）。期間 Prometheus 告警不會外送 Telegram；"
                                   "站外看門狗 watchdog-ct201 仍獨立監控 CT201。")
                log("pipeline-failure alert sent (3 consecutive fetch errors)")
            except Exception as e2:
                log(f"pipeline-failure alert send failed: {type(e2).__name__}: {str(e2)[:150]}")
        sys.exit(1)
    prev_fails = read_fetch_failures()
    if prev_fails:
        if prev_fails >= FETCH_FAIL_ALERT_AFTER and not dry:
            try:
                telegram_send(cfg, "✅ 告警管線恢復：CT201 Alertmanager 又可正常讀取"
                                   f"（先前連續失敗 {prev_fails} 次）。")
                log(f"pipeline recovered after {prev_fails} consecutive fetch errors")
            except Exception as e2:
                log(f"pipeline-recovery send failed: {type(e2).__name__}: {str(e2)[:150]}")
        if not dry:  # dry-run 不清計數器，恢復通知留給下一輪真跑發
            reset_fetch_failures()

    current = {}
    for a in alerts:
        st = a.get("status", {})
        if st.get("state") != "active":
            continue
        if st.get("silencedBy") or st.get("inhibitedBy"):
            continue
        labels = a.get("labels", {})
        if labels.get("severity") not in sevs:
            continue
        fp = a.get("fingerprint")
        if not fp:
            continue
        current[fp] = a

    prev = load_state()
    new_fp = [fp for fp in current if fp not in prev]
    resolved_fp = [fp for fp in prev if fp not in current]
    persist_fp = [fp for fp in current if fp in prev]

    has_key = bool(cfg.get("DEEPSEEK_API_KEY"))
    try:
        batch_threshold = int(cfg.get("AI_BATCH_THRESHOLD", "3"))
    except ValueError:
        batch_threshold = 3
    try:
        escalate_after = int(cfg.get("ESCALATE_AFTER_MIN", "5")) * 60
    except ValueError:
        escalate_after = 300
    flash_sevs = {s.strip() for s in cfg.get("FLASH_SEVERITIES",
                  cfg.get("NOTIFY_SEVERITIES", "warning,critical")).split(",") if s.strip()}
    now = datetime.now(timezone.utc)

    def firing_seconds(alert):
        try:
            st = datetime.fromisoformat(alert.get("startsAt", "").replace("Z", "+00:00"))
            return (now - st).total_seconds()
        except Exception:
            return 0.0

    def label_true(alert, k):
        return str((alert.get("labels", {}) or {}).get(k, "")).lower() == "true"

    # daily threshold-hit counters (for the 20:00 report)
    if not dry:
        bump_counts([current[fp] for fp in new_fp])

    sent = 0
    escalated = {}  # fp -> True if Tier2 already sent (carried in state)

    # --- Tier 1: new firing -> fast triage line ---
    batch_ai = has_key and len(new_fp) >= batch_threshold
    for fp in new_fp:
        a = current[fp]
        sev = (a.get("labels", {}) or {}).get("severity")
        ch = route_channels("firing", sev)
        # 動作頻道最先發（趕在 Tier1 DeepSeek 之前，按鈕不等 AI）；實際結果餵進 TG 註記；
        # 例外/失敗都不擋 TG（鐵則）。未設定 ntfy 時 ntfy_ok 維持 None=不加註記。
        ntfy_ok = None
        if not dry and CH_NTFY in ch and ntfy_enabled(cfg):
            ntfy_ok = ntfy_try_publish_firing(cfg, a)
        flash = None
        if has_key and sev in flash_sevs and not batch_ai and not dry:
            flash = flash_oneliner(cfg, a)
        msg = build_firing_msg(cfg, a, flash_line=flash, ntfy_ok=ntfy_ok)
        if dry:
            log(f"[dry-run] FIRING -> {'+'.join(sorted(ch))}: {msg!r}")
        else:
            try:
                telegram_send(cfg, msg); sent += 1
            except Exception as e:
                log(f"telegram send (firing) failed: {type(e).__name__}: {str(e)[:150]}")
        # ai_analyze:"true" -> escalate immediately on first fire（analysis=閱讀型，查路由表；現行僅 TG 發送器）
        if has_key and label_true(a, "ai_analyze") and not dry and CH_TG in route_channels("analysis"):
            an = deep_analysis(cfg, a)
            if an:
                try:
                    telegram_send(cfg, f"🔬 深度分析 [{(sev or '').upper()}] "
                                       f"{a['labels'].get('alertname')}\n{an}"); sent += 1
                    escalated[fp] = True
                except Exception as e:
                    log(f"telegram send (deep-immediate) failed: {type(e).__name__}: {str(e)[:150]}")

    # --- batch correlation (deep model) when several fire at once ---
    if batch_ai and not dry and CH_TG in route_channels("analysis"):
        analysis = deepseek_batch(cfg, [current[fp] for fp in new_fp])
        if analysis:
            try:
                telegram_send(cfg, f"🔬 關聯分析（同時 {len(new_fp)} 個告警）\n{analysis}"); sent += 1
            except Exception as e:
                log(f"telegram send (batch) failed: {type(e).__name__}: {str(e)[:150]}")

    # --- Tier 2: persisting alert crosses escalation threshold (continuous firing) ---
    n_escalated = 0
    for fp in persist_fp:
        a = current[fp]
        p = prev.get(fp, {})
        # reset escalation if the firing restarted (startsAt changed = flap/re-fire)
        was_escalated = bool(p.get("escalated")) and p.get("startsAt") == a.get("startsAt")
        if was_escalated:
            escalated[fp] = True
            continue
        if has_key and CH_TG in route_channels("analysis") and firing_seconds(a) >= escalate_after:
            mins = int(firing_seconds(a) // 60)
            sev = (a.get("labels", {}) or {}).get("severity", "")
            if dry:
                log(f"[dry-run] ESCALATE {a['labels'].get('alertname')} (firing {mins}m)")
                escalated[fp] = True
            else:
                an = deep_analysis(cfg, a)
                if an:
                    try:
                        telegram_send(cfg, f"🔬 深度分析 [{sev.upper()}] "
                                           f"{a['labels'].get('alertname')}（已持續 {mins}m）\n{an}")
                        sent += 1; n_escalated += 1
                        escalated[fp] = True
                    except Exception as e:
                        log(f"telegram send (escalate) failed: {type(e).__name__}: {str(e)[:150]}")

    # --- resolved ---
    for fp in resolved_fp:
        msg = build_resolved_msg(prev[fp])
        ch = route_channels("resolved", (prev[fp] or {}).get("severity"))
        if dry:
            log(f"[dry-run] RESOLVED -> {'+'.join(sorted(ch))}: {msg!r}")
        else:
            try:
                telegram_send(cfg, msg); sent += 1
            except Exception as e:
                log(f"telegram send (resolved) failed: {type(e).__name__}: {str(e)[:150]}")
            if CH_NTFY in ch:
                try:
                    ntfy_publish_resolved(cfg, prev[fp])  # 路由表現行=不推（閱讀型）
                except Exception as e:
                    log(f"ntfy publish (resolved) failed: {type(e).__name__}: {str(e)[:120]}")

    # persist compact state (carry escalated + startsAt for continuity)
    new_state = {}
    for fp, a in current.items():
        labels = a.get("labels", {})
        new_state[fp] = {
            "alertname": labels.get("alertname"),
            "severity": labels.get("severity"),
            "instance": labels.get("instance"),
            "startsAt": a.get("startsAt"),
            "escalated": bool(escalated.get(fp)),
        }
    if not dry:
        save_state(new_state)

    if new_fp or resolved_fp or n_escalated:
        log(f"firing={len(new_fp)} resolved={len(resolved_fp)} escalated={n_escalated} "
            f"sent={sent} active={len(current)}")


if __name__ == "__main__":
    main()
