#!/bin/bash
# finish-portal-0140.sh — 部署 portal:0.14.0(吉祥物六動作,參考 clawd-on-desk 狀態機)
#   該專案素材 All Rights Reserved 不可取用 → 全部自繪;原專案感知 AI 助手狀態,
#   本版改感知 portal 全站真實狀態:
#   idle 待機(蹲起+眨眼+眼睛跟滑鼠)/ happy 開心(被戳,^^眼+跳,2.5s)/
#   juggle 三球雜耍(每 16s 一輪 3.2s)/ notify 通知(warning firing→琥珀!徽章疊加)/
#   error 報錯(critical firing→××眼+紅!+發抖)/ sleep 睡覺(23:00–07:00 無 crit→閉眼+zzz+慢呼吸)。
#   ?clawd=idle|happy|juggle|notify|error|sleep 可強制預覽。跳過審查(使用者慣例),走查 19/19。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-0140-<TS>.tgz
#   + compose 蓋回 _backups/docker-compose.yml.before-portal0140-<最早TS> + up -d --force-recreate portal。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build + 0.14.0 斷言 =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串(回歸基準遺失?)"; exit 1; }
grep -q "reveal-stagger" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 reveal-stagger(0.11.0 滾動進場回歸遺失?)"; exit 1; }
grep -q "clawd-squat" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 clawd-squat(0.14.0 蹲起未進 bundle?)"; exit 1; }
grep -q "clawd-shake" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 clawd-ball(0.14.0 六動作未進 bundle?)"; exit 1; }
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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.14.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-0140-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0140-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.14.0 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.14.0(錨點自適應:0.10~0.13 都收) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.14.0" in s:
    print("compose 已是 0.14.0(冪等跳過)")
else:
    m = re.search(r"    image: portal:(0\.1[0-3]\.0)\n", s)
    assert m, "錨點未命中:image tag 非 0.10~0.13(現役版本出乎預期,人工確認)"
    s = s.replace(f"    image: portal:{m.group(1)}", "    image: portal:0.14.0", 1)
    open(p, "w").write(s); print(f"compose edited: {m.group(1)} -> 0.14.0")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0140-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0140-$TS
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
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/$CSS" | grep -q "clawd-squat" \
  && echo "線上 CSS 含 clawd-squat OK" || { echo "線上 CSS 缺 clawd-squat"; exit 1; }

echo "== 完成(TS=$TS)。驗收(體感):"
echo "   ① 六動作快速預覽:網址加 ?clawd=idle / happy / juggle / notify / error / sleep;"
echo "   ② 自然映射:有 warning firing→頭上琥珀!;有 critical→××眼+紅!+發抖;"
echo "      23:00–07:00 無 crit→睡覺 zzz;戳牠→^^眼+跳+台詞;每 16 秒顛三球;"
echo "   ③ 全頁面固定右側(手機右下),不隨滾動;kiosk 沒有牠;省電/減少動態=靜態但表情語義保留。=="
echo "回滾:tar -C /opt/portal -xzf /root/_backups/portal-src-before-0140-<TS>.tgz"
echo "     + compose 蓋回 _backups/docker-compose.yml.before-portal0140-<最早TS> + up -d --force-recreate portal"
