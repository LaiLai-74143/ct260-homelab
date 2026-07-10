#!/bin/bash
# hl-cert-watch(2026-07-10):hl.* LE wildcard 憑證到期哨兵——acme.sh 續簽斷鏈的備援。
# 常駐路徑 ~/.local/bin/hl-cert-watch.sh(SoT=~/workspace/ops/),cron 每週一 01:00 UTC(台北 09:00)。
# 剩 <21 天(正常續簽點=剩 60 天,落到 21=斷鏈五週)或讀不到憑證 → 直發 TG(比照 watchdog-ct201)。
# 為何不用 Kuma:CT201 解析 *.hl→100.100.1.2(tailnet-only)不可達、monitor→dmz:443 未放行;
#   CT260→dmz:443 既有放行=零新規則。走 ct260_auto 自動軌?否——本腳本純出站 TLS 讀取,不需 ssh。
set -uo pipefail
THRESH_DAYS=21
DMZ_IP="10.60.60.10"
SNI="portal.hl.lailai74143.com"

tg() {  # token 經 curl -K stdin,不進 argv
    local envf="$HOME/.config/homelab/notify-telegram.env" token chat
    token=$(grep '^TELEGRAM_BOT_TOKEN=' "$envf" 2>/dev/null | cut -d= -f2-)
    chat=$(grep '^TELEGRAM_CHAT_ID=' "$envf" 2>/dev/null | cut -d= -f2-)
    [ -n "$token" ] && [ -n "$chat" ] || return 1
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" | \
        curl -sf -m 20 -K - --data-urlencode "chat_id=${chat}" --data-urlencode "text=$1" >/dev/null
}

end=$(timeout 10 openssl s_client -connect "$DMZ_IP:443" -servername "$SNI" </dev/null 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -z "$end" ]; then
    tg "⚠️ hl-cert-watch:讀不到 $SNI 憑證($DMZ_IP:443)——CT203/Caddy 可能異常,請查。"
    echo "FAIL: 讀不到憑證"; exit 1
fi
end_epoch=$(date -d "$end" +%s)
days=$(( (end_epoch - $(date +%s)) / 86400 ))
if [ "$days" -lt "$THRESH_DAYS" ]; then
    tg "⚠️ hl-cert-watch:hl.* 憑證剩 ${days} 天(到期 $end)。acme.sh 續簽鏈可能斷了——
CT260 檢查:crontab -l | grep acme;手動:hl-unlock 後 ~/.acme.sh/acme.sh --renew -d '*.hl.lailai74143.com' --ecc && ~/.local/bin/hl-deploy-hl-cert"
    echo "WARN: 剩 $days 天,已發 TG"; exit 0
fi
echo "OK: 剩 $days 天(到期 $end)"
