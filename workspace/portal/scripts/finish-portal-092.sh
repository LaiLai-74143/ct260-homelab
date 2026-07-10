#!/bin/bash
# finish-portal-092.sh — 部署 portal:0.9.2(設備總覽三修,純 BFF 變更)
#   ① openwrt 卡接上 openwrt_* textfile 指標(cpu/mem/disk/uptime)——M1 起 bare 路徑
#     只寫了 SNMP(switch3f),openwrt 卡一直空白,非本次退化。
#   ② dxp4800 disk:mountpoint 放寬 =~"/|/rootfs|/volume[0-9]+"(UGOS 根=/rootfs,
#     原查詢寫死 "/" 永遠查空);NAS 讀數=最滿掛載點(volume 滿比 rootfs 滿致命)。
#   ③ vm300 加 off_ok+note「手動開機(onboot 0,省RAM)」——比照 ct250,紅點轉灰。
#   PromQL 已於 2026-07-10 對 live Prometheus 逐條驗值(openwrt 3.9/6.0/0.2%/13d,
#   dxp 72.8%,其餘主機讀數不受 regex 放寬影響)。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-092-<TS>.tgz
#   + compose 蓋回 _backups/docker-compose.yml.before-portal092-<最早TS> + up -d --force-recreate portal。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build(內容無變更,重建保持打包一致) =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串(回歸基準遺失?)"; exit 1; }

echo "== 1. 打包 static + bff =="
tar -C "$ROOT/frontend/dist" -czf "$TMP/portal-static.tgz" .
tar -C "$ROOT/bff" --exclude .venv --exclude '__pycache__' \
    -czf "$TMP/portal-bff.tgz" app Dockerfile requirements.txt
STATIC_SHA=$(sha256sum "$TMP/portal-static.tgz" | cut -d' ' -f1)
BFF_SHA=$(sha256sum "$TMP/portal-bff.tgz" | cut -d' ' -f1)

echo "== 2. 傳輸 pve24 → pct push CT201 =="
scp -q "$TMP/portal-static.tgz" "$TMP/portal-bff.tgz" pve24:/tmp/
ssh pve24 'sudo pct push 201 /tmp/portal-static.tgz /tmp/portal-static.tgz && \
           sudo pct push 201 /tmp/portal-bff.tgz /tmp/portal-bff.tgz && \
           rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz'

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.9.2 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-092-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-092-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.9.2 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.9.2(先驗後裝) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.9.2" not in s:
    assert "    image: portal:0.9.1" in s, "錨點未命中:image tag(現役非 0.9.1?)"
    s = s.replace("    image: portal:0.9.1", "    image: portal:0.9.2", 1)
open(p, "w").write(s); print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal092-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal092-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:端點回歸 + 三修斷言(本機執行,避免巢狀引號) =="
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf "/api/%s → " "$ep"
  ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/$ep"
  echo
done
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/api/overview" > "$TMP/ov.json"
python3 - "$TMP/ov.json" <<'PYEOF'
import json, sys
h = {x["slug"]: x for x in json.load(open(sys.argv[1]))["hosts"]}
ow, dxp, vm, sw = h["openwrt"], h["dxp4800"], h["vm300"], h["switch3f"]
assert ow["cpu"] is not None and ow["uptime"] != "—", "openwrt 仍空: %r" % ow
print("openwrt cpu=%s%% mem=%s%% disk=%s%% uptime=%s OK" % (ow["cpu"], ow["mem"], ow["disk"], ow["uptime"]))
assert dxp["disk"] is not None, "dxp disk 仍空: %r" % dxp
print("dxp4800 disk=%s%% OK" % dxp["disk"])
assert vm["up"] != "crit", "vm300 仍 crit: %r" % vm
print("vm300 up=%s note=%s OK" % (vm["up"], vm["note"]))
assert "埠 up" in sw["note"] and sw["uptime"] != "—", "switch3f 回歸失敗: %r" % sw
print("switch3f %s uptime=%s OK(回歸)" % (sw["note"], sw["uptime"]))
PYEOF

echo "== 完成(TS=$TS)。驗收:設備總覽 openwrt 卡有四項讀數、dxp4800 有 disk 條、vm300 灰點「手動開機」 =="
echo "回滾:tar -C /opt/portal -xzf /root/_backups/portal-src-before-092-<TS>.tgz"
echo "     + compose 蓋回 _backups/docker-compose.yml.before-portal092-<最早TS> + up -d --force-recreate portal"
