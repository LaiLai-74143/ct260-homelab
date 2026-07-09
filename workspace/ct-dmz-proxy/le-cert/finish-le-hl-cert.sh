#!/bin/bash
# finish-le-hl-cert.sh — hl.* 內部站換 Let's Encrypt wildcard 憑證(從源頭消瀏覽器警告)
# 背景(2026-07-09 使用者裁決,方案 B2):acme 客戶端放 CT260(使用者級,零 root、CT203 零新套件),
#   DNS-01 經 Cloudflare 簽 *.hl.lailai74143.com(純出站,hl.* 維持零公網 record),
#   憑證推送 CT203 /etc/caddy/certs/,Caddyfile 7 站 tls internal → import hl_tls。
# 在哪跑:CT260(codex@codex-ops),先 hl-unlock,然後:
#   bash ~/workspace/ct-dmz-proxy/le-cert/finish-le-hl-cert.sh
# 前置:~/.config/homelab/cloudflare-dns.env 已填 CF_Token(見模板註解)。
# 冪等:全段可重跑(含段5 半途中斷後重跑——切換段每次都 validate+存活檢查,不憑字串跳過)。
# 回滾:CT203 /root/_backups/Caddyfile.before-le-<TS> 蓋回 + systemctl restart caddy;
#   憑證檔另有 .prev 一代備份(hl-deploy-hl-cert 維護)。
# 預期 caddy restart 次數:2(段5 切換 + 段6 reloadcmd 註冊時 acme.sh 立即實跑一次部署,
#   後者是 acme.sh --install-cert 的固有行為,同時充當完整驗證;TG ✅ 通知一則)。
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
DOMAIN='*.hl.lailai74143.com'
ACME="$HOME/.acme.sh/acme.sh"
ACME_TAG="3.1.1"
STAGE="$HOME/.local/state/le-hl"
ENVF="$HOME/.config/homelab/cloudflare-dns.env"
DMZ_IP="10.60.60.10"

echo "══ 段0 前置檢查 ══"
[ -f "$ENVF" ] || { echo "✗ $ENVF 不存在(先跑模板落位)"; exit 1; }
tok=$(grep '^CF_Token=' "$ENVF" | cut -d= -f2- || true)
{ [ -n "$tok" ] && [ "$tok" != "REPLACE_ME" ]; } || { echo "✗ CF_Token 未填($ENVF)"; exit 1; }
unset tok
ssh -o ConnectTimeout=5 pve24 true || { echo "✗ ssh pve24 不通(先 hl-unlock)"; exit 1; }
ssh pve24 "sudo pct exec 203 -- true" || { echo "✗ CT203 不可達"; exit 1; }
curl -sf -m 10 https://acme-v02.api.letsencrypt.org/directory >/dev/null || { echo "✗ LE API 不可達"; exit 1; }
# CF API 連通性:4xx 也算通(未帶 token),只有連線層失敗才擋
cfcode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://api.cloudflare.com/client/v4/) \
    || { echo "✗ Cloudflare API 不可達(連線層失敗)"; exit 1; }
echo "✓ 前置全過(CF API http=$cfcode)"

echo "══ 段1 acme.sh 安裝(使用者級,釘版 $ACME_TAG,冪等) ══"
if [ ! -x "$ACME" ]; then
    rm -rf /tmp/acme.sh-src
    git clone -q --depth 1 --branch "$ACME_TAG" https://github.com/acmesh-official/acme.sh /tmp/acme.sh-src
    ( cd /tmp/acme.sh-src && ./acme.sh --install --home "$HOME/.acme.sh" ) >/dev/null
    rm -rf /tmp/acme.sh-src
    echo "✓ acme.sh $ACME_TAG 已安裝(cron 已自動掛,crontab -l 可核)"
else
    echo "✓ acme.sh 已存在,跳過安裝"
fi
"$ACME" --set-default-ca --server letsencrypt >/dev/null
grep -q '^AUTO_UPGRADE=' "$HOME/.acme.sh/account.conf" 2>/dev/null \
    || echo 'AUTO_UPGRADE="0"' >> "$HOME/.acme.sh/account.conf"   # 釘版紀律:不自動升級

echo "══ 段1.5 hl-deploy-hl-cert 落位 ~/.local/bin ══"
install -D -m 755 "$SELF_DIR/hl-deploy-hl-cert" "$HOME/.local/bin/hl-deploy-hl-cert"
echo "✓ 已落位"

echo "══ 段2 簽發 $DOMAIN(DNS-01/Cloudflare;冪等:仍有效則跳過) ══"
set -a; . "$ENVF"; set +a
rc=0
"$ACME" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 --days 30 --server letsencrypt || rc=$?
unset CF_Token   # token 已由 acme.sh 存入 account.conf,縮短行程 env 存活
case $rc in
    0) echo "✓ 簽發成功";;
    2) echo "✓ 憑證仍有效,跳過簽發";;
    *) echo "✗ 簽發失敗 rc=$rc(檢查 CF token 權限:Zone:Read+DNS:Edit 限 lailai74143.com)"; exit 1;;
esac
chmod 700 "$HOME/.acme.sh"
chmod 600 "$HOME/.acme.sh/account.conf"   # token 落點顯式收斂,不賭 acme.sh 預設

echo "══ 段3 憑證落 staging($STAGE) ══"
mkdir -p "$STAGE"
"$ACME" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$STAGE/hl-fullchain.pem" \
    --key-file "$STAGE/hl-privkey.pem" >/dev/null
chmod 600 "$STAGE/hl-privkey.pem"
openssl x509 -in "$STAGE/hl-fullchain.pem" -noout -subject -issuer -enddate
echo "✓ staging 就緒"

echo "══ 段4 CT203 憑證目錄 + 首次推送(免 restart 免驗證,Caddyfile 未切換) ══"
ssh pve24 "sudo pct exec 203 -- mkdir -p /etc/caddy/certs"
"$HOME/.local/bin/hl-deploy-hl-cert" --skip-verify

echo "══ 段5 Caddyfile 切換(冪等;每次必 validate+存活檢查,失敗自動回滾) ══"
pushed=0
TS=$(date +%Y%m%d_%H%M%S)
if ssh pve24 "sudo pct exec 203 -- grep -q hl_tls /etc/caddy/Caddyfile"; then
    echo "· CT203 Caddyfile 已含 hl_tls,不重推(仍會 validate+檢查存活)"
else
    ssh pve24 "sudo pct exec 203 -- mkdir -p /root/_backups"
    ssh pve24 "sudo pct exec 203 -- cp /etc/caddy/Caddyfile /root/_backups/Caddyfile.before-le-$TS"
    scp -q "$SELF_DIR/../Caddyfile" pve24:/tmp/Caddyfile.le
    ssh pve24 "sudo pct push 203 /tmp/Caddyfile.le /etc/caddy/Caddyfile; rc=\$?; rm -f /tmp/Caddyfile.le; exit \$rc"
    pushed=1
fi
if ! ssh pve24 "sudo pct exec 203 -- caddy validate --config /etc/caddy/Caddyfile" >/dev/null 2>&1; then
    if [ "$pushed" = "1" ]; then
        echo "✗ caddy validate 失敗 → 回滾舊 Caddyfile"
        ssh pve24 "sudo pct exec 203 -- cp /root/_backups/Caddyfile.before-le-$TS /etc/caddy/Caddyfile" \
            || echo "✗ 回滾亦失敗,人工介入"
        ssh pve24 "sudo pct exec 203 -- systemctl restart caddy" || echo "✗ 回滾後 restart 失敗,人工介入"
    else
        echo "✗ 現役 Caddyfile validate 失敗(前次切換半殘?)→ 人工介入:/root/_backups/ 有歷次備份"
    fi
    exit 1
fi
if [ "$pushed" = "1" ]; then
    restart_ok=1
    ssh pve24 "sudo pct exec 203 -- systemctl restart caddy" || restart_ok=0
    sleep 2
    [ "$restart_ok" = "1" ] && ssh pve24 "sudo pct exec 203 -- systemctl is-active --quiet caddy" || restart_ok=0
    if [ "$restart_ok" != "1" ]; then
        echo "✗ restart 後 caddy 未存活 → 回滾舊 Caddyfile"
        ssh pve24 "sudo pct exec 203 -- cp /root/_backups/Caddyfile.before-le-$TS /etc/caddy/Caddyfile" \
            || echo "✗ 回滾亦失敗,人工介入"
        ssh pve24 "sudo pct exec 203 -- systemctl restart caddy" || echo "✗ 回滾後 restart 失敗,人工介入"
        exit 1
    fi
    echo "✓ 已切換+存活(備份:CT203 /root/_backups/Caddyfile.before-le-$TS)"
else
    ssh pve24 "sudo pct exec 203 -- systemctl is-active --quiet caddy" \
        || { echo "✗ caddy 未在跑,人工介入"; exit 1; }
    echo "✓ validate+存活 OK(未重推)"
fi

echo "══ 段6 續簽 reloadcmd 註冊(acme.sh 固有行為:註冊時立即實跑一次=完整部署+驗證) ══"
"$ACME" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$STAGE/hl-fullchain.pem" \
    --key-file "$STAGE/hl-privkey.pem" \
    --reloadcmd "$HOME/.local/bin/hl-deploy-hl-cert"
echo "✓ 已註冊+完整驗證過(acme.sh cron 每日檢查,~30 天一續,緩衝 ~60 天;ssh 上鎖時 TG 通知人工補跑)"

echo "══ 段7 回歸(:80 vault 健康點、:8082 跳轉站) ══"
vh=$(curl -sf -m 5 "http://$DMZ_IP/health" || true)
[ "$vh" = "OK" ] || { echo "✗ 回歸失敗::80/health=「$vh」"; exit 1; }
r82=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$DMZ_IP:8082/" || true)
[ "$r82" = "302" ] || { echo "✗ 回歸失敗::8082=「$r82」(預期 302)"; exit 1; }
echo "✓ 回歸過(:80/health OK、:8082 302)"

echo ""
echo "完成。後續(使用者):"
echo "  1. 手機開 https://portal.hl.lailai74143.com → 應綠鎖免警告"
echo "  2. Kuma UI 加 HTTPS monitor(portal.hl)開『憑證到期通知』作續簽斷鏈備援"
echo "  3. 各裝置可移除舊 CT203 Caddy root.crt(信任面收縮)"
