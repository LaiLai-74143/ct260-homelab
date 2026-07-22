#!/usr/bin/env bash
# finish-portal-0193.sh — portal 0.19.3:服務目錄「生活」組加「檔案站」卡
# ─────────────────────────────────────────────────────────────────────────────
# 內容:
#   部署 bff registry.py(生活組新增檔案站卡:LAN=ct260:8790/files、公網=storage.lailai74143.com)
#   + main.py(版本 0.19.3)。無防火牆/Kuma 變更(公網走既有 CF Tunnel;LAN 8790 既有可達)。
# 在哪跑:CT260(codex-ops),身分 codex,路徑 ~/workspace/portal/scripts/。
#   需 ssh pve24 金鑰可用(互動鑰先 hl-unlock)。
# 回滾:見檔尾輸出。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
TS=$(date +%Y%m%d-%H%M%S)
cd ~/workspace/portal

echo "== 0. preflight =="
[ "$(hostname)" = "codex-ops" ] || { echo "✗ 請在 CT260(codex-ops)跑"; exit 1; }
ssh -o ConnectTimeout=6 pve24 true || { echo "✗ pve24 ssh 不可達(金鑰上鎖?先 hl-unlock)"; exit 1; }
grep -q '"檔案站"' bff/app/registry.py || { echo "✗ registry.py 無檔案站卡,源檔不對"; exit 1; }
grep -q '0.19.3' bff/app/main.py || { echo "✗ main.py 版本非 0.19.3"; exit 1; }

echo "== 1. 部署 registry.py + main.py 到 CT201(image 本地 build pin:build 新 tag + compose 換版)=="
scp -q bff/app/registry.py bff/app/main.py pve24:/tmp/
ssh pve24 "
  sudo -n pct exec 201 -- cp -a /opt/portal/bff/app/registry.py /opt/portal/bff/app/registry.py.before-0193-$TS
  sudo -n pct exec 201 -- cp -a /opt/portal/bff/app/main.py /opt/portal/bff/app/main.py.before-0193-$TS
  sudo -n pct push 201 /tmp/registry.py /opt/portal/bff/app/registry.py --perms 644
  sudo -n pct push 201 /tmp/main.py /opt/portal/bff/app/main.py --perms 644
  rm -f /tmp/registry.py /tmp/main.py
  sudo -n pct exec 201 -- docker build -q -t portal:0.19.3 /opt/portal/bff
  sudo -n pct exec 201 -- sh -c '
    cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0193-$TS 2>/dev/null || true
    grep -q \"image: portal:0.19.3\" /opt/monitoring/docker-compose.yml || \
      sed -i \"s|image: portal:0.19.2|image: portal:0.19.3|\" /opt/monitoring/docker-compose.yml
    n=\$(grep -c \"image: portal:0.19.3\" /opt/monitoring/docker-compose.yml)
    [ \"\$n\" = \"1\" ] || { echo \"✗ compose 換版異常(匹配 \$n 處),中止\"; exit 1; }
    cd /opt/monitoring && docker compose up -d portal >/dev/null 2>&1
  '
"
echo "  等 portal 就緒(最多 30s)…"
for i in $(seq 1 10); do
  st=$(ssh pve24 "sudo -n pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m5 http://127.0.0.1:8088/api/health" 2>/dev/null || echo 000)
  [ "$st" = "200" ] && break
  sleep 3
done
ssh pve24 "sudo -n pct exec 201 -- docker ps --format '{{.Names}} {{.Image}} {{.Status}}'" | grep -i portal

echo "== 2. 驗證 =="
SVC=$(ssh pve24 "sudo -n pct exec 201 -- curl -s -m8 http://127.0.0.1:8088/api/services")
echo "$SVC" | grep -q '"檔案站"' && echo "  /api/services 含 檔案站 ✓" || { echo "✗ services 無檔案站"; exit 1; }
echo "$SVC" | grep -q 'storage.lailai74143.com' && echo "  url_hl=storage.* ✓" || { echo "✗ 卡片缺公網 URL"; exit 1; }

echo
echo "✅ 完成(portal 0.19.3)。入口大廳(portal.hl / App 大廳分頁)「生活」組應出現「檔案站」卡。"
echo
echo "── ROLLBACK ──"
echo "ssh pve24 'sudo pct exec 201 -- cp -a /opt/portal/bff/app/registry.py.before-0193-$TS /opt/portal/bff/app/registry.py && sudo pct exec 201 -- cp -a /opt/portal/bff/app/main.py.before-0193-$TS /opt/portal/bff/app/main.py && sudo pct exec 201 -- sh -c \"cd /opt/monitoring && docker compose up -d portal\"'"
