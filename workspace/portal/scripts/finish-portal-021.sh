#!/bin/bash
# finish-portal-021.sh — 待辦49:部署 portal:0.2.1(registry phone flags 對齊 V7 發證模型)
#                        + force-recreate 使容器吃到 portal.env 新值(Kuma API key)
# 冪等:重跑無害。回滾:compose 蓋回 _backups/docker-compose.yml.before-portal021-<TS>
#       + docker compose up -d --force-recreate portal(0.2.0 image 仍在本機)。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 1. 打包 bff(前端無變更,不動 static) =="
tar -C "$ROOT/bff" --exclude .venv --exclude '__pycache__' \
    -czf "$TMP/portal-bff.tgz" app Dockerfile requirements.txt
BFF_SHA=$(sha256sum "$TMP/portal-bff.tgz" | cut -d' ' -f1)

echo "== 2. 傳輸 pve24 → pct push CT201 =="
scp -q "$TMP/portal-bff.tgz" pve24:/tmp/
ssh pve24 'sudo pct push 201 /tmp/portal-bff.tgz /tmp/portal-bff.tgz && rm -f /tmp/portal-bff.tgz'

echo "== 3. CT201:sha 驗證 + 備份 + 換源 + build 0.2.1 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-bff.tgz)\" | grep -q $BFF_SHA || { echo bff sha 不符; exit 1; }
# 自癒:上次死在兩個 mv 之間時 bff 不在,把 bff.old 挪回(兩者皆缺則 fail-loud)
[ -d /opt/portal/bff ] || mv /opt/portal/bff.old /opt/portal/bff
# 首跑才建 before-021 備份(重跑時 bff 已是 0.2.1,再備份會污染回滾點)
ls /root/_backups/portal-bff-before-021-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-bff-before-021-$TS.tgz bff
rm -rf /opt/portal/bff.new /opt/portal/bff.old
mkdir -p /opt/portal/bff.new
tar -C /opt/portal/bff.new -xzf /tmp/portal-bff.tgz
mv /opt/portal/bff /opt/portal/bff.old && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-bff.tgz
docker build -q -t portal:0.2.1 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 0.2.0→0.2.1(先驗後裝)+ force-recreate =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.2.1" not in s:
    assert "    image: portal:0.2.0" in s, "錨點未命中:image tag"
    s = s.replace("    image: portal:0.2.0", "    image: portal:0.2.1", 1)
open(p, "w").write(s); print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
# 首跑才建 before-021 備份(重跑時現役 compose 可能已是 0.2.1)
ls /opt/monitoring/_backups/docker-compose.yml.before-portal021-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal021-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
# force-recreate:換 bind 來源目錄 + 讓 env_file 新值(Kuma key)進容器
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/bff.old
'"

echo "== 5. 驗證:env 進容器(只印長度)+ 10 端點 + Kuma monitor 名對齊清單 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
docker exec portal sh -c \"echo 容器內 KUMA_len=\\\${#KUMA_API_KEY} MCSM_len=\\\${#MCSM_API_KEY}\"
for ep in health overview alerts brief services security game life power host/ct201; do
  printf \"/api/%s → \" \"\$ep\"; curl -s -o /dev/null -w \"%{http_code}\" -m 8 http://127.0.0.1:8088/api/\$ep; echo
done
echo \"-- Kuma monitor 名(對齊 registry kuma 欄位用;不印金鑰) --\"
KEY=\$(sed -n \"s/^KUMA_API_KEY=//p\" /opt/portal/portal.env | tr -d \"\\047\\042\")
OUT=\$(curl -s -m 8 -u \":\$KEY\" http://127.0.0.1:3001/metrics) || { echo \"(Kuma metrics 取不到——3001 連線失敗)\"; OUT=; }
printf \"%s\" \"\$OUT\" | grep -o \"monitor_name=\\\"[^\\\"]*\\\"\" | sort -u || echo \"(無 monitor_name——401/key 錯或 Kuma 無 monitor)\"
'"
echo "-- kuma_ok 摘要(CT260 側解析) --"
ssh pve24 'sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/api/services' | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('kuma_note:', d.get('kuma_note'))
for g in d['groups']:
    for i in g['items']:
        print(f\"{i['name']:<16} kuma_ok={i['kuma_ok']} phone={i['phone']}\")"

echo "== 完成。回滾點:各取「最早一份」/opt/monitoring/_backups/docker-compose.yml.before-portal021-* + /root/_backups/portal-bff-before-021-*.tgz(功能回滾走 compose 換回 0.2.0 image 即可) =="
