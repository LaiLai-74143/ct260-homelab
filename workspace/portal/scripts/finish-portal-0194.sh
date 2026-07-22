#!/usr/bin/env bash
# finish-portal-0194.sh — portal 0.19.4:檔案站獨立頁+底欄改版(取代未跑的 0193)
# ─────────────────────────────────────────────────────────────────────────────
# 內容:
#   前端:新增 /m/storage 檔案站頁(iframe 嵌 https://storage.lailai74143.com,
#         與電力/遊戲/生活同級);手機底欄「告警」→「檔案站」,告警入口移「更多」;
#         大廳多一張檔案站卡;⌘K 模塊清單含檔案站(g f 直跳)。
#   BFF:registry.py 生活組「檔案站」卡(0193 內容一併帶上)+版本 0.19.4。
#   ★ 已跑過 0193 也無妨(冪等);沒跑過 0193 直接跑本腳本即可,0193 作廢。
# 在哪跑:CT260(codex-ops),身分 codex,路徑 ~/workspace/portal/scripts/。
#   需 ssh pve24 金鑰可用(互動鑰先 hl-unlock)。
# 回滾:見檔尾輸出。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
TS=$(date +%Y%m%d-%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$ROOT"

echo "== 0. preflight =="
[ "$(hostname)" = "codex-ops" ] || { echo "✗ 請在 CT260(codex-ops)跑"; exit 1; }
ssh -o ConnectTimeout=6 pve24 true || { echo "✗ pve24 ssh 不可達(金鑰上鎖?先 hl-unlock)"; exit 1; }
grep -q '"檔案站"' bff/app/registry.py || { echo "✗ registry.py 無檔案站卡,源檔不對"; exit 1; }
grep -q '0.19.4' bff/app/main.py || { echo "✗ main.py 版本非 0.19.4"; exit 1; }
# 嵌入前置:公網檔案站可達且無擋 iframe 標頭(打會壞的那一層)
HDRS=$(curl -sI -m 10 https://storage.lailai74143.com/ | tr -d '\r')
echo "$HDRS" | head -1 | grep -q " 200" || { echo "✗ storage.lailai74143.com 非 200:$(echo "$HDRS" | head -1)"; exit 1; }
echo "$HDRS" | grep -qi 'x-frame-options\|content-security-policy' \
  && { echo "✗ storage 回應帶 X-Frame-Options/CSP,iframe 會被擋,先解再部署"; exit 1; }
echo "  storage 200 且無 frame 攔截標頭 ✓"

echo "== 1. 前端 build + 斷言 =="
( cd frontend && npm run build ) >/dev/null
[ -f frontend/dist/index.html ] || { echo "✗ dist 缺 index.html"; exit 1; }
grep -rq "portal v0.19.4" frontend/dist/assets/*.js || { echo "✗ bundle 版號非 v0.19.4"; exit 1; }
grep -rq "m/storage" frontend/dist/assets/*.js || { echo "✗ bundle 無 /m/storage 路由"; exit 1; }
grep -rq "檔案站" frontend/dist/assets/*.js || { echo "✗ bundle 無檔案站字串"; exit 1; }
grep -rq "storage.lailai74143.com" frontend/dist/assets/*.js || { echo "✗ bundle 無 iframe 目標網址"; exit 1; }
# 回歸斷言(既有功能仍在)
grep -rq "命令面板" frontend/dist/assets/*.js || { echo "✗ 回歸:bundle 無命令面板"; exit 1; }
grep -rq "近期行程" frontend/dist/assets/*.js || { echo "✗ 回歸:bundle 無近期行程"; exit 1; }
grep -rq "拾遺歸檔" frontend/dist/assets/*.js || { echo "✗ 回歸:bundle 無拾遺歸檔"; exit 1; }
echo "  bundle 斷言全過 ✓"

echo "== 2. 打包 static + bff,傳輸 pve24 → pct push CT201 =="
tar -C frontend/dist -czf "$TMP/portal-static.tgz" .
tar -C bff --exclude .venv --exclude '__pycache__' -czf "$TMP/portal-bff.tgz" app Dockerfile requirements.txt
STATIC_SHA=$(sha256sum "$TMP/portal-static.tgz" | cut -d' ' -f1)
BFF_SHA=$(sha256sum "$TMP/portal-bff.tgz" | cut -d' ' -f1)
scp -q "$TMP/portal-static.tgz" "$TMP/portal-bff.tgz" pve24:/tmp/
ssh pve24 'sudo -n pct push 201 /tmp/portal-static.tgz /tmp/portal-static.tgz && \
           sudo -n pct push 201 /tmp/portal-bff.tgz /tmp/portal-bff.tgz && \
           rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz'

echo "== 3. CT201:sha 驗證 + 備份 + 換源 + docker build 0.19.4 =="
ssh pve24 "sudo -n pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
sha256sum /tmp/portal-static.tgz | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
sha256sum /tmp/portal-bff.tgz    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
# 首跑才建備份(0180 同款 guard):失敗後重跑時 static/ 已是新版,無 guard 會把
# 「新版內容」存成 before-0194 偽備份、再 rm 掉唯一真舊版(對抗審查 1532 沙盤實證)
ls /root/_backups/portal-src-before-0194-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0194-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.19.4 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 → 0.19.4(錨點自適應 0.19.0~0.19.3;已是 0.19.4 冪等跳過) =="
ssh pve24 'sudo -n pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "✗ compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.19.4" in s:
    print("compose 已是 0.19.4(冪等跳過)")
else:
    m = re.search(r"    image: portal:(0\.19\.[0-3])\n", s)
    assert m, "錨點未命中:image tag 非 0.19.0~0.19.3(現役版本出乎預期,人工確認)"
    s = s.replace(f"    image: portal:{m.group(1)}", "    image: portal:0.19.4", 1)
    open(p, "w").write(s); print(f"compose edited: {m.group(1)} -> 0.19.4")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo -n pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo -n pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0194-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0194-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
'"

echo "  等 portal 就緒(最多 30s)…"
for i in $(seq 1 10); do
  st=$(ssh pve24 "sudo -n pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m5 http://127.0.0.1:8088/api/health" 2>/dev/null || echo 000)
  [ "$st" = "200" ] && break
  sleep 3
done
[ "$st" = "200" ] || { echo "✗ /api/health 未回 200(得 $st)——先回滾再排查"; exit 1; }
ssh pve24 "sudo -n pct exec 201 -- docker ps --format '{{.Names}} {{.Image}} {{.Status}}'" | grep -i portal

echo "== 5. 驗證 =="
SVC=$(ssh pve24 "sudo -n pct exec 201 -- curl -s -m8 http://127.0.0.1:8088/api/services")
echo "$SVC" | grep -q '"檔案站"' && echo "  /api/services 含 檔案站 ✓" || { echo "✗ services 無檔案站"; exit 1; }
echo "$SVC" | grep -q 'storage.lailai74143.com' && echo "  url_hl=storage.* ✓" || { echo "✗ 卡片缺公網 URL"; exit 1; }
ssh pve24 "sudo -n pct exec 201 -- grep -rq 'm/storage' /opt/portal/static/assets" \
  && echo "  static 已含 /m/storage 新殼 ✓" || { echo "✗ CT201 static 缺新頁(換源失敗?)"; exit 1; }
for ep in health overview alerts brief services security game life power spark archive; do
  code=$(ssh pve24 "sudo -n pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/$ep")
  printf "  /api/%s → %s\n" "$ep" "$code"
  [ "$code" = "200" ] || { echo "✗ 端點回歸失敗"; exit 1; }
done
ssh pve24 "sudo -n pct exec 201 -- rm -rf /opt/portal/static.old /opt/portal/bff.old"

echo
echo "✅ 完成(portal 0.19.4)。體感驗收:"
echo "   ① 手機開 portal.hl:底欄=大廳/設備/檔案站/更多;點檔案站=整頁檔案站(首次輸通行碼);"
echo "   ② 更多頁多「告警中心」磚(告警沒消失,只是搬家);"
echo "   ③ 大廳多一張〔檔案站〕卡;桌面側欄同見;⌘K 打「檔案站」或 g f 直跳。"
echo
echo "── ROLLBACK ──(備份是首跑建立的唯一一份,用 glob 找,重跑過也不會指錯)"
cat <<'ROLLBACK'
ssh pve24 'sudo pct exec 201 -- sh -c "tar -C /opt/portal -xzf \$(ls /root/_backups/portal-src-before-0194-*.tgz | head -1)"'
ssh pve24 'sudo pct exec 201 -- sh -c "cp \$(ls /opt/monitoring/_backups/docker-compose.yml.before-portal0194-* | head -1) /opt/monitoring/docker-compose.yml"'
ssh pve24 'sudo pct exec 201 -- sh -c "cd /opt/monitoring && docker compose up -d --force-recreate portal"'
ROLLBACK
