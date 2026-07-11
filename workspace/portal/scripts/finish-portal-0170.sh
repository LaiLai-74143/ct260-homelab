#!/bin/bash
# finish-portal-0170.sh — 部署 portal:0.17.0(P0/P1 增強包,範本 v0.17 移植)
#   P0:⌘K 命令面板(模糊搜尋模塊/服務/網站/動作;⌘K // 喚起、g+字母跳頁;
#       靜音動作走既有確認框+/api/action)+ 卡片 sparkline(新端點 /api/spark:
#       devices/security/power 24h 真時序;alerts 卡重用 timeline_24h)。
#   P1:卡片指標追蹤光暈、背景氛圍 canvas(hidden 停 rAF/REDUCED 靜態)、
#       crit 戰情模式(html.crit 紅呼吸條+INCIDENT 徽章+氛圍轉紅)、
#       夜間模式(html.night 23:00–07:00 token 降飽和,Tailwind 五色改 CSS 變數管道)。
#   另:晨報「今日訊息」改條列排版(要點+來源右欄)。走查 31/31。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾:CT201 /root/_backups/portal-src-before-0170-<TS>.tgz 蓋回
#      + /opt/monitoring/_backups/docker-compose.yml.before-portal0170-<TS> 蓋回
#      + docker compose up -d --force-recreate portal
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== B0. 前端 build + 0.17.0 斷言 =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
# 本版新物斷言
grep -rq "命令面板" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無命令面板(CommandPalette 未接入?)"; exit 1; }
grep -q "html.night" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 html.night(夜間模式遺失?)"; exit 1; }
grep -q -- "--bg-rgb" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 -rgb 三元組(token 管道遺失?)"; exit 1; }
grep -q "critbar" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 critbar(戰情模式遺失?)"; exit 1; }
grep -rq "INCIDENT" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無 INCIDENT 徽章"; exit 1; }
# 回歸斷言(既有功能)
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串(回歸基準遺失?)"; exit 1; }
grep -q "clawd-heavy" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 clawd-heavy(0.15.0 吉祥物回歸遺失?)"; exit 1; }
grep -rq "每次對話都是全新的" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無問答框文案(0.16.0 回歸遺失?)"; exit 1; }

echo "== B1. 打包 static + bff =="
tar -C "$ROOT/frontend/dist" -czf "$TMP/portal-static.tgz" .
tar -C "$ROOT/bff" --exclude .venv --exclude '__pycache__' \
    -czf "$TMP/portal-bff.tgz" app Dockerfile requirements.txt
STATIC_SHA=$(sha256sum "$TMP/portal-static.tgz" | cut -d' ' -f1)
BFF_SHA=$(sha256sum "$TMP/portal-bff.tgz" | cut -d' ' -f1)

echo "== B2. 傳輸 pve24 → pct push CT201 =="
scp -q "$TMP/portal-static.tgz" "$TMP/portal-bff.tgz" pve24:/tmp/
ssh pve24 'sudo pct push 201 /tmp/portal-static.tgz /tmp/portal-static.tgz && \
           sudo pct push 201 /tmp/portal-bff.tgz /tmp/portal-bff.tgz && \
           rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz'

echo "== B3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.17.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-0170-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0170-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.17.0 /opt/portal/bff
echo build-OK
'"

echo "== B4. compose 換版 →0.17.0(錨點自適應:0.10~0.16 都收) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.17.0" in s:
    print("compose 已是 0.17.0(冪等跳過)")
else:
    m = re.search(r"    image: portal:(0\.1[0-6]\.0)\n", s)
    assert m, "錨點未命中:image tag 非 0.10~0.16(現役版本出乎預期,人工確認)"
    s = s.replace(f"    image: portal:{m.group(1)}", "    image: portal:0.17.0", 1)
    open(p, "w").write(s); print(f"compose edited: {m.group(1)} -> 0.17.0")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0170-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0170-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== B5. 驗證:端點回歸 + 新端點(CT201 視角) =="
for ep in health overview alerts brief services security game life power host/ct201 actions clawd/chat spark; do
  printf "/api/%s → " "$ep"
  ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/$ep"
  echo
done
# /api/spark 內容:live 下 devices(sum(up) 恆有)必在;security/power 依指標存在
SPARK=$(ssh pve24 "sudo pct exec 201 -- curl -s -m 10 http://127.0.0.1:8088/api/spark")
echo "$SPARK" | grep -q '"devices"' \
  && echo "spark 序列 OK(keys: $(echo "$SPARK" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["series"].keys()))'))" \
  || { echo "spark 無 devices 序列:$SPARK"; exit 1; }
# 閘門回歸:直達無 Remote-User → actions allowed:false(命令面板靜音項同閘)
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/api/actions" | grep -q '"allowed":false' \
  && echo "actions 閘門 allowed:false OK" || { echo "閘門異常:直達竟 allowed?"; exit 1; }

echo "== 完成(TS=$TS)。驗收(體感):"
echo "   ① PC40/portal.hl 按 Ctrl+K(或 / 、banner 的〔⌘K 搜尋〕鈕)→ 面板;"
echo "      打「gra」跳 Grafana、「靜音」出告警靜音項(僅 portal.hl 有動作項);"
echo "      g d 跳設備、g a 告警、g h 回大廳(注意:g d 從 0.17.0 起=設備,大廳改 g h);"
echo "   ② 大廳四張卡(設備/告警/安全/電力)右下有 24h 迷你趨勢線,顏色跟狀態燈;"
echo "   ③ 卡片 hover 有琥珀光暈跟滑鼠;背景有極淡網格+流動光點(分頁切走即停);"
echo "   ④ 23:00 後(或 ?night=1)全站降飽和+刊頭出 ☾,與 Clawd 睡覺同步;"
echo "   ⑤ 有 critical 時(或 ?crit=1)頂部紅呼吸條+刊頭 INCIDENT+光點轉紅;"
echo "   ⑥ 晨報「今日訊息」逐條分列、來源靠右對齊。=="
echo "回滾:CT201 tar -C /opt/portal -xzf /root/_backups/portal-src-before-0170-$TS.tgz"
echo "     + cp /opt/monitoring/_backups/docker-compose.yml.before-portal0170-$TS /opt/monitoring/docker-compose.yml"
echo "     + cd /opt/monitoring && docker compose up -d --force-recreate portal"
