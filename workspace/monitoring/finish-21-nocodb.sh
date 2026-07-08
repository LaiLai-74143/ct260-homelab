#!/bin/bash
# finish-21-nocodb.sh — 待辦21 尾段:nocodb pin :latest→2026.06.2
# (CT270 docker egress 走 CT202 squid;dockerhub 為刻意常閉的「暫時窗」,
#  agent 改 squid 現役檔被 auto-mode 分類器攔,照慣例收斂本腳本交使用者執行)
# 在 CT260 以一般使用者執行:bash ~/workspace/monitoring/finish-21-nocodb.sh
# 冪等:重跑無害。回滾:CT270 /opt/nocodb/_backups/docker-compose.yml.before-todo21-* 蓋回。
set -euo pipefail
TS=$(date +%Y%m%d_%H%M%S)

echo "== 1. CT202 squid:開 dockerhub 暫時窗 =="
ssh pve24 "sudo pct exec 202 -- bash -c '
set -e
cp -a /etc/squid/squid.conf /etc/squid/squid.conf.before-todo21-$TS
sed -i \"s|^# acl ok dstdomain .docker.io production.cloudfront.docker.com|acl ok dstdomain .docker.io production.cloudfront.docker.com|\" /etc/squid/squid.conf
grep -q \"^acl ok dstdomain .docker.io\" /etc/squid/squid.conf || { echo 開窗失敗:錨點未命中; exit 1; }
squid -k parse >/dev/null && squid -k reconfigure && echo window-open
'"

echo "== 2. CT270:pin nocodb 2026.06.2 + 重建 =="
ssh pve24 "sudo pct exec 270 -- bash -c '
set -e
cd /opt/nocodb
sed -i \"s|image: nocodb/nocodb:latest|image: nocodb/nocodb:2026.06.2|\" docker-compose.yml
docker compose config -q
docker compose pull -q
docker compose up -d
sleep 10
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep nocodb
ver=\$(curl -sm8 localhost:8080/api/v1/version | grep -o \"2026.06.2\" | head -1)
[ \"\$ver\" = \"2026.06.2\" ] || { echo \"nocodb 版本驗證失敗\"; exit 1; }
echo nocodb-2026.06.2-OK
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
echo "== 完成。若第 2 步 pull 卡 blob:看 CT202 /var/log/squid/access.log 抓被拒的 CDN 域名回報 =="
