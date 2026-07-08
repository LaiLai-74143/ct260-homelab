#!/bin/bash
# finish-30-freshrss.sh — 待辦30:FreshRSS 上線(image 拉取需 CT202 squid dockerhub 暫時窗,
# 與 finish-21-nocodb.sh 同理由收斂使用者執行;可與該腳本任意先後、各自獨立開關窗)。
# 在 CT260 以一般使用者執行:bash ~/workspace/monitoring/finish-30-freshrss.sh
# 冪等:重跑無害。回滾:CT270 docker compose down + rm -rf /opt/freshrss;
#       CT260 sed 回註 FRESHRSS_URL(晨報段自動消失)。
set -euo pipefail
TS=$(date +%Y%m%d_%H%M%S)
ENVF=~/.config/homelab/freshrss.env
[ -f "$ENVF" ] || { echo "缺 $ENVF"; exit 1; }

echo "== 1. CT202 squid:開 dockerhub 暫時窗 =="
ssh pve24 "sudo pct exec 202 -- bash -c '
set -e
cp -a /etc/squid/squid.conf /etc/squid/squid.conf.before-todo30-$TS
sed -i \"s|^# acl ok dstdomain .docker.io production.cloudfront.docker.com|acl ok dstdomain .docker.io production.cloudfront.docker.com|\" /etc/squid/squid.conf
grep -q \"^acl ok dstdomain .docker.io\" /etc/squid/squid.conf || { echo 開窗失敗:錨點未命中; exit 1; }
squid -k parse >/dev/null && squid -k reconfigure && echo window-open
'"

echo "== 2. CT270:pull + up =="
ssh pve24 "sudo pct exec 270 -- bash -c '
set -e
cd /opt/freshrss
docker compose pull -q
docker compose up -d
for i in \$(seq 1 30); do
  code=\$(curl -sm3 -o /dev/null -w \"%{http_code}\" http://localhost:8082/i/ || true)
  [ \"\$code\" = \"200\" ] && break; sleep 2
done
[ \"\$code\" = \"200\" ] || { echo \"FreshRSS UI 未起(\$code)\"; exit 1; }
echo freshrss-ui-200
'"

echo "== 3. CT202 squid:復關暫時窗 =="
ssh pve24 "sudo pct exec 202 -- bash -c '
set -e
sed -i \"s|^acl ok dstdomain .docker.io production.cloudfront.docker.com|# acl ok dstdomain .docker.io production.cloudfront.docker.com|\" /etc/squid/squid.conf
squid -k parse >/dev/null && squid -k reconfigure
sleep 1
code=\$(curl -sm8 -o /dev/null -w \"%{http_code}\" --proxy http://127.0.0.1:3128 https://registry-1.docker.io/v2/ || true)
[ \"\$code\" = \"403\" ] || { echo \"復關驗證異常:squid 回 \$code(預期 403)\"; exit 1; }
echo window-closed-verified
'"

echo "== 4. CT270:do-install + 建使用者(憑證走檔案 push,不過 pve24 命令列) =="
scp -q "$ENVF" pve24:/tmp/freshrss-todo30.env
ssh pve24 "sudo pct push 270 /tmp/freshrss-todo30.env /tmp/freshrss-todo30.env && rm -f /tmp/freshrss-todo30.env"
ssh pve24 "sudo pct exec 270 -- bash -c '
set -e
set -a; . /tmp/freshrss-todo30.env; set +a
docker exec freshrss ./cli/do-install.php --default-user \"\$FRESHRSS_USER\" --auth-type form \
  --environment production --base-url http://rss.home.arpa:8082 --db-type sqlite 2>/dev/null \
  || echo \"do-install 已跑過(冪等略過)\"
docker exec freshrss ./cli/create-user.php --user \"\$FRESHRSS_USER\" --password \"\$FRESHRSS_PASSWORD\" \
  --api-password \"\$FRESHRSS_API_PASSWORD\" --language zh-tw 2>/dev/null \
  || docker exec freshrss ./cli/update-user.php --user \"\$FRESHRSS_USER\" --password \"\$FRESHRSS_PASSWORD\" \
       --api-password \"\$FRESHRSS_API_PASSWORD\"
docker exec freshrss ./cli/actualize-user.php --user \"\$FRESHRSS_USER\" >/dev/null 2>&1 || true
rm -f /tmp/freshrss-todo30.env
echo user-provisioned
'"

echo "== 5. CT260 視角:Google Reader API ClientLogin 驗證 + 啟用晨報段 =="
set -a; . "$ENVF"; set +a
URL="${FRESHRSS_URL:-http://192.168.20.70:8082}"
auth=$(curl -sm10 "$URL/api/greader.php/accounts/ClientLogin" \
  --data-urlencode "Email=$FRESHRSS_USER" --data-urlencode "Passwd=$FRESHRSS_API_PASSWORD" | grep -c '^Auth=' || true)
[ "$auth" = "1" ] || { echo "ClientLogin 失敗——查 FreshRSS 使用者 API 密碼"; exit 1; }
echo api-ok
sed -i 's|^#FRESHRSS_URL=|FRESHRSS_URL=|' "$ENVF"
python3 ~/.local/bin/homelab-notify.py --write-brief --dry-run >/dev/null 2>&1
python3 - <<'PY'
import json,os
d=json.load(open(os.path.expanduser('~/.local/state/homelab-notify/brief.json')))
hs=[s['h'] for s in d['sections']]
assert '今日訊息' in hs, hs
print('晨報段就位:', hs)
PY

echo "== 完成。後續:PC40 開 http://rss.home.arpa:8082 登入(帳密在 $ENVF)加訂閱源;"
echo "   明晨 06:00 起晨報自動帶「今日訊息」;無未讀/讀取失敗都有誠實註記。 =="
