"""live 模式:Prometheus / Alertmanager 唯讀查詢(§4/§8)。

上游皆走 compose 內網,無憑證、無寫入;PC40 健檢走既有防火牆放行
(Allow/SNAT-Monitor-To-PC40-Health-18080)。查詢聚合 by(job),
一次 overview 只打 Prometheus 6 發、PC40 1 發,外層另有 3–10s 快取。
"""
import asyncio
import os
from datetime import datetime, timezone

import httpx

from .providers import UpstreamError

PROM = os.environ.get("PROM_URL", "http://prometheus:9090")
AM = os.environ.get("AM_URL", "http://alertmanager:9093")
PC40_HEALTH = os.environ.get("PC40_HEALTH", "http://192.168.40.4:18080/")

# 主機註冊表(拓樸 V7 §1/§2;job 對應監控告警 §2)
#   job:node_exporter 類 job 名;pve:pve-exporter 的 pve_up id;http:健檢 URL
#   off_ok:關機屬正常(unk 而非 crit);pending:數據源未接完成的說明
HOSTS: list[dict] = [
    {"name": "openwrt", "vlan": "路由", "job": "openwrt-system", "bare": True, "note": "textfile 9105"},
    {"name": "router-pve", "vlan": "infra", "job": "n95-router-pve-node"},
    {"name": "pve24", "vlan": "infra", "job": "pve-node"},
    {"name": "dxp4800", "vlan": "storage", "job": "dxp4800-node"},
    {"name": "switch3f", "vlan": "infra", "job": "snmp-switch3f", "bare": True,
     "pending": "SNMP 待接(待辦25)", "off_ok": True},
    {"name": "pc40", "vlan": "trusted", "http": PC40_HEALTH, "off_ok": True},
    {"name": "ct100 · mc", "vlan": "game", "job": "mc-server-node"},
    {"name": "ct102 · velocity", "vlan": "game", "job": "ct102-mc-proxy-node"},
    {"name": "ct201 · monitor", "vlan": "svc", "job": "monitor-node"},
    {"name": "ct202 · fwdproxy", "vlan": "svc", "job": "ct202-fwdproxy-node"},
    {"name": "ct203 · dmz", "vlan": "dmz", "job": "ct-dmz-proxy-node"},
    {"name": "ct250 · lab", "vlan": "srv", "pve": "lxc/250", "off_ok": True, "note": "常態關機(onboot 0)"},
    {"name": "ct260 · codex", "vlan": "srv", "job": "ct260-codex-ops-node"},
    {"name": "ct270 · life", "vlan": "srv", "job": "ct270-life-ops-node"},
    {"name": "vm300 · honeypot", "vlan": "666", "job": "vm300-honeypot-node", "pve": "qemu/300"},
]


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


async def overview() -> dict:
    async with httpx.AsyncClient(timeout=5.0) as client:
        up_vec, cpu, mem, disk, boot, pve, pc40 = await asyncio.gather(
            _promq(client, "up"),
            _promq(client, '100 * (1 - avg by (job)(rate(node_cpu_seconds_total{mode="idle"}[5m])))'),
            _promq(client, '100 * avg by (job)(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'),
            _promq(client, '100 * max by (job)(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})'),
            _promq(client, "time() - max by (job)(node_boot_time_seconds)"),
            _promq(client, "pve_up"),
            _pc40_alive(client),
        )

    up = _by_job(up_vec)
    cpu, mem, disk, boot = _by_job(cpu), _by_job(mem), _by_job(disk), _by_job(boot)
    pve_up = {r["metric"].get("id"): float(r["value"][1]) for r in pve}

    hosts = []
    crit_notes, warn_notes = [], []
    for h in HOSTS:
        name, job = h["name"], h.get("job")
        state, note, uptime = "unk", h.get("note", ""), "—"
        c = m = dk = None
        if h.get("pending") and up.get(job or "", 0) < 1:
            note = h["pending"]
        elif "http" in h:
            state = "ok" if pc40 else "unk"
            note = "health OK" if pc40 else "關機(正常)"
            uptime = "on" if pc40 else "off"
        elif job and job in up:
            if up[job] >= 1:
                state = "ok"
                if not h.get("bare"):
                    c = round(cpu[job]) if job in cpu else None
                    m = round(mem[job]) if job in mem else None
                    dk = round(disk[job]) if job in disk else None
                    uptime = _human_secs(boot[job]) if job in boot else "—"
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
        hosts.append({"name": name, "vlan": h["vlan"], "up": state,
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
        "services_ok": None,           # M2:Kuma
        "alerts_firing": -1,           # 前端以 /api/alerts 為準;此欄 M1 不重複查
        "targets": {"up": n_up, "total": total},
        "generated_at": _now(),
    }


def _humanize_since(start: str) -> str:
    try:
        t = datetime.fromisoformat(start.replace("Z", "+00:00"))
        return _human_secs((datetime.now(timezone.utc) - t).total_seconds())
    except ValueError:
        return "?"


async def alerts() -> dict:
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            fr = await client.get(f"{AM}/api/v2/alerts",
                                  params={"active": "true", "silenced": "false", "inhibited": "false"})
            fr.raise_for_status()
            sr = await client.get(f"{AM}/api/v2/silences")
            sr.raise_for_status()
        except Exception as e:  # noqa: BLE001
            raise UpstreamError(f"Alertmanager 查詢失敗: {type(e).__name__}") from e
        try:
            pr = await client.get(f"{PROM}/api/v1/alerts")
            pending_raw = [a for a in pr.json()["data"]["alerts"] if a.get("state") == "pending"]
        except Exception:  # noqa: BLE001 —— pending 屬加值資訊,失敗不整包壞
            pending_raw = []

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

    return {"firing": firing, "pending": pending, "silences": silences, "generated_at": _now()}
