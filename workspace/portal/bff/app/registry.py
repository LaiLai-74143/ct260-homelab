"""靜態註冊表:主機清單 + 服務目錄(M2 §5)。

單一事實來源=拓樸 V7(2026-07-08 逐條核實);改顯示名/放行後同步這裡。
reach 旗標:pc40=PC40 直達已放行(V7 §4.4);phone=手機(tailnet 發證後)可達
——有 url_hl 者經 CT203 Caddy;其餘走發證直達:phone→CT203 masq 10.60.60.10→OpenWrt
  TSGate 8 zone proto-all(V7 §4.4)+ router input 80/443/8080,手機 DNS=100.100.1.1(AGH)
  故 home.arpa/hl 皆可解析(V7 §4.8,2026-07-08 逐條核實)。兩者皆 False 只列不連。
  例外:MC 對外入口走公網 WAN DNAT,phone=True 與發證無關。
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
     "pending": "SNMP 未應答(待辦25)", "off_ok": True},
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

# ---- 服務目錄(M2 §5;kuma=Kuma monitor 名 lower——2026-07-08 與 UI 實際命名逐一核過) ----
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
        {"name": "pve24 PVE", "url": "https://pve24.home.arpa:8006", "kuma": "pve 24bay nas",
         "host": "pve24", "pc40": True, "phone": True},
        {"name": "RouterPVE", "url": "https://router-pve.home.arpa:8006", "kuma": "pve router",
         "host": "router-pve", "pc40": True, "phone": True},
        {"name": "OpenWrt LuCI", "url": "http://192.168.10.1", "kuma": "openwrt",
         "host": "openwrt", "pc40": False, "phone": True,
         "note": "PC40 未放行(管理面);手機發證後經 router-web 80/443 可達"},
        {"name": "Switch3F", "url": "http://192.168.10.21", "kuma": None,
         "host": "switch3f", "pc40": True, "phone": True},
        {"name": "AP Main", "url": "http://192.168.50.41", "kuma": "be3600 pro main",
         "host": None, "pc40": True, "phone": True},
        {"name": "NAS 管理 UI", "url": "https://nas.home.arpa:8243", "kuma": "ugreen nas",
         "host": "dxp4800", "pc40": True, "phone": True},
    ]},
    {"group": "安全", "items": [
        {"name": "Wazuh", "url": "https://10.80.80.12", "kuma": "wazuh", "host": None,
         "pc40": True, "phone": True},
        {"name": "AdGuard Home", "url": "http://192.168.10.1:8080", "kuma": "adguardhome", "host": "openwrt",
         "pc40": False, "phone": True, "note": "PC40 未放行(僅手機,待辦49 決策6)"},
    ]},
    {"group": "生活", "items": [
        {"name": "NocoDB", "url": "http://192.168.20.70:8080", "kuma": "nocodb", "host": "ct270",
         "pc40": True, "phone": True},
        {"name": "Home Assistant", "url": "http://192.168.20.70:8123", "kuma": "ha", "host": "ct270",
         "pc40": True, "phone": True},
        {"name": "Paperless", "url": "http://192.168.20.70:8000", "kuma": "paperless-ngx", "host": "ct270",
         "pc40": True, "phone": True},
        {"name": "Navidrome", "url": "http://192.168.20.70:4533", "kuma": "navidrome", "host": "ct270",
         "pc40": True, "phone": True, "note": "媒體豁免,手機免發證"},
    ]},
    {"group": "媒體", "items": [
        {"name": "Jellyfin", "url": "http://192.168.30.3:8096", "kuma": "jellyfin", "host": "dxp4800",
         "pc40": False, "phone": True, "note": "媒體豁免;PC40 未放行(僅手機,待辦49 決策6)"},
        {"name": "qBittorrent", "url": "http://192.168.30.3:8080", "kuma": "qbittorrent",
         "host": "dxp4800", "pc40": False, "phone": True,
         "note": "PC40 未放行(待辦49 決策6);手機發證後可達"},
    ]},
    {"group": "遊戲", "items": [
        {"name": "MCSManager", "url": "http://10.70.70.20:23333", "kuma": "mcsmanager", "host": "ct100",
         "pc40": True, "phone": True,
         "note": "PC40+發證後手機可達(OpenWrt 一條 + CT100 nft 點名,待辦49 2026-07-08)"},
        {"name": "MC 對外入口", "url": "mc.lailai74143.com:49169", "kuma": "minecraft java public entry", "host": "ct100",
         "pc40": True, "phone": True,
         "note": "Java 49169 / Bedrock 43915;公網 WAN DNAT(蜂巢/外網直達,與發證無關);"
                 "hairpin 僅 PC40,手機在家 Wi-Fi 用公網名不通"},
    ]},
    {"group": "基礎", "items": [
        # 威脅面緩解(M2 §7 決策8):Vaultwarden 只列名稱+綠燈,不附公網 URL
        {"name": "Vaultwarden", "url": None, "kuma": "vaultwarden", "host": "dxp4800",
         "pc40": False, "phone": False, "note": "經 CF Tunnel,入口不在此列出"},
    ]},
]


def services_of_host(slug: str) -> list[str]:
    return [i["name"] for g in SERVICE_GROUPS for i in g["items"] if i.get("host") == slug]


# ---- M3 動作鏡像表(待辦49 M3,2026-07-08) ----
# 單一事實來源=CT260 ~/.local/bin/ntfy-webhook.py 的 ACTIONS 字典(待辦19d)。
# 改動作先改那邊,再同步這裡;漂移的失敗模式安全:BFF 先 403(新動作按不到)
# 或 webhook 403(BFF 有、CT260 無),錯誤 hint 直指同步。
#   param:該動作收的參數語義(僅 silence-* 收 alertname,webhook 端 regex 驗參)。
#   danger:確認框追加的琥珀警告行(不影響執行)。
#   fire_and_forget:動作會殺掉 BFF 自身(pct-reboot-201)→ 送出即回 202 不等結果。
WEBHOOK_ACTIONS: dict[str, dict] = {
    "silence-1h":  {"desc": "靜音該告警 1 小時", "param": "alertname"},
    "silence-24h": {"desc": "靜音該告警 24 小時", "param": "alertname"},
    "restart-gotify":       {"desc": "重啟 Gotify"},
    "restart-kuma":         {"desc": "重啟 Uptime Kuma"},
    "restart-grafana":      {"desc": "重啟 Grafana"},
    "restart-prometheus":   {"desc": "重啟 Prometheus"},
    "restart-alertmanager": {"desc": "重啟 Alertmanager"},
    "restart-ntfy":         {"desc": "重啟 ntfy"},
    "restart-monitoring-stack": {"desc": "重啟整個監控棧",
                                 "danger": "Prometheus/Alertmanager 短暫離線,告警頁會空窗"},
    "pct-reboot-201": {"desc": "重啟 CT201(監控主機)", "fire_and_forget": True,
                       "danger": "入口本身將短暫離線,結果見 TG 回報"},
    "pct-start-250":  {"desc": "啟動 CT250(沙盒)"},
    "restart-squid":     {"desc": "重啟 CT202 squid"},
    "restart-ctdmz-nft": {"desc": "重啟 CT203 ctdmz-nft",
                          "danger": "清空 tailnet 通行證,手機需重新發證"},
}

# 鏡像自 CT260 homelab-notify.py NTFY_ACTION_MAP(告警名→預定義處置)
ALERT_ACTION_MAP: dict[str, str] = {
    "SquidProxyDown": "restart-squid",
    "CtdmzGateDown": "restart-ctdmz-nft",
}
