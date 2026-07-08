"""靜態註冊表:主機清單 + 服務目錄(M2 §5)。

單一事實來源=拓樸 V7(2026-07-08 逐條核實);改顯示名/放行後同步這裡。
reach 旗標:pc40=PC40 直達已放行(V7 §4.4);phone=手機(tailnet 發證後)可達
——有 url_hl 者經 CT203 Caddy,其餘依 dmz 豁免規則。兩者皆 False 只列不連。
"""

# ---- 主機(overview / L2 詳情共用) ----
#   slug:路由 /host/<slug>;job:node_exporter 類 job;pve:pve-exporter id;
#   loki:Loki host label(監控告警 §5e,無 promtail 的機器為 None);
#   bare:textfile/snmp 類,無 cpu/mem 指標;off_ok:關機屬正常。
HOSTS: list[dict] = [
    {"slug": "openwrt", "name": "openwrt", "vlan": "路由", "job": "openwrt-system",
     "bare": True, "loki": "openwrt", "note": "textfile 9105"},
    {"slug": "router-pve", "name": "router-pve", "vlan": "infra", "job": "n95-router-pve-node"},
    {"slug": "pve24", "name": "pve24", "vlan": "infra", "job": "pve-node"},
    {"slug": "dxp4800", "name": "dxp4800", "vlan": "storage", "job": "dxp4800-node"},
    {"slug": "switch3f", "name": "switch3f", "vlan": "infra", "job": "snmp-switch3f", "bare": True,
     "pending": "SNMP 待接(待辦25)", "off_ok": True},
    {"slug": "pc40", "name": "pc40", "vlan": "trusted", "http": True, "off_ok": True},
    {"slug": "ct100", "name": "ct100 · mc", "vlan": "game", "job": "mc-server-node",
     "loki": "ct100", "pve": "lxc/100"},
    {"slug": "ct102", "name": "ct102 · velocity", "vlan": "game", "job": "ct102-mc-proxy-node",
     "pve": "lxc/102"},
    {"slug": "ct201", "name": "ct201 · monitor", "vlan": "svc", "job": "monitor-node", "loki": "ct201"},
    {"slug": "ct202", "name": "ct202 · fwdproxy", "vlan": "svc", "job": "ct202-fwdproxy-node",
     "loki": "ct202"},
    {"slug": "ct203", "name": "ct203 · dmz", "vlan": "dmz", "job": "ct-dmz-proxy-node"},
    {"slug": "ct250", "name": "ct250 · lab", "vlan": "srv", "pve": "lxc/250", "off_ok": True,
     "note": "常態關機(onboot 0)"},
    {"slug": "ct260", "name": "ct260 · codex", "vlan": "srv", "job": "ct260-codex-ops-node",
     "loki": "ct260"},
    {"slug": "ct270", "name": "ct270 · life", "vlan": "srv", "job": "ct270-life-ops-node",
     "loki": "ct270"},
    {"slug": "vm300", "name": "vm300 · honeypot", "vlan": "666", "job": "vm300-honeypot-node",
     "pve": "qemu/300"},
]

BY_SLUG = {h["slug"]: h for h in HOSTS}

GRAFANA_LAN = "http://10.80.80.11:3002"
GRAFANA_HL = "https://grafana.hl.lailai74143.com"
DASH_OVERVIEW = "/d/homelab-overview"
DASH_SECURITY = "/d/openwrt-portscan-autoban/openwrt-portscan-autoban"

# ---- 服務目錄(M2 §5;kuma=Uptime Kuma monitor 名,與 UI 實際命名對齊後生效) ----
#   host:掛載主機 slug(L2 詳情反查);pc40/phone 見檔頭。
SERVICE_GROUPS: list[dict] = [
    {"group": "觀測", "items": [
        {"name": "Grafana", "url": f"{GRAFANA_LAN}", "url_hl": GRAFANA_HL,
         "kuma": "grafana", "host": "ct201", "pc40": True, "phone": True},
        {"name": "總覽 dashboard", "url": f"{GRAFANA_LAN}{DASH_OVERVIEW}",
         "url_hl": f"{GRAFANA_HL}{DASH_OVERVIEW}", "kuma": "grafana", "host": "ct201",
         "pc40": True, "phone": True},
        {"name": "安全 dashboard", "url": f"{GRAFANA_LAN}{DASH_SECURITY}",
         "url_hl": f"{GRAFANA_HL}{DASH_SECURITY}", "kuma": "grafana", "host": "ct201",
         "pc40": True, "phone": True},
        {"name": "Uptime Kuma", "url": "http://10.80.80.11:3001",
         "url_hl": "https://kuma.hl.lailai74143.com", "kuma": None, "host": "ct201",
         "pc40": True, "phone": True},
        {"name": "Prometheus", "url": "http://10.80.80.11:9090",
         "url_hl": "https://prometheus.hl.lailai74143.com", "kuma": "prometheus", "host": "ct201",
         "pc40": True, "phone": True},
        {"name": "Portal 本站", "url": "http://10.80.80.11:8088",
         "url_hl": "https://portal.hl.lailai74143.com", "kuma": "portal", "host": "ct201",
         "pc40": True, "phone": True},
        {"name": "ntfy", "url": "http://10.80.80.11:8091", "kuma": "ntfy", "host": "ct201",
         "pc40": False, "phone": True, "note": "PC40 未放行(僅手機,待辦49 決策6)"},
    ]},
    {"group": "虛擬化/網路", "items": [
        {"name": "pve24 PVE", "url": "https://pve24.home.arpa:8006", "kuma": None,
         "host": "pve24", "pc40": True, "phone": False},
        {"name": "RouterPVE", "url": "https://router-pve.home.arpa:8006", "kuma": None,
         "host": "router-pve", "pc40": True, "phone": False},
        {"name": "OpenWrt LuCI", "url": "http://192.168.10.1", "kuma": None,
         "host": "openwrt", "pc40": False, "phone": False, "note": "PC40/手機皆未放行(管理面)"},
        {"name": "Switch3F", "url": "http://192.168.10.21", "kuma": None,
         "host": "switch3f", "pc40": True, "phone": False},
        {"name": "AP Main", "url": "http://192.168.50.2", "kuma": None,
         "host": None, "pc40": True, "phone": False},
        {"name": "NAS 管理 UI", "url": "https://nas.home.arpa:8243", "kuma": None,
         "host": "dxp4800", "pc40": True, "phone": False},
    ]},
    {"group": "安全", "items": [
        {"name": "Wazuh", "url": "https://10.80.80.12", "kuma": "wazuh", "host": None,
         "pc40": True, "phone": False},
        {"name": "AdGuard Home", "url": "http://192.168.10.1:8080", "kuma": "agh", "host": "openwrt",
         "pc40": False, "phone": True, "note": "PC40 未放行(僅手機,待辦49 決策6)"},
    ]},
    {"group": "生活", "items": [
        {"name": "NocoDB", "url": "http://192.168.20.70:8080", "kuma": "nocodb", "host": "ct270",
         "pc40": True, "phone": False},
        {"name": "Home Assistant", "url": "http://192.168.20.70:8123", "kuma": "ha", "host": "ct270",
         "pc40": True, "phone": False},
        {"name": "Paperless", "url": "http://192.168.20.70:8000", "kuma": "paperless", "host": "ct270",
         "pc40": True, "phone": False},
        {"name": "Navidrome", "url": "http://192.168.20.70:4533", "kuma": "navidrome", "host": "ct270",
         "pc40": True, "phone": True, "note": "媒體豁免,手機免發證"},
    ]},
    {"group": "媒體", "items": [
        {"name": "Jellyfin", "url": "http://192.168.30.3:8096", "kuma": "jellyfin", "host": "dxp4800",
         "pc40": False, "phone": True, "note": "媒體豁免;PC40 未放行(僅手機,待辦49 決策6)"},
        {"name": "qBittorrent", "url": "http://192.168.30.3:8080", "kuma": "qbittorrent",
         "host": "dxp4800", "pc40": False, "phone": False, "note": "PC40/手機皆未放行(待辦49 決策6)"},
    ]},
    {"group": "遊戲", "items": [
        {"name": "MCSManager", "url": "http://10.70.70.20:23333", "kuma": None, "host": "ct100",
         "pc40": False, "phone": False, "note": "PC40/手機皆未放行(僅 CT201 監控面)"},
        {"name": "MC 對外入口", "url": "mc.lailai74143.com:49169", "kuma": None, "host": "ct100",
         "pc40": True, "phone": True, "note": "Java 49169 / Bedrock 43915,公網 hairpin"},
    ]},
    {"group": "基礎", "items": [
        # 威脅面緩解(M2 §7 決策8):Vaultwarden 只列名稱+綠燈,不附公網 URL
        {"name": "Vaultwarden", "url": None, "kuma": "vaultwarden", "host": "dxp4800",
         "pc40": False, "phone": False, "note": "經 CF Tunnel,入口不在此列出"},
    ]},
]


def services_of_host(slug: str) -> list[str]:
    return [i["name"] for g in SERVICE_GROUPS for i in g["items"] if i.get("host") == slug]
