#!/bin/bash
# finish-life-chat-infra.sh — 生活助理(待辦49 生活對話框)基建三件:
#   1) CT260 cron 常駐(@reboot + */5 自癒,照 ntfy-webhook 模式)
#   2) OpenWrt 放行 10.80.80.11 → 192.168.20.60 tcp/5002(照 Webhook-5001 模板,不加 SNAT)
#   3) CT201 portal.env 補 LIFE_CHAT_URL/LIFE_CHAT_TOKEN(token 走暫存檔,不經 ps)
# 冪等:重跑無害。回滾:uci delete firewall.allow_monitor_to_ct260_lifechat && reload;
#       portal.env 蓋回 /opt/portal/_backups/portal.env.before-lifechat-<TS>
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ENV=~/.config/homelab/life-chat.env
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前檢 =="
[ -f "$ENV" ] || { echo "缺 $ENV(先跑 life-chat 安裝段)"; exit 1; }
[ -x ~/.local/bin/life-chat-run.sh ] || { echo "缺 ~/.local/bin/life-chat-run.sh"; exit 1; }
curl -s -m 4 http://127.0.0.1:5002/health | grep -q '"ok": true' || { echo "life-chat :5002 未在跑"; exit 1; }
ssh -o ConnectTimeout=6 openwrt true || { echo "openwrt ssh 不可達(金鑰上鎖?先 hl-unlock)"; exit 1; }
ssh -o ConnectTimeout=6 pve24 true   || { echo "pve24 ssh 不可達(金鑰上鎖?先 hl-unlock)"; exit 1; }

echo "== 1. CT260 cron 常駐 =="
( crontab -l 2>/dev/null | grep -v 'life-chat-run.sh' ;
  echo '# life-chat: 生活助理(Sonnet 5 唯讀工具+提案單) :5002 (待辦#49, added 2026-07-09)' ;
  echo '@reboot sleep 25 && /home/codex/.local/bin/life-chat-run.sh' ;
  echo '*/5 * * * * /home/codex/.local/bin/life-chat-run.sh' ) | crontab -
crontab -l | grep -c 'life-chat-run.sh' | xargs echo "cron 行數(應為2):"

echo "== 2. OpenWrt 放行 5002(冪等) =="
if ssh openwrt "uci -q get firewall.allow_monitor_to_ct260_lifechat.name" >/dev/null 2>&1; then
  echo "規則已存在,跳過"
else
  ssh openwrt "cp /etc/config/firewall /etc/config/firewall.bak-lifechat-$TS"
  ssh openwrt "cat /etc/config/firewall" > ~/_backups/openwrt-firewall.before-lifechat-$TS 2>/dev/null \
    || { mkdir -p ~/_backups; ssh openwrt "cat /etc/config/firewall" > ~/_backups/openwrt-firewall.before-lifechat-$TS; }
  ssh openwrt "
    uci set firewall.allow_monitor_to_ct260_lifechat=rule
    uci set firewall.allow_monitor_to_ct260_lifechat.name='Allow-Monitor-To-CT260-LifeChat-5002'
    uci set firewall.allow_monitor_to_ct260_lifechat.src='service'
    uci set firewall.allow_monitor_to_ct260_lifechat.src_ip='10.80.80.11'
    uci set firewall.allow_monitor_to_ct260_lifechat.dest='servers'
    uci set firewall.allow_monitor_to_ct260_lifechat.dest_ip='192.168.20.60'
    uci set firewall.allow_monitor_to_ct260_lifechat.dest_port='5002'
    uci set firewall.allow_monitor_to_ct260_lifechat.proto='tcp'
    uci set firewall.allow_monitor_to_ct260_lifechat.target='ACCEPT'
    uci commit firewall && /etc/init.d/firewall reload >/dev/null 2>&1"
fi
ssh openwrt "nft list ruleset | grep -q 'LifeChat-5002'" && echo "nft 已載入 LifeChat-5002 ✓" \
  || { echo "nft 驗證失敗"; exit 1; }
# 回歸抽查:既有 5001 放行不受影響
ssh pve24 "sudo pct exec 201 -- curl -s -m 4 -o /dev/null -w '%{http_code}' http://192.168.20.60:5001/health" \
  | grep -q 200 && echo "回歸:CT201→CT260:5001 仍通 ✓" || { echo "回歸失敗:5001 不通了"; exit 1; }

echo "== 3. CT201 portal.env 補鍵(token 經暫存檔,不經 ps) =="
TOK=$(grep '^LIFE_CHAT_TOKEN=' "$ENV" | cut -d= -f2-)
[ -n "$TOK" ] || { echo "env 缺 LIFE_CHAT_TOKEN"; exit 1; }
umask 077
cat > "$TMP/lifechat.frag" <<EOF
LIFE_CHAT_URL=http://192.168.20.60:5002
LIFE_CHAT_TOKEN=$TOK
EOF
scp -q "$TMP/lifechat.frag" pve24:/tmp/lifechat.frag.$$
ssh pve24 "sudo pct push 201 /tmp/lifechat.frag.$$ /tmp/lifechat.frag && rm -f /tmp/lifechat.frag.$$"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/portal/_backups
cp -a /opt/portal/portal.env /opt/portal/_backups/portal.env.before-lifechat-$TS
grep -v \"^LIFE_CHAT_\" /opt/portal/portal.env > /opt/portal/portal.env.new
cat /tmp/lifechat.frag >> /opt/portal/portal.env.new
cp /opt/portal/portal.env.new /opt/portal/portal.env && rm -f /opt/portal/portal.env.new /tmp/lifechat.frag
chmod 600 /opt/portal/portal.env
grep -c \"^LIFE_CHAT_\" /opt/portal/portal.env | xargs echo \"portal.env LIFE_CHAT_ 鍵數(應為2):\"
'"

echo "== 4. CT201 視角通路驗證 =="
ssh pve24 "sudo pct exec 201 -- curl -s -m 4 http://192.168.20.60:5002/health" | grep -q '"ok": true' \
  && echo "CT201→CT260:5002 /health ✓" || { echo "5002 不通"; exit 1; }
code=$(ssh pve24 "sudo pct exec 201 -- curl -s -m 6 -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer wrong' \
  -d '{}' http://192.168.20.60:5002/chat")
[ "$code" = 401 ] && echo "錯 token → 401 ✓" || { echo "預期 401 實得 $code"; exit 1; }

echo "== 完成(TS=$TS)。下一步:finish-portal-060.sh 部署前端+BFF =="
