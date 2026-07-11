#!/bin/bash
# finish-portal-0150.sh — 部署 portal:0.15.0(吉祥物視覺對齊 clawd-on-desk 桌面版)
#   使用者比對截圖後點名「盡可能一致」→ 照原專案 SVG 實測參數重繪(格點 15×16、
#   體色 #DE886D、1×2 直縫眼、四腿、2×2 側臂、地面陰影;動畫參數是事實不受著作權
#   保護,圖形全自繪,素材 All Rights Reserved 不取用):
#   idle 呼吸+眨眼+眼神平滑跟隨 / happy 大跳(擠壓拉伸)+揮臂+^^+像素星光 /
#   juggle 三彩球拋物線+身體搖擺+接拋臂+追球眼 / notify 琥珀!徽章疊加 /
#   error 趴地+××眼+冒煙+ERROR 紅字閃爍 / sleep 趴地深呼吸+閉眼縫+像素 Z 飄浮。
#   ?clawd=idle|happy|juggle|notify|error|sleep 可強制預覽。跳過審查(使用者慣例),走查 24/24。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-0150-<TS>.tgz
#   + compose 蓋回 _backups/docker-compose.yml.before-portal0150-<最早TS> + up -d --force-recreate portal。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build + 0.15.0 斷言 =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串(回歸基準遺失?)"; exit 1; }
grep -q "reveal-stagger" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 reveal-stagger(0.11.0 滾動進場回歸遺失?)"; exit 1; }
grep -q "clawd-breathe-idle" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 clawd-breathe-idle(0.15.0 待機呼吸未進 bundle?)"; exit 1; }
grep -q "clawd-heavy" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 clawd-heavy(0.15.0 趴地喘息未進 bundle?)"; exit 1; }
grep -q "clawd-packet" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 clawd-packet(0.15.0 雜耍球軌跡未進 bundle?)"; exit 1; }
grep -rq "本站吉祥物" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無吉祥物台詞(Mascot 未接入 Layout?)"; exit 1; }

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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.15.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-0150-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0150-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.15.0 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.15.0(錨點自適應:0.10~0.14 都收) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.15.0" in s:
    print("compose 已是 0.15.0(冪等跳過)")
else:
    m = re.search(r"    image: portal:(0\.1[0-4]\.0)\n", s)
    assert m, "錨點未命中:image tag 非 0.10~0.14(現役版本出乎預期,人工確認)"
    s = s.replace(f"    image: portal:{m.group(1)}", "    image: portal:0.15.0", 1)
    open(p, "w").write(s); print(f"compose edited: {m.group(1)} -> 0.15.0")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0150-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0150-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:端點回歸 + 線上 CSS 含吉祥物動效 =="
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf "/api/%s → " "$ep"
  ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/$ep"
  echo
done
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/" > "$TMP/index.html"
CSS=$(grep -o 'assets/index-[^"]*\.css' "$TMP/index.html" | head -1)
[ -n "$CSS" ] || { echo "index.html 無 CSS 引用?"; exit 1; }
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/$CSS" | grep -q "clawd-heavy" \
  && echo "線上 CSS 含 clawd-heavy OK" || { echo "線上 CSS 缺 clawd-heavy"; exit 1; }

echo "== 完成(TS=$TS)。驗收(體感,對照 clawd-on-desk 桌面版):"
echo "   ① 六動作快速預覽:網址加 ?clawd=idle / happy / juggle / notify / error / sleep;"
echo "   ② 自然映射:warning firing→頭上琥珀!;critical→整隻趴地+××眼+冒煙+ERROR 紅字;"
echo "      23:00–07:00 無 crit→趴地睡+像素 Z;戳牠→大跳+揮臂+^^+星光+台詞;每 16 秒拋三球;"
echo "   ③ 全頁面固定右側(手機右下),不隨滾動;kiosk 沒有牠;省電/減少動態=靜態姿勢但語義保留。=="
echo "回滾:tar -C /opt/portal -xzf /root/_backups/portal-src-before-0150-<TS>.tgz"
echo "     + compose 蓋回 _backups/docker-compose.yml.before-portal0150-<最早TS> + up -d --force-recreate portal"
