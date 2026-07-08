#!/bin/bash
# deploy-020.sh — 待辦49 M2:部署 portal:0.2.0 到 CT201
# 冪等:重跑無害(備份帶時間戳;build/up 對同內容為 no-op)。
# 回滾:compose 蓋回 /opt/monitoring/_backups/docker-compose.yml.before-portal020-<TS>
#       + docker compose up -d portal(image 0.1.0 仍在本機);static/bff 有 _backups tgz。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== 1. 打包 =="
tar -C "$ROOT/frontend/dist" -czf "$TMP/portal-static.tgz" .
tar -C "$ROOT/bff" --exclude .venv --exclude '__pycache__' \
    -czf "$TMP/portal-bff.tgz" app Dockerfile requirements.txt
sha256sum "$TMP"/portal-*.tgz | tee "$TMP/sums"

echo "== 2. 傳輸 pve24 → pct push CT201 =="
scp -q "$TMP/portal-static.tgz" "$TMP/portal-bff.tgz" pve24:/tmp/
ssh pve24 'sudo pct push 201 /tmp/portal-static.tgz /tmp/portal-static.tgz && sudo pct push 201 /tmp/portal-bff.tgz /tmp/portal-bff.tgz && rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz'
STATIC_SHA=$(grep static "$TMP/sums" | cut -d' ' -f1)
BFF_SHA=$(grep bff "$TMP/sums" | cut -d' ' -f1)

echo "== 3. CT201:備份 + 解包 + build 0.2.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
tar -C /opt/portal -czf /root/_backups/portal-src-before-020-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
# 換目錄後容器仍掛舊 inode,務必在步驟 5 用 --force-recreate 重綁;
# 上一代 .old 直到本次 recreate 後才清(見步驟 5 末),避免刪到運行中容器的 bind 來源。
rm -rf /opt/portal/static.old /opt/portal/bff.old
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff    /opt/portal/bff.old    && mv /opt/portal/bff.new    /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.2.0 /opt/portal/bff
echo build-OK
'"

echo "== 4. portal.env(600,唯讀憑證位;不存在才建) =="
ssh pve24 "sudo pct exec 201 -- bash -c '
if [ ! -f /opt/portal/portal.env ]; then
  printf \"# portal BFF 唯讀憑證(待辦49 決策4;值由使用者填入後 docker compose up -d portal)\n# 全部留空=對應功能誠實降級(綠燈灰/玩家數待接)\nKUMA_API_KEY=\nMCSM_API_KEY=\n\" > /opt/portal/portal.env
  chmod 600 /opt/portal/portal.env && chown root:root /opt/portal/portal.env
  echo portal.env created
else echo portal.env exists; fi
'"

echo "== 5. compose:pull → 改(image 0.2.0 + env_file + extra_hosts + LOKI_URL)→ 驗證 → push =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
assert "  portal:" in s, "compose 無 portal 服務"
def sub_once(text, old, new, why):
    if new.split("\n")[0].strip() in text and old not in text:
        return text  # 已套用過(冪等)
    out = text.replace(old, new, 1)
    assert out != text, f"錨點未命中:{why}"  # 錨點失效就 fail-fast,不靜默略過
    return out

if "portal:0.2.0" not in s:
    s = sub_once(s, "    image: portal:0.1.0", "    image: portal:0.2.0", "image tag")
if "LOKI_URL" not in s:
    s = sub_once(s, "      - AM_URL=http://alertmanager:9093",
                 "      - AM_URL=http://alertmanager:9093\n"
                 "      - LOKI_URL=http://loki:3100\n"
                 "      - KUMA_URL=http://host.docker.internal:3001", "env urls")
if "/opt/portal/portal.env" not in s:
    s = sub_once(s, "    volumes:\n      - /opt/portal/static:/app/static:ro",
                 "    env_file:\n      - /opt/portal/portal.env\n"
                 "    extra_hosts:\n      - \"host.docker.internal:host-gateway\"\n"
                 "    volumes:\n      - /opt/portal/static:/app/static:ro", "env_file+extra_hosts")
open(p, "w").write(s)
print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
# 先驗後裝:壞 YAML 絕不覆蓋現役監控棧 compose
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal020-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
# --force-recreate:換目錄後容器必須重綁新 bind inode(否則續掛 .old,再次重跑會被清空)
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 6. 驗證 live 端點 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
for ep in health overview services security game life power host/ct201 host/zzz; do
  printf \"/api/%s → \" \"\$ep\"; curl -s -o /dev/null -w \"%{http_code}\" -m 8 http://127.0.0.1:8088/api/\$ep; echo
done
curl -s -m 8 http://127.0.0.1:8088/api/security | head -c 300; echo
'"

echo "== 完成。回滾點:/opt/monitoring/_backups/docker-compose.yml.before-portal020-$TS + /root/_backups/portal-src-before-020-$TS.tgz =="
