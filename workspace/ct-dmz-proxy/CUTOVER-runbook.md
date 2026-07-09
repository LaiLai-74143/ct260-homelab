# CT203 ct-dmz-proxy — CUTOVER runbook（待辦第2項 d/e/f/g 收尾）

狀態：**地基已建**（CT203 + Caddy 2.6.2 held + node_exporter 1.9.0 + 監控放行 + snapshot baseline）。
本檔＝把「對外面」從 DXP4800 cloudflared 遷到 CT203 Caddy 的**正式 cutover**，需在維護窗執行。
每步照《操作規範與回滾.txt》：先備份、每步驗證、留回滾路徑。現況數字以拓樸V6 為準。

⚠️ 對外/不可逆：改動 Cloudflare 後台會影響正式 Vaultwarden 對外存取（密碼庫）。先在測試域或低峰驗證。

---

## 0. 前置（開工前備齊）
- [ ] 維護窗（低峰；Vaultwarden 對外會短暫切換）。
- [ ] DXP4800 SSH 開著（`ssh dxp4800`；3 小時自動關，要時重開）。
- [ ] Cloudflare Zero Trust dashboard 登入權限（改 tunnel public hostname service）。
- [ ] CF tunnel 憑證：既有 tunnel 的 token 或 credentials.json（**機密**，在 DXP 上或 CF 後台取得；只放 CT203 chmod600，勿入任何文件/git）。

## 1. 查 Vaultwarden 後端埠（DXP）
```sh
ssh dxp4800 'docker ps --format "{{.Names}}\t{{.Ports}}" | grep -iE "vault|bitwarden"'
# 記下容器對外 http 埠（如 8080/80/8000），下稱 <VW_PORT>。走 http（CF/內部終結 TLS）。
```

## 2. OpenWrt：加 dmz→storage 單條放行（+SNAT）
```sh
# 備份
hl-run openwrt 'cp /etc/config/firewall /etc/config/firewall.before-dmz-to-vault-'"$(date +%Y%m%d-%H%M%S)"
# 放行 CT203(dmz) -> DXP(storage):<VW_PORT>
hl-run openwrt 'uci set firewall.allow_dmzproxy_to_vault=rule
uci set firewall.allow_dmzproxy_to_vault.name="Allow-DMZProxy-To-Vaultwarden"
uci set firewall.allow_dmzproxy_to_vault.src="dmz"
uci set firewall.allow_dmzproxy_to_vault.src_ip="10.60.60.10"
uci set firewall.allow_dmzproxy_to_vault.dest="storage"
uci set firewall.allow_dmzproxy_to_vault.dest_ip="192.168.30.3"
uci set firewall.allow_dmzproxy_to_vault.proto="tcp"
uci set firewall.allow_dmzproxy_to_vault.dest_port="<VW_PORT>"
uci set firewall.allow_dmzproxy_to_vault.target="ACCEPT"
# DXP SMB/其他服務只信任 .30.1 來源：SNAT 成 storage 閘道（src=storage egress zone，才會 fire！見缺改記錄 SNAT 發現）
uci set firewall.snat_dmzproxy_to_vault=nat
uci set firewall.snat_dmzproxy_to_vault.name="SNAT-DMZProxy-To-Vaultwarden"
uci set firewall.snat_dmzproxy_to_vault.src="storage"
uci set firewall.snat_dmzproxy_to_vault.src_ip="10.60.60.10"
uci set firewall.snat_dmzproxy_to_vault.dest_ip="192.168.30.3"
uci set firewall.snat_dmzproxy_to_vault.proto="tcp"
uci set firewall.snat_dmzproxy_to_vault.target="SNAT"
uci set firewall.snat_dmzproxy_to_vault.snat_ip="192.168.30.1"
uci commit firewall'
hl-run openwrt 'fw4 check && fw4 reload'
# 驗證：CT203 -> DXP:<VW_PORT>
hl-run pve24 'sudo -n /usr/sbin/pct exec 203 -- bash -lc "curl -sf -o /dev/null -w %{http_code}\\n --max-time 5 http://192.168.30.3:<VW_PORT>/"'
```

## 3. Caddy：啟用 Vaultwarden 反代站
編 CT260 `~/workspace/ct-dmz-proxy/Caddyfile`，把 cutover 模板取消註解、填 `<VW_PORT>` 與正式域名（用 CF 上的 public hostname，如 `vault.lailai74143.com`）：
```
vault.lailai74143.com {
    reverse_proxy 192.168.30.3:<VW_PORT>
}
```
部署：
```sh
scp ~/workspace/ct-dmz-proxy/Caddyfile pve24:/tmp/Caddyfile.dmz
hl-run pve24 'sudo -n /usr/sbin/pct push 203 /tmp/Caddyfile.dmz /etc/caddy/Caddyfile --perms 644; rm -f /tmp/Caddyfile.dmz
sudo -n /usr/sbin/pct exec 203 -- bash -lc "caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && systemctl reload caddy"'
```

## 4. cloudflared：CT203 起同一 tunnel 的新 connector
```sh
# 4a. 裝 cloudflared（pin 版本；DMZ 有 WAN。可 apt 官方 repo 或直接下載固定版 .deb）
# 4b. 放 tunnel 憑證（機密！只放 CT203，chmod600）：credentials.json 或用 token 模式
#     token 模式最簡：systemd 服務跑  cloudflared tunnel run --token <TUNNEL_TOKEN>
#     （新 connector 會與 DXP 上舊 connector 並存於同一 tunnel — 這是預期的雙棲期）
# 4c. ingress 指到本機 Caddy：http://localhost:80（或 http://10.60.60.10:80）
# 4d. 起服務、確認 connector 在 CF dashboard 上線（Tunnel > Connectors 多一個）
```

## 5. CF dashboard：切 service 到 Caddy
- Zero Trust > Networks > Tunnels > 該 tunnel > Public Hostname > `vault.*` > **Service 改 `http://10.60.60.10:80`**（經新 connector 路由）。
- 若用同 tunnel token 模式，ingress 已在 4c 定；此步是把 hostname 綁到新 service。

## 6. 驗證外網（雙棲期，DXP cloudflared 仍在）
- [ ] 外部網路（手機熱點）開 `https://vault.lailai74143.com` → 正常登入、Vaultwarden app 同步 OK。
- [ ] Caddy 有流量：`hl-run pve24 'sudo pct exec 203 -- journalctl -u caddy --since "-5min" | tail'`
- [ ] 若異常 → CF dashboard service 改回原 DXP 指向即回滾（DXP connector 還在）。

## 7. 收舊：停 DXP cloudflared
```sh
ssh dxp4800 'docker ps | grep cloudflared'   # 記容器名
ssh dxp4800 'docker stop <cf_container>'      # 先停不刪；穩定數日後再 rm
# 再驗一次外網 Vaultwarden 仍通（此時只剩 CT203 connector）
```

## 8. AGH：內部 vault.* rewrite 指 Caddy（待辦②e）
- AGH 後台 > Filters > DNS rewrites：`vault.home.arpa`（及對外域內部化者）→ `10.60.60.10`。
- 內部→dmz:443/80 放行（待辦②f）：加 `Allow-Trusted/Servers-To-DMZProxy`（trusted/servers → 10.60.60.10 tcp/443,80）。
- 改完 `/etc/init.d/adguardhome restart` 清快取；內網開 vault 走 Caddy 驗證。

## 9. Kuma 探活（待辦②g，UI）
- Kuma（http://monitor.home.arpa:3001）> Add Monitor：
  - HTTP(s)，`http://ct-dmz-proxy.home.arpa/health`，keyword `OK`，間隔 60s。（OpenWrt monitor→dmz:80 已放行）
  - 另加一個對 `https://vault.lailai74143.com` 的外部探活（keyword 選登入頁字串）。

## 10. 收尾
- [ ] 缺改記錄.txt 加 cutover 完成條目（日期、CF 設定文字/截圖、後端埠、回滾點）。
- [ ] 拓樸V6 §10.7 把 cutover 由 OPEN 改為完成；§4.4 加 dmz→storage 放行；§11 安全摘要「Vaultwarden 走 CF Tunnel」改為「經 CT203 Caddy」。
- [ ] 待辦清單②：d✔ e✔ f✔ g✔ → 標 DONE（若全部服務收編完）；否則保留「後續批次 Jellyfin/qBittorrent」。
- [ ] CT203 `pct snapshot 203 post-cutover`。

---
## 回滾（任一步異常）
1. CF dashboard：public hostname service 改回原 DXP 指向（最快，DXP connector 雙棲期還在）。
2. Caddy：移除 vault 站、reload；或 `pct rollback 203 baseline`（回乾淨基線）。
3. OpenWrt：`cp firewall.before-dmz-to-vault-* /etc/config/firewall && fw4 reload`。
4. AGH：移除 vault rewrite、restart。

## 附註
- **Caddy 版本**：現為 Debian pkg 2.6.2（held）。需新版→改用官方 cloudsmith repo：
  `curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg`
  + `.../debian.deb.txt` 寫入 sources.list.d → `apt-mark unhold caddy && apt update && apt install caddy`（記得重新 pin）。
- **待辦③ Authelia**：上線後在每個受保護 site 加 `forward_auth authelia:9091 {...}`（Caddyfile 模板已留註解）。
- **小發現（可清理）**：全隊既有 `SNAT-Monitor-To-X` 因 `src=<源zone>` 落錯 srcnat 鏈、實際 no-op（無害）。要修就把各 `src` 改成目的 zone（egress），如本次 DMZ 版 `src=dmz`。非緊急。
