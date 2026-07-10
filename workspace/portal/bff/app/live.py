"""live 模式:Prometheus / Alertmanager / Loki / Kuma 唯讀查詢(§4/§8)。

上游走 compose 內網(Kuma 例外:獨立 compose,經 host.docker.internal);
PC40 健檢走既有防火牆放行(Allow/SNAT-Monitor-To-PC40-Health-18080)。
全部唯讀、無寫入;外層 providers 有 3–10s 快取 + 30s negative cache。
M2:新增 services(Kuma 綠燈)/security/game/host_detail 與告警 24h 時間軸。
"""
import asyncio
import os
import re
import time
from datetime import datetime, timedelta, timezone

import httpx

from .providers import UpstreamError
from .registry import (BY_SLUG, DASH_OVERVIEW, GRAFANA_LAN, HOSTS,
                       SERVICE_GROUPS, services_of_host)

PROM = os.environ.get("PROM_URL", "http://prometheus:9090")
AM = os.environ.get("AM_URL", "http://alertmanager:9093")
LOKI = os.environ.get("LOKI_URL", "http://loki:3100")
PC40_HEALTH = os.environ.get("PC40_HEALTH", "http://192.168.40.4:18080/")
KUMA_URL = os.environ.get("KUMA_URL", "http://host.docker.internal:3001")
KUMA_API_KEY = os.environ.get("KUMA_API_KEY", "")
MCSM_URL = os.environ.get("MCSM_URL", "http://10.70.70.20:23333")
MCSM_API_KEY = os.environ.get("MCSM_API_KEY", "")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _human_secs(s: float) -> str:
    s = int(s)
    d, h, m = s // 86400, (s % 86400) // 3600, (s % 3600) // 60
    if d >= 3:
        return f"{d}d"
    if d:
        return f"{d}d {h:02d}h"
    if h:
        return f"{h}h {m:02d}m"
    return f"{m}m"


async def _promq(client: httpx.AsyncClient, query: str) -> list[dict]:
    try:
        r = await client.get(f"{PROM}/api/v1/query", params={"query": query})
        r.raise_for_status()
        body = r.json()
    except Exception as e:  # noqa: BLE001 —— 一律折成 UpstreamError,錯誤格式統一
        raise UpstreamError(f"Prometheus 查詢失敗: {type(e).__name__}") from e
    if body.get("status") != "success":
        raise UpstreamError(f"Prometheus 回應異常: {body.get('error', '?')}")
    return body["data"]["result"]


async def _promq_range(client: httpx.AsyncClient, query: str,
                       seconds: int, step: int, end: float | None = None) -> list[dict]:
    end = end if end is not None else time.time()
    try:
        r = await client.get(f"{PROM}/api/v1/query_range",
                             params={"query": query, "start": end - seconds,
                                     "end": end, "step": step})
        r.raise_for_status()
        body = r.json()
    except Exception as e:  # noqa: BLE001
        raise UpstreamError(f"Prometheus range 查詢失敗: {type(e).__name__}") from e
    if body.get("status") != "success":
        raise UpstreamError(f"Prometheus 回應異常: {body.get('error', '?')}")
    return body["data"]["result"]


def _series(matrix: list[dict]) -> list[list[float]]:
    """單序列 matrix → [[ts,val]…];空結果回 []。"""
    if not matrix:
        return []
    return [[float(t), round(float(v), 2)] for t, v in matrix[0]["values"]]


def _scalar(vec: list[dict]) -> float | None:
    return float(vec[0]["value"][1]) if vec else None


def _by_job(result: list[dict]) -> dict[str, float]:
    out: dict[str, float] = {}
    for r in result:
        j = r["metric"].get("job")
        if j is not None:
            out[j] = float(r["value"][1])
    return out


async def _pc40_alive(client: httpx.AsyncClient) -> bool:
    try:
        r = await client.get(PC40_HEALTH, timeout=1.5)
        return r.status_code == 200
    except Exception:  # noqa: BLE001 —— 拒連/逾時=關機,屬正常狀態非錯誤
        return False


# ---------------- overview(M1;M2 增 slug) ----------------

async def overview() -> dict:
    async with httpx.AsyncClient(timeout=5.0) as client:
        (up_vec, cpu, mem, disk, boot, pve, pc40, snmp_upt, ports_up, ports_all,
         ow_cpu, ow_mem, ow_disk, ow_upt) = await asyncio.gather(
            _promq(client, "up"),
            _promq(client, '100 * (1 - avg by (job)(rate(node_cpu_seconds_total{mode="idle"}[5m])))'),
            _promq(client, '100 * avg by (job)(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'),
            # mountpoint 放寬到 NAS 型佈局(UGOS 根=/rootfs、資料=/volumeN;0.9.2)
            # ——NAS 取「最滿掛載點」為 disk 讀數(volume 滿比 rootfs 滿更致命)
            _promq(client, '100 * max by (job)(1 - node_filesystem_avail_bytes{mountpoint=~"/|/rootfs|/volume[0-9]+"} / node_filesystem_size_bytes{mountpoint=~"/|/rootfs|/volume[0-9]+"})'),
            _promq(client, "time() - max by (job)(node_boot_time_seconds)"),
            _promq(client, "pve_up"),
            _pc40_alive(client),
            # SNMP 類 bare 主機(switch3f,待辦25):sysUpTime 為 timeticks(1/100 秒)
            _promq(client, "max by (job)(sysUpTime) / 100"),
            _promq(client, "count by (job)(ifOperStatus == 1)"),
            _promq(client, "count by (job)(ifOperStatus)"),
            # openwrt textfile 指標(0.9.2 補接:M1 起 bare 只走 SNMP 路徑,openwrt 卡一直空)
            _promq(client, '100 * (1 - sum by (job)(rate(openwrt_cpu_seconds_total{mode="idle"}[5m])) / sum by (job)(rate(openwrt_cpu_seconds_total[5m])))'),
            _promq(client, '100 * (1 - max by (job)(openwrt_memory_bytes{type="available"}) / max by (job)(openwrt_memory_bytes{type="total"}))'),
            _promq(client, '100 * max by (job)(1 - openwrt_filesystem_available_bytes{mountpoint="/"} / openwrt_filesystem_size_bytes{mountpoint="/"})'),
            _promq(client, "max by (job)(openwrt_uptime_seconds)"),
        )

    up = _by_job(up_vec)
    cpu, mem, disk, boot = _by_job(cpu), _by_job(mem), _by_job(disk), _by_job(boot)
    snmp_upt, ports_up, ports_all = _by_job(snmp_upt), _by_job(ports_up), _by_job(ports_all)
    # openwrt 讀數併入同名 dict(單位一致:% 與 uptime 秒),下游渲染零分叉
    cpu.update(_by_job(ow_cpu)); mem.update(_by_job(ow_mem))
    disk.update(_by_job(ow_disk)); boot.update(_by_job(ow_upt))
    pve_up = {r["metric"].get("id"): float(r["value"][1]) for r in pve}

    hosts = []
    crit_notes, warn_notes = [], []
    for h in HOSTS:
        name, job = h["name"], h.get("job")
        state, note, uptime = "unk", h.get("note", ""), "—"
        c = m = dk = None
        if h.get("pending") and up.get(job or "", 0) < 1:
            note = h["pending"]
        elif h.get("http"):
            state = "ok" if pc40 else "unk"
            note = "health OK" if pc40 else "關機(正常)"
            uptime = "on" if pc40 else "off"
        elif job and job in up:
            if up[job] >= 1:
                state = "ok"
                # 0.9.2 統一取數:dict 有值就用(openwrt 靠上方併入的 openwrt_* 讀數;
                # switch3f 無 cpu/mem 自然缺席),bare 只決定 SNMP 補充項
                c = round(cpu[job]) if job in cpu else None
                m = round(mem[job]) if job in mem else None
                dk = round(disk[job]) if job in disk else None
                uptime = _human_secs(boot[job]) if job in boot else "—"
                if h.get("bare"):
                    # SNMP bare 主機(switch3f,待辦25):uptime 與埠數各自獨立,缺一不擋另一
                    if job in snmp_upt:
                        uptime = _human_secs(snmp_upt[job])
                    if job in ports_all:
                        note = f"{int(ports_up.get(job, 0))}/{int(ports_all[job])} 埠 up"
            else:
                # exporter down:主機可能還活著;有 pve id 就用宿主視角判生死
                g = pve_up.get(h.get("pve", ""))
                if g is not None and g < 1:
                    state = "unk" if h.get("off_ok") else "crit"
                    note = h.get("note") or ("關機" if h.get("off_ok") else "停機(非預期)")
                    uptime = "off"
                    if state == "crit":
                        crit_notes.append(f"{name} 停機")
                else:
                    state = "warn"
                    note = "exporter 離線"
                    warn_notes.append(f"{name} exporter 離線")
        elif h.get("pve"):
            g = pve_up.get(h["pve"])
            if g is None:
                state, note = "unk", "pve-exporter 無資料"
            elif g >= 1:
                state, note, uptime = "ok", h.get("note", ""), "on"
            else:
                state = "unk" if h.get("off_ok") else "crit"
                note = h.get("note") or "停機"
                uptime = "off"
                if state == "crit":
                    crit_notes.append(f"{name} 停機")
        hosts.append({"slug": h["slug"], "name": name, "vlan": h["vlan"], "up": state,
                      "cpu": c, "mem": m, "disk": dk, "uptime": uptime, "note": note})

    total = len(up_vec)
    n_up = sum(1 for r in up_vec if float(r["value"][1]) >= 1)
    if total and n_up < total:
        warn_notes.append(f"{total - n_up} 個 target 離線")

    if crit_notes:
        summary = {"state": "crit", "text": "、".join(crit_notes[:3]) + "——需要處理"}
    elif warn_notes:
        summary = {"state": "warn", "text": f"{len(warn_notes)} 個注意:" + "、".join(warn_notes[:3])}
    else:
        summary = {"state": "ok", "text": "全站正常"}

    return {
        "summary": summary,
        "hosts": hosts,
        "services_ok": None,           # providers 以 services 快取補真值
        "alerts_firing": -1,           # 前端以 /api/alerts 為準;此欄不重複查
        "targets": {"up": n_up, "total": total},
        "generated_at": _now(),
    }


# ---------------- alerts(M1;M2 增 24h 時間軸) ----------------

def _humanize_since(start: str) -> str:
    try:
        t = datetime.fromisoformat(start.replace("Z", "+00:00"))
        return _human_secs((datetime.now(timezone.utc) - t).total_seconds())
    except ValueError:
        return "?"


def _fill_buckets(series: list[list[float]], end: float, seconds: int, step: int) -> list[list[float]]:
    """把稀疏 range 結果補滿等距桶(count() 對空向量整步缺樣本=0 firing,補 0 才誠實)。"""
    base = end - seconds
    have = {round((t - base) / step): v for t, v in series}
    return [[base + k * step, have.get(k, 0)] for k in range(seconds // step + 1)]


async def alerts() -> dict:
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            fr = await client.get(f"{AM}/api/v2/alerts",
                                  params={"active": "true", "silenced": "false", "inhibited": "false"})
            fr.raise_for_status()
            fr_body = fr.json()
            sr = await client.get(f"{AM}/api/v2/silences")
            sr.raise_for_status()
            sr_body = sr.json()
        except Exception as e:  # noqa: BLE001 —— 含 200 非 JSON body,一律折成 UpstreamError
            raise UpstreamError(f"Alertmanager 查詢失敗: {type(e).__name__}") from e
        try:
            pr = await client.get(f"{PROM}/api/v1/alerts")
            pending_raw = [a for a in pr.json()["data"]["alerts"] if a.get("state") == "pending"]
        except Exception:  # noqa: BLE001 —— pending 屬加值資訊,失敗不整包壞
            pending_raw = []
        try:
            tl_end = time.time()
            tl = _fill_buckets(_series(await _promq_range(
                client, 'count(ALERTS{alertstate="firing"})', 24 * 3600, 1800, end=tl_end)),
                tl_end, 24 * 3600, 1800)
        except UpstreamError:  # 時間軸屬加值資訊,失敗不整包壞
            tl = []

    def sev(labels: dict) -> str:
        s = labels.get("severity", "info")
        return s if s in ("critical", "warning") else "info"

    firing = [{
        "name": a["labels"].get("alertname", "?"),
        "severity": sev(a["labels"]),
        "description": a.get("annotations", {}).get("summary")
                       or a.get("annotations", {}).get("description", ""),
        "instance": a["labels"].get("instance", ""),
        "since": _humanize_since(a.get("startsAt", "")),
    } for a in fr.json()]

    pending = [{
        "name": a["labels"].get("alertname", "?"),
        "severity": sev(a["labels"]),
        "description": a.get("annotations", {}).get("summary", ""),
        "instance": a["labels"].get("instance", ""),
        "since": _humanize_since(a.get("activeAt", "")),
    } for a in pending_raw]

    silences = [{
        "comment": s.get("comment", ""),
        "matchers": ", ".join(f"{m['name']}={m['value']}" for m in s.get("matchers", [])),
        "ends_at": (s.get("endsAt", "") or "")[:10],
    } for s in sr.json() if s.get("status", {}).get("state") == "active"]

    sev_rank = {"critical": 0, "warning": 1, "info": 2}
    firing.sort(key=lambda a: sev_rank.get(a["severity"], 3))

    return {"firing": firing, "pending": pending, "silences": silences,
            "timeline_24h": tl, "generated_at": _now()}


# ---------------- services(M2:註冊表 × Kuma 綠燈) ----------------

_KUMA_LINE = re.compile(r'^monitor_status\{(?P<labels>[^}]*)\}\s+(?P<val>[\d.]+)')
_KUMA_NAME = re.compile(r'monitor_name="(?P<name>[^"]*)"')


async def _kuma_status() -> dict[str, int]:
    """Kuma /metrics(API key,唯讀)→ {monitor_name(lower): status};1=up。"""
    async with httpx.AsyncClient(timeout=4.0, auth=("", KUMA_API_KEY)) as client:
        try:
            r = await client.get(f"{KUMA_URL}/metrics")
        except Exception as e:  # noqa: BLE001
            raise UpstreamError(f"Kuma 失聯: {type(e).__name__}") from e
    if r.status_code in (401, 403):
        raise UpstreamError("Kuma 憑證失效(401/403)——請輪替 API key")
    if r.status_code != 200:
        raise UpstreamError(f"Kuma 回應異常: HTTP {r.status_code}")
    out: dict[str, int] = {}
    for line in r.text.splitlines():
        m = _KUMA_LINE.match(line)
        if not m:
            continue
        n = _KUMA_NAME.search(m.group("labels"))
        if n:
            out[n.group("name").strip().lower()] = int(float(m.group("val")))
    return out


async def services() -> dict:
    """服務目錄:靜態表永遠可回(M2 §3:此端點不因 Kuma 掛而 502)。"""
    kuma: dict[str, int] | None = None
    note = None
    if KUMA_API_KEY:
        try:
            kuma = await _kuma_status()
        except UpstreamError as e:
            note = str(e)
    else:
        note = "Kuma API key 未設定——綠燈待接(待辦49 決策4)"

    groups = []
    for g in SERVICE_GROUPS:
        items = []
        for i in g["items"]:
            ok = None
            if kuma is not None and i.get("kuma"):
                # Kuma monitor_status:1=up、0=down;2(pending)/3(maintenance)不裝紅也不裝綠
                s = kuma.get(i["kuma"])
                ok = True if s == 1 else False if s == 0 else None
            items.append({"name": i["name"], "url": i.get("url"), "url_hl": i.get("url_hl"),
                          "pc40": i.get("pc40", False), "phone": i.get("phone", False),
                          "host": i.get("host"), "kuma_ok": ok, "note": i.get("note")})
        groups.append({"group": g["group"], "items": items})
    return {"groups": groups, "kuma_note": note, "generated_at": _now()}


# ---------------- security(M2) ----------------

async def security() -> dict:
    async with httpx.AsyncClient(timeout=5.0) as client:
        banned, trend, trip24, tripd, cow_up = await asyncio.gather(
            _promq(client, "sum(portscan_autoban_banned_ips)"),
            _promq_range(client, "sum(portscan_autoban_banned_ips)", 24 * 3600, 3600),
            _promq(client, "sum(increase(openwrt_ssh22_tripwire_total[24h]))"),
            _promq_range(client, "sum(increase(openwrt_ssh22_tripwire_total[1d]))",
                         30 * 86400, 86400),
            _promq(client, 'up{job="cowrie-exporter"}'),
        )
        cowrie: dict
        if _scalar(cow_up) == 1:
            cnt, top = await asyncio.gather(
                _promq(client, "sum(increase(cowrie_sessions_total[24h]))"),
                _promq(client, "topk(5, cowrie_top_source_ip_sessions)"),
            )
            def _ip(metric: dict) -> str:
                for k in ("ip", "src_ip", "source_ip", "address", "source"):
                    if k in metric:
                        return metric[k]
                return "?"
            cowrie = {"count": int(_scalar(cnt) or 0),
                      "top_src": [{"ip": _ip(r["metric"]), "n": int(float(r["value"][1]))}
                                  for r in top]}
        else:
            # 誠實態(M2 §2):源=VM300 cowrie-exporter,停機時不擺舊數據
            cowrie = {"offline": True, "hint": "資料源離線(VM300 停機)——重啟屬使用者裁決"}

    # 誠實區分:整窗無樣本(exporter 沒數據)→ None;有樣本但全 0 → 零事件 ≥30 天
    samples = _series(tripd)
    hits = [(t, v) for t, v in samples if v > 0.5]
    now = time.time()
    if not samples:
        days_clean, last_hit = None, None
    elif hits:
        last_ts = hits[-1][0]
        days_clean = max(0, int((now - last_ts) // 86400))
        last_hit = datetime.fromtimestamp(last_ts, timezone.utc).date().isoformat()
    else:
        days_clean, last_hit = 30, None  # 30 天窗內零事件;顯示「≥30 天」

    return {
        "autoban_today": int(_scalar(banned) or 0),  # 現行封鎖 IP 數(gauge)
        "autoban_trend_24h": _series(trend),
        "tripwire": {"today": int(_scalar(trip24) or 0),
                     "last_hit": last_hit, "days_clean": days_clean},
        "cowrie": cowrie,
        "generated_at": _now(),
    }


# ---------------- game(M2:Prometheus 為主;玩家數=MCSM 使用者級 API,2026-07-08 實測接上) ----------------

async def game() -> dict:
    async with httpx.AsyncClient(timeout=5.0) as client:
        pve, exp, cpu, mem = await asyncio.gather(
            _promq(client, 'pve_up{id="lxc/100"}'),
            _promq(client, 'up{job=~"mc-server-node|ct102-mc-proxy-node"}'),
            _promq(client, '100 * (1 - avg by (job)(rate(node_cpu_seconds_total{mode="idle",job=~"mc-server-node|ct102-mc-proxy-node"}[5m])))'),
            _promq(client, '100 * avg by (job)(1 - node_memory_MemAvailable_bytes{job=~"mc-server-node|ct102-mc-proxy-node"} / node_memory_MemTotal_bytes)'),
        )
    up, cpu, mem = _by_job(exp), _by_job(cpu), _by_job(mem)
    running = (_scalar(pve) or 0) >= 1

    players, names, note = None, None, None
    instance_uuid, daemon_id = None, None  # 網頁終端 URL 與控制解析用(待辦49 0.8.0)
    # MCSM 實例狀態碼 → portal 語彙。instance_state 的權威來源是這個,不是 pve_up:
    # LXC 容器存活 ≠ MC 進程在跑——MCSM stop 只停 Java,容器照常,pve_up 永遠 1,
    # 「stopped→啟動鍵」路徑會不可達(審查確認項 2026-07-09)
    _MCSM_STATE = {-1: "busy", 0: "stopped", 1: "stopping", 2: "starting", 3: "running"}
    mcsm_state = None
    if MCSM_API_KEY:
        try:
            async with httpx.AsyncClient(timeout=4.0) as client:
                # /api/overview 是 admin 端點;API-user 為 permission-1 唯讀帳號,
                # 走自身資料端點只看得到被指派的實例(Fabric-MC)——權限最小化
                r = await client.get(f"{MCSM_URL}/api/auth/",
                                     params={"advanced": "true", "apikey": MCSM_API_KEY},
                                     headers={"X-Requested-With": "XMLHttpRequest"})
            if r.status_code in (401, 403):
                note = "MCSManager 憑證失效(401/403)——請輪替 API key"
            elif r.status_code == 200:
                insts = (r.json().get("data") or {}).get("instances") or []
                inst = next((i for i in insts if i.get("nickname") == "Fabric-MC"),
                            insts[0] if insts else None)
                if inst is None:
                    note = "MCSM key 可用但無實例指派——面板把 Fabric-MC 指派給 API-user 即接通"
                else:
                    # 終端機/控制都靠這兩個 id 定位實例(前端組終端 URL;控制由 BFF 自解析)
                    instance_uuid = inst.get("instanceUuid") or None
                    daemon_id = inst.get("daemonId") or None
                    mcsm_state = _MCSM_STATE.get(inst.get("status"))
                    info = inst.get("info") or {}
                    if info.get("mcPingOnline"):
                        players = int(info.get("currentPlayers") or 0)
                        # mcping 只給人數不給名單;player_names 維持 None(前端已誠實顯示)
                    else:
                        note = "MCSM mcping 未上線——面板實例類型設 Minecraft Java 後自動有玩家數"
            else:
                note = f"MCSManager 回應異常: HTTP {r.status_code}"
        except Exception as e:  # noqa: BLE001
            note = f"MCSManager 失聯: {type(e).__name__}"
    else:
        note = "MCSM API key 未設定——玩家數待接(待辦49 決策4)"

    def _host(job: str, label: str) -> dict:
        return {"name": label, "up": up.get(job, 0) >= 1,
                "cpu": round(cpu[job]) if job in cpu else None,
                "mem": round(mem[job]) if job in mem else None}

    return {
        "server_up": up.get("mc-server-node", 0) >= 1,
        # MCSM 權威狀態優先;拿不到(key 未設/失聯)才退回 LXC 存活的粗略推定
        "instance_state": mcsm_state or ("running" if running else "stopped"),
        "players_online": players,
        "player_names": names,
        "instance_uuid": instance_uuid,
        "daemon_id": daemon_id,
        "hosts": [_host("mc-server-node", "ct100 · backend"),
                  _host("ct102-mc-proxy-node", "ct102 · velocity")],
        "note": note,
        "generated_at": _now(),
    }


# ---------------- host detail(M2 L2) ----------------

async def _loki_tail(host_label: str) -> list[dict] | None:
    end_ns = int(time.time() * 1e9)
    start_ns = end_ns - 15 * 60 * int(1e9)
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.get(f"{LOKI}/loki/api/v1/query_range",
                                 params={"query": f'{{host="{host_label}"}}',
                                         "start": start_ns, "end": end_ns,
                                         "limit": 50, "direction": "backward"})
            r.raise_for_status()
            data = r.json()["data"]["result"]
    except Exception:  # noqa: BLE001 —— 日誌尾巴屬加值資訊,失敗回 null 不整包壞
        return None
    rows: list[tuple[int, str]] = []
    for stream in data:
        rows.extend((int(t), line) for t, line in stream["values"])
    rows.sort(reverse=True)
    return [{"ts": datetime.fromtimestamp(t / 1e9, timezone.utc).isoformat(timespec="seconds"),
             "line": line[:300]} for t, line in rows[:50]]


# ---------------- power(待辦49 決策2;pve24 upsc→textfile→pve-node:9100) ----------------

_TZ_TAIPEI = timezone(timedelta(hours=8))  # 事件時戳用;台灣無夏令,固定偏移即可


def _ups_events(res: list[dict]) -> list[dict]:
    """on_battery 7 天序列 → 轉換事件(新的在前)。跨資料缺口(管線斷)不判轉換。"""
    if not res:
        return []
    events = []
    prev, prev_ts = None, 0.0
    for ts, v in res[0].get("values", []):
        cur = str(v) == "1"
        if prev is not None and cur != prev and ts - prev_ts <= 900:
            t = datetime.fromtimestamp(ts, _TZ_TAIPEI).strftime("%m-%d %H:%M")
            events.append({"ts": t, "text": "轉電池供電(市電中斷)" if cur else "市電恢復"})
        prev, prev_ts = cur, ts
    return list(reversed(events))[:20]


async def power() -> dict:
    """指標缺席=管線未上線→pending 誠實態;upsc 失敗/資料過期同樣不裝正常。"""
    async with httpx.AsyncClient(timeout=6.0) as client:
        ok, onb, lb, charge, runtime, load, volt, nominal, stale, ev = await asyncio.gather(
            _promq(client, "nut_upsc_ok"),
            _promq(client, "nut_ups_on_battery"),
            _promq(client, "nut_battery_low"),
            _promq(client, "nut_battery_charge_percent"),
            _promq(client, "nut_battery_runtime_seconds"),
            _promq(client, "nut_ups_load_percent"),
            _promq(client, "nut_input_voltage_volts"),
            _promq(client, "nut_ups_realpower_nominal_watts"),
            _promq(client, 'time() - node_textfile_mtime_seconds{file=~".*ups[.]prom"}'),
            _promq_range(client, "nut_ups_on_battery", 7 * 24 * 3600, 300),
        )

    def val(vec: list[dict]) -> float | None:
        return float(vec[0]["value"][1]) if vec else None

    if val(onb) is None:
        return {"pending": True,
                "hint": "UPS 指標管線待上線——pve24 執行 finish-ups-metrics.sh(upsc→textfile)後此頁自動有數據",
                "generated_at": _now()}
    if val(ok) == 0:
        return {"pending": True,
                "hint": "pve24 upsc 讀不到 UPS(ups0@192.168.100.2)——查 DXP upsd / USB 線 / VLAN100 直連",
                "generated_at": _now()}
    st = val(stale)
    if st is not None and st > 300:
        return {"pending": True,
                "hint": f"UPS 數據已 {int(st // 60)} 分鐘未更新(pve24 cron/upsc 中斷)——不擺舊數據裝正常",
                "generated_at": _now()}
    load_v, nom = val(load), val(nominal)
    return {
        "on_battery": val(onb) == 1,
        "battery_low": val(lb) == 1,
        "charge": round(val(charge)) if val(charge) is not None else None,
        "load": round(load_v) if load_v is not None else None,
        "runtime_s": int(val(runtime)) if val(runtime) is not None else None,
        "input_v": val(volt),
        "watts": round(load_v * nom / 100) if load_v is not None and nom else None,
        "events_7d": _ups_events(ev),
        "generated_at": _now(),
    }


async def host_detail(slug: str) -> dict:
    h = BY_SLUG.get(slug)
    if h is None:
        raise KeyError(slug)
    job = h.get("job")
    metrics: dict[str, list] = {"cpu": [], "mem": [], "disk": [], "net": []}
    if job and not h.get("bare"):
        q = {
            "cpu": f'100 * (1 - avg(rate(node_cpu_seconds_total{{mode="idle",job="{job}"}}[5m])))',
            "mem": f'100 * avg(1 - node_memory_MemAvailable_bytes{{job="{job}"}} / node_memory_MemTotal_bytes{{job="{job}"}})',
            "disk": f'100 * max(1 - node_filesystem_avail_bytes{{mountpoint=~"/|/rootfs|/volume[0-9]+",job="{job}"}} / node_filesystem_size_bytes{{mountpoint=~"/|/rootfs|/volume[0-9]+",job="{job}"}})',
            # 網路:rx+tx KB/s,排除虛擬介面
            "net": (f'sum(rate(node_network_receive_bytes_total{{job="{job}",device!~"lo|veth.*|br.*|docker.*|tap.*|fwbr.*|fwpr.*|fwln.*"}}[5m])'
                    f' + rate(node_network_transmit_bytes_total{{job="{job}",device!~"lo|veth.*|br.*|docker.*|tap.*|fwbr.*|fwpr.*|fwln.*"}}[5m])) / 1024'),
        }
        async with httpx.AsyncClient(timeout=6.0) as client:
            res = await asyncio.gather(*[
                _promq_range(client, expr, 6 * 3600, 300) for expr in q.values()
            ], return_exceptions=True)
        for key, r in zip(q.keys(), res):
            metrics[key] = [] if isinstance(r, BaseException) else _series(r)

    related: list[dict] = []
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            fr = await client.get(f"{AM}/api/v2/alerts",
                                  params={"active": "true", "silenced": "false", "inhibited": "false"})
            fr.raise_for_status()
        short = h["name"].split(" ")[0]
        for a in fr.json():
            labels = a.get("labels", {})
            inst = labels.get("instance", "")
            desc = (a.get("annotations", {}).get("summary")
                    or a.get("annotations", {}).get("description", ""))
            # 帶 pve guest id 的告警(PveGuest*)只歸屬該 guest——不因 instance=宿主 FQDN
            # 而攀到宿主頁(否則 vm300 停機同時出現在 pve24 頁,歸屬顛倒)。
            alert_id = labels.get("id", "")
            if alert_id and alert_id.startswith(("lxc/", "qemu/")):
                hit = alert_id == h.get("pve")
            else:
                # 一般告警:job 相等,或 instance host(切埠切網域)精確 token 命中
                inst_host = inst.split(":")[0]
                tokens = {inst_host, inst_host.split(".")[0]}
                hit = (job and labels.get("job") == job) or slug in tokens or short in tokens
            if hit:
                s = labels.get("severity", "info")
                related.append({
                    "name": labels.get("alertname", "?"),
                    "severity": s if s in ("critical", "warning") else "info",
                    "description": desc,
                    "instance": inst,
                    "since": _humanize_since(a.get("startsAt", "")),
                })
    except Exception:  # noqa: BLE001 —— 相關告警屬加值資訊
        related = []

    log_tail = await _loki_tail(h["loki"]) if h.get("loki") else None

    return {
        "slug": slug,
        "name": h["name"],
        "vlan": h["vlan"],
        "bare": bool(h.get("bare") or not job),
        "metrics_6h": metrics,
        "services": services_of_host(slug),
        "related_alerts": related,
        "log_tail": log_tail,
        "loki": h.get("loki"),
        "grafana_url": f"{GRAFANA_LAN}{DASH_OVERVIEW}",
        "generated_at": _now(),
    }
