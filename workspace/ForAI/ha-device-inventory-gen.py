#!/usr/bin/env python3
# HA + OpenWrt 設備清單生成器（在 CT260 執行，用既有 ssh alias）
# 來源：
#   HA 設備名/型號/雲端MAC  <- CT270 /opt/homeassistant/config/.storage/core.device_registry（唯讀，不碰 token）
#   線上實機MAC/IP/在線/靜態 <- OpenWrt /tmp/dhcp.leases + `ip neigh` + uci dhcp host
# join：以「HA 雲端 MAC」對映線上；已知偏移（攝影機/路由器）用 CLOUD_TO_WIRE 修正。
# 用法：  python3 ha-device-inventory-gen.py > HA米家設備清單.txt
import json, re, subprocess, sys, datetime

OPENWRT = "openwrt"          # ssh alias -> root@openwrt
PVE = "pve24"                # ssh alias -> codex-admin@192.168.20.5（可 sudo pct exec）
HA_CTID = "270"
DEVREG = "/opt/homeassistant/config/.storage/core.device_registry"

# 已知「雲端 MAC → 線上實機 MAC」偏移（見拓樸V7 §2.6 / 缺改記錄 2026-07-02）
CLOUD_TO_WIRE = {
    "18:50:73:0e:d2:51": "18:50:73:0e:d2:52",   # 監視器（大門口）isa.camera：線上 +1
    "04:67:61:24:62:a9": "04:67:61:58:c5:0a",   # 主路由 rn01 → WiFiMain .50.41
    "04:67:61:24:3a:62": "04:67:61:59:8e:6d",   # 節點 rn04  → WiFiSub  .50.42
}
MAC_RE = re.compile(r"^([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})")


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30).stdout


BLE_MESH_MODELS = {"cddz.plug.pc01m"}  # BLE-Mesh，無 IP，經小愛音箱(oh2p)閘道→Mi雲


def conn_type(model, ident):
    if ident.startswith("ir."):
        return "IR遙控(雲)"
    if model in BLE_MESH_MODELS:
        return "BLE-Mesh(雲)"
    if model.startswith("lumi."):
        return "Zigbee(雲)"
    if ".magnet." in model or ".sensor_" in model:
        return "BLE(雲)"
    if model.startswith("xiaomi.router"):
        return "AP/路由"
    return "WiFi"


def ewidth(s):  # 東亞全形字寬 2
    w = 0
    for ch in s:
        o = ord(ch)
        w += 2 if (0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0xA4CF or
                   0xAC00 <= o <= 0xD7A3 or 0xF900 <= o <= 0xFAFF or
                   0xFE30 <= o <= 0xFE4F or 0xFF00 <= o <= 0xFF60 or
                   0xFFE0 <= o <= 0xFFE6) else 1
    return w


def pad(s, width):
    s = "-" if s in (None, "") else str(s)
    return s + " " * max(0, width - ewidth(s))


def main():
    # ---- OpenWrt：leases / neigh / static hosts ----
    raw = sh(f"ssh -o ConnectTimeout=8 {OPENWRT} "
             "'cat /tmp/dhcp.leases; echo ===NEIGH===; ip neigh show dev br-iot; "
             "echo ===HOSTS===; uci -q show dhcp | grep -E \"@host\\[\"'")
    leases_txt, rest = raw.split("===NEIGH===", 1)
    neigh_txt, hosts_txt = rest.split("===HOSTS===", 1)

    wire = {}   # mac(lower) -> dict(ip, host, reach, static)
    for ln in leases_txt.splitlines():
        p = ln.split()
        if len(p) >= 4:
            m = p[1].lower()
            wire.setdefault(m, {}).update(ip=p[2], host=(p[3] if p[3] != "*" else ""))
    for ln in neigh_txt.splitlines():
        p = ln.split()
        if "lladdr" in p:
            m = p[p.index("lladdr") + 1].lower()
            wire.setdefault(m, {})["reach"] = p[-1]
    # static hosts：解析 uci index
    hosts = {}
    for ln in hosts_txt.splitlines():
        mm = re.match(r"dhcp\.@host\[(\d+)\]\.(\w+)='?([^']*)'?", ln.strip())
        if mm:
            hosts.setdefault(mm.group(1), {})[mm.group(2)] = mm.group(3)
    for h in hosts.values():
        if "mac" in h:
            m = h["mac"].lower()
            d = wire.setdefault(m, {})
            d["static"] = h.get("name", "yes")
            d.setdefault("ip", h.get("ip", ""))

    # ---- HA device_registry ----
    dr = json.loads(sh(f"ssh -o ConnectTimeout=8 {PVE} "
                       f"'sudo pct exec {HA_CTID} -- cat {DEVREG}'"))
    rows, internal = [], []
    for dev in dr.get("data", {}).get("devices", []):
        name = dev.get("name_by_user") or dev.get("name") or "-"
        model = dev.get("model") or "-"
        ident = ""
        cloud = ""
        for i in dev.get("identifiers", []):
            val = i[1] if len(i) > 1 else ""
            m = MAC_RE.match(val)
            if m:
                cloud = m.group(1).lower()
            if val.startswith("ir."):
                ident = val
        if not cloud and not ident:
            internal.append((name, model))
            continue
        wmac = CLOUD_TO_WIRE.get(cloud, cloud)
        w = wire.get(wmac, {})
        conn = conn_type(model, ident or (cloud and ""))
        if w.get("reach") in ("REACHABLE", "STALE", "DELAY"):
            online = "在線"
        elif w.get("ip"):
            online = "有租約"
        elif conn in ("BLE(雲)", "BLE-Mesh(雲)", "Zigbee(雲)", "IR遙控(雲)"):
            online = "雲/子設備"   # 無 DHCP 為正常，靠閘道+雲
        else:
            online = "離線"
        rows.append(dict(
            name=name, model=model, conn=conn,
            ip=w.get("ip", ""), wmac=(wmac if w else (wmac if cloud else "")),
            cloud=cloud, static=w.get("static", ""), online=online,
        ))
    rows.sort(key=lambda r: (r["ip"].split(".")[-1].zfill(3) if r["ip"] else "999", r["name"]))

    # ---- 輸出 ----
    used = {m.lower() for r in rows for m in [r["wmac"]] if m}
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    W = [(("名稱"), 22), ("型號/model", 26), ("連線", 15), ("IP", 16),
         ("線上實機MAC", 19), ("HA雲端MAC", 19), ("靜態host", 15), ("狀態", 6)]
    out = []
    out.append("# HA / 米家設備清單（便查快照）")
    out.append(f"生成：{now}（Asia/Taipei）  由 ForAI/ha-device-inventory-gen.py 生成，重跑即刷新。")
    out.append("來源：HA CT270 core.device_registry（名稱/型號/雲端MAC）+ OpenWrt leases/neigh/uci（線上MAC/IP/在線/靜態）。")
    out.append("註：小米雲端 MAC 與線上實機 MAC 部分不同（攝影機/路由器已於腳本 CLOUD_TO_WIRE 修正）；IP 不入 HA，取自 OpenWrt。")
    out.append("")
    out.append("".join(pad(h, w) for h, w in W))
    out.append("".join("-" * w for _, w in W))
    for r in rows:
        out.append("".join([
            pad(r["name"], W[0][1]), pad(r["model"], W[1][1]), pad(r["conn"], W[2][1]),
            pad(r["ip"], W[3][1]), pad(r["wmac"], W[4][1]), pad(r["cloud"], W[5][1]),
            pad(r["static"], W[6][1]), pad(r["online"], W[7][1]),
        ]))
    if internal:
        out.append("")
        out.append("HA 內建/非實體（無設備 MAC）：" + "、".join(n for n, _ in internal))
    # OpenWrt 在線但非 HA
    extra = []
    for m, w in wire.items():
        if m in used or not w.get("ip"):
            continue
        extra.append(f"  {w.get('ip',''):<15} {m}  {w.get('host','') or '-'}  "
                     f"{'static:'+w['static'] if w.get('static') else ''}".rstrip())
    if extra:
        out.append("")
        out.append("OpenWrt 在線/有租約但非 HA（供對照，未納入 HA 管理）：")
        out.extend(sorted(extra, key=lambda x: int(x.split('.')[3].split()[0]) if x.strip() else 0))
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
