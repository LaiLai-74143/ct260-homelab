#!/bin/bash
# hl-derp-watch(2026-07-18):自架 DERP(region900)防退化哨兵。
# 常駐路徑 ~/.local/bin/hl-derp-watch.sh(SoT=~/workspace/ops/),cron 每小時 :07(flock)。
# 背景:07-17/18 兩起「全機 DNS 押隧道+家內連不到自家 DERP」斷網(手機 iot、PC trusted),
#   缺口全程靜默、既有監控看不到。本哨兵斷言三件事,違例直發 TG(比照 hl-cert-watch):
#   ① OpenWrt 兩條 DERP redirect 的 reflection 配置不漂移(reflection='1'+zone 含 iot+trusted,
#      nft dstnat_iot/dstnat_trusted 反射 DNAT 與 forward 顯式放行都在)。
#   ② derper 存活:OpenWrt tailscale netcheck 看得到 home 延遲(STUN=同一進程,死了就消失)。
#   ③ 家內在線 peer(手機 100.100.1.6 / PC 100.100.1.4)Relay 應=home;掛外區=hairpin 又壞了。
# 走 openwrt-auto(自動化鑰)純唯讀;12h 內同內容告警去重防刷屏。
set -uo pipefail
STATE_DIR="$HOME/.local/state/homelab-notify"; mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/derp-watch.state"
SSH="ssh -o ConnectTimeout=10 openwrt-auto"

tg() {  # token 經 curl -K stdin,不進 argv
    local envf="$HOME/.config/homelab/notify-telegram.env" token chat
    token=$(grep '^TELEGRAM_BOT_TOKEN=' "$envf" 2>/dev/null | cut -d= -f2-)
    chat=$(grep '^TELEGRAM_CHAT_ID=' "$envf" 2>/dev/null | cut -d= -f2-)
    [ -n "$token" ] && [ -n "$chat" ] || return 1
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" | \
        curl -sf -m 20 -K - --data-urlencode "chat_id=${chat}" --data-urlencode "text=$1" >/dev/null
}

problems=()

# ① 配置不漂移
ucifw=$($SSH 'uci show firewall' 2>/dev/null)
if [ -z "$ucifw" ]; then
    problems+=("openwrt-auto ssh 不通,無法巡檢(路由器掛了會另有告警;若只此哨兵失聯請查金鑰/dropbear)")
else
    for rname in WAN-DERP-8443-to-CT203 WAN-DERP-STUN-3478-to-CT203; do
        sec=$(printf '%s\n' "$ucifw" | grep -B1 -A11 "name='$rname'")
        printf '%s' "$sec" | grep -q "reflection='1'" || problems+=("redirect $rname 的 reflection≠1")
        for z in iot trusted; do
            printf '%s' "$sec" | grep "reflection_zone" | grep -q "$z" || problems+=("redirect $rname 的 reflection_zone 缺 $z")
        done
    done
    nftout=$($SSH 'nft list chain inet fw4 dstnat_iot; nft list chain inet fw4 dstnat_trusted; nft list chain inet fw4 forward_iot; nft list chain inet fw4 forward_trusted' 2>/dev/null)
    printf '%s' "$nftout" | grep -A9 'chain dstnat_iot'     | grep -q 'dport 8443.*dnat'  || problems+=("nft dstnat_iot 缺 8443 反射 DNAT")
    printf '%s' "$nftout" | grep -A9 'chain dstnat_trusted' | grep -q 'dport 8443.*dnat'  || problems+=("nft dstnat_trusted 缺 8443 反射 DNAT")
    printf '%s' "$nftout" | grep -q 'Allow-IoT-DERP-Hairpin-8443'     || problems+=("forward_iot 缺 DERP 顯式放行")
    printf '%s' "$nftout" | grep -q 'Allow-Trusted-DERP-Hairpin-8443' || problems+=("forward_trusted 缺 DERP 顯式放行")
fi

# ② derper 存活(netcheck home 延遲;STUN 與 TLS 同進程)
nchk=$($SSH 'timeout 15 tailscale netcheck 2>/dev/null' </dev/null)
printf '%s' "$nchk" | grep -q -- '- home:' || problems+=("OpenWrt netcheck 看不到 home DERP(derper 掛了或 STUN 路徑斷)")

# ③ 家內在線 peer 的 Relay 應=home
tsjson=$($SSH 'tailscale status --json' 2>/dev/null)
if [ -n "$tsjson" ]; then
    bad=$(printf '%s' "$tsjson" | python3 -c '
import json,sys
d=json.load(sys.stdin)
watch={"100.100.1.6":"手機","100.100.1.4":"PC"}
out=[]
for p in (d.get("Peer") or {}).values():
    ips=p.get("TailscaleIPs") or []
    for ip,label in watch.items():
        if ip in ips and p.get("Online") and (p.get("Relay") or "")!="home":
            r=p.get("Relay") or "?"
            out.append(f"{label}({ip}) Relay={r}")
print("; ".join(out))' 2>/dev/null)
    [ -n "$bad" ] && problems+=("在線 peer 中繼掛外區:$bad(hairpin/derper 疑似失效)")
fi

if [ ${#problems[@]} -eq 0 ]; then
    echo "OK: reflection 配置完整、derper 存活、家內 peer Relay=home"
    rm -f "$STATE"; exit 0
fi

msg="⚠️ hl-derp-watch:自架 DERP 防線異常
- $(printf '%s\n- ' "${problems[@]}" | sed '$d')
排查:V7 §4.8 家內 hairpin 段;回滾/修復參考缺改記錄 2026-07-18。"
hash=$(printf '%s' "$msg" | md5sum | cut -d' ' -f1)
now=$(date +%s)
if [ -f "$STATE" ]; then
    read -r oldhash oldts < "$STATE" || true
    if [ "$oldhash" = "$hash" ] && [ $((now - oldts)) -lt 43200 ]; then
        echo "WARN(去重,12h 內不重發): ${problems[*]}"; exit 0
    fi
fi
tg "$msg" && echo "$hash $now" > "$STATE"
echo "WARN(已發 TG): ${problems[*]}"
exit 1
