#!/usr/bin/env bash
# finish-portal-0192.sh — portal 0.19.2:服務目錄加「開發/opencode」卡 + Kuma 存活監控地基
# ─────────────────────────────────────────────────────────────────────────────
# 內容:
#   1) OpenWrt 放行 10.80.80.11 → 192.168.20.60 tcp/4096(照 Archive-5003 模板,無 SNAT)
#      —— 給 CT201 Kuma 探活 opencode 用;opencode 有 Basic 密碼,401=活著。
#   2) 部署 bff registry.py(新增「開發」組 opencode 卡,kuma="opencode")+ main.py(0.19.2)。
#   3) 驗證 + 清 pve24 殘留腳本。
# ★ Kuma monitor 本身要你在 UI 手動建(無乾淨 API),步驟見腳本尾輸出。
# 在哪跑:CT260(codex-ops),身分 codex,路徑 ~/workspace/portal/scripts/。
#   需 ssh openwrt / ssh pve24 金鑰可用(互動鑰先 hl-unlock)。
# 回滾:見檔尾輸出。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
TS=$(date +%Y%m%d-%H%M%S)
cd ~/workspace/portal

echo "== 0. preflight =="
[ "$(hostname)" = "codex-ops" ] || { echo "✗ 請在 CT260(codex-ops)跑"; exit 1; }
ssh -o ConnectTimeout=6 openwrt true || { echo "✗ openwrt ssh 不可達(金鑰上鎖?先 hl-unlock)"; exit 1; }
ssh -o ConnectTimeout=6 pve24 true   || { echo "✗ pve24 ssh 不可達"; exit 1; }
grep -q '"開發"' bff/app/registry.py || { echo "✗ registry.py 無開發組,源檔不對"; exit 1; }
grep -q '0.19.2' bff/app/main.py     || { echo "✗ main.py 版本非 0.19.2"; exit 1; }

echo "== 1. OpenWrt 放行 4096(冪等) =="
if ssh openwrt "uci -q get firewall.allow_monitor_to_ct260_opencode.name" >/dev/null 2>&1; then
  echo "  規則已存在,跳過"
else
  ssh openwrt "cp /etc/config/firewall /etc/config/firewall.bak-opencode-$TS"
  mkdir -p ~/_backups
  ssh openwrt "cat /etc/config/firewall" > ~/_backups/openwrt-firewall.before-opencode-$TS
  ssh openwrt "
    uci set firewall.allow_monitor_to_ct260_opencode=rule
    uci set firewall.allow_monitor_to_ct260_opencode.name='Allow-Monitor-To-CT260-OpenCode-4096'
    uci set firewall.allow_monitor_to_ct260_opencode.src='service'
    uci set firewall.allow_monitor_to_ct260_opencode.src_ip='10.80.80.11'
    uci set firewall.allow_monitor_to_ct260_opencode.dest='servers'
    uci set firewall.allow_monitor_to_ct260_opencode.dest_ip='192.168.20.60'
    uci set firewall.allow_monitor_to_ct260_opencode.dest_port='4096'
    uci set firewall.allow_monitor_to_ct260_opencode.proto='tcp'
    uci set firewall.allow_monitor_to_ct260_opencode.target='ACCEPT'
    uci commit firewall && /etc/init.d/firewall reload >/dev/null 2>&1"
fi
ssh openwrt "nft list ruleset | grep -q 'OpenCode-4096'" && echo "  nft 已載入 OpenCode-4096 ✓" \
  || { echo "✗ nft 未見規則"; exit 1; }
c=$(ssh pve24 "sudo -n pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m6 http://192.168.20.60:4096/")
echo "  CT201→CT260:4096 → $c(應 401=通且要密碼)"
[ "$c" = "401" ] || { echo "✗ 探活路徑不通"; exit 1; }

echo "== 2. 部署 registry.py + main.py 到 CT201(image 本地 build pin:須 build 新 tag + compose 換版)=="
scp -q bff/app/registry.py bff/app/main.py pve24:/tmp/
ssh pve24 "
  sudo -n pct exec 201 -- cp -a /opt/portal/bff/app/registry.py /opt/portal/bff/app/registry.py.before-0192-$TS
  sudo -n pct exec 201 -- cp -a /opt/portal/bff/app/main.py /opt/portal/bff/app/main.py.before-0192-$TS
  sudo -n pct push 201 /tmp/registry.py /opt/portal/bff/app/registry.py --perms 644
  sudo -n pct push 201 /tmp/main.py /opt/portal/bff/app/main.py --perms 644
  rm -f /tmp/registry.py /tmp/main.py
  sudo -n pct exec 201 -- docker build -q -t portal:0.19.2 /opt/portal/bff
  sudo -n pct exec 201 -- sh -c '
    cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0192-$TS 2>/dev/null || true
    grep -q \"image: portal:0.19.2\" /opt/monitoring/docker-compose.yml || \
      sed -i \"s|image: portal:0.19.1|image: portal:0.19.2|\" /opt/monitoring/docker-compose.yml
    n=\$(grep -c \"image: portal:0.19.2\" /opt/monitoring/docker-compose.yml)
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

echo "== 3. 驗證 =="
SVC=$(ssh pve24 "sudo -n pct exec 201 -- curl -s -m8 http://127.0.0.1:8088/api/services")
echo "$SVC" | grep -q '"opencode"' && echo "  /api/services 含 opencode ✓" || { echo "✗ services 無 opencode"; exit 1; }
echo "$SVC" | grep -q '開發' && echo "  「開發」分組存在 ✓" || echo "  ⚠ 分組名未見(檢查前端顯示)"
for ep in health overview services; do
  printf "  /api/%s → " "$ep"
  ssh pve24 "sudo -n pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m8 http://127.0.0.1:8088/api/$ep"; echo
done

echo "== 4. 清 pve24 殘留 =="
ssh pve24 "rm -f ~/finish-hl-authstrip.sh" && echo "  已清 finish-hl-authstrip.sh"

echo
echo "✅ 完成(portal 0.19.2)。最後一步請你在 Kuma UI 手動建 monitor(portal 綠燈靠名字匹配):"
echo "   kuma.hl → Add New Monitor:"
echo "     Monitor Type = HTTP(s)"
echo "     Friendly Name = opencode      ← 必須小寫,portal 按此名對接"
echo "     URL = http://192.168.20.60:4096"
echo "     Accepted Status Codes = 401   ← opencode 有 Basic 密碼,401 即活著"
echo "   建完 portal 服務目錄的 opencode 卡即轉綠。"
echo
echo "── ROLLBACK ──"
echo "ssh openwrt 'uci delete firewall.allow_monitor_to_ct260_opencode; uci commit firewall; /etc/init.d/firewall reload'"
echo "ssh pve24 'sudo pct exec 201 -- cp -a /opt/portal/bff/app/registry.py.before-0192-$TS /opt/portal/bff/app/registry.py && sudo pct exec 201 -- cp -a /opt/portal/bff/app/main.py.before-0192-$TS /opt/portal/bff/app/main.py && sudo pct exec 201 -- cp -a /opt/monitoring/_backups/docker-compose.yml.before-portal0192-$TS /opt/monitoring/docker-compose.yml && sudo pct exec 201 -- sh -c \"cd /opt/monitoring && docker compose up -d portal\"'"
