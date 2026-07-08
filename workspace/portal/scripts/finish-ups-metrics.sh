#!/bin/bash
# finish-ups-metrics.sh — 待辦49 電力模塊:pve24 upsc → node_exporter textfile 管線
# ★ 在 pve24 上以 root 執行(codex-admin sudo 僅限 pct/qm/pvesh/pvesm,寫 host 檔需本腳本)
# 比照 CT202 squid-metrics.sh 前例:零新埠、零防火牆,騎現有 pve-node:9100 scrape。
# 冪等:重跑覆蓋同名檔。回滾:rm /usr/local/bin/ups-metrics.sh /etc/cron.d/ups-metrics \
#       /var/lib/prometheus/node-exporter/ups.prom
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "請以 root 執行(su - 或 sudo bash $0)"; exit 1; }
[ -d /var/lib/prometheus/node-exporter ] || { echo "textfile 目錄不存在,中止"; exit 1; }

echo "== 1. 安裝 /usr/local/bin/ups-metrics.sh =="
cat > /usr/local/bin/ups-metrics.sh <<'SCRIPT'
#!/bin/bash
# ups-metrics.sh — upsc ups0@192.168.100.2(VLAN100 帶外)→ textfile(待辦49 電力模塊)
set -u
OUT=/var/lib/prometheus/node-exporter/ups.prom
TMP=$(mktemp "$OUT.XXXXXX")
trap 'rm -f "$TMP"' EXIT
DATA=$(upsc ups0@192.168.100.2 2>/dev/null || true)
emit() { [[ "$2" =~ ^-?[0-9.]+$ ]] && echo "$1 $2" >> "$TMP"; }  # 非數值略過,不寫壞格式
if [ -z "$DATA" ]; then
  echo "nut_upsc_ok 0" >> "$TMP"
else
  echo "nut_upsc_ok 1" >> "$TMP"
  get() { awk -F': ' -v k="$1" '$1==k{print $2}' <<<"$DATA"; }
  STATUS=$(get ups.status)
  onb=0; [[ "$STATUS" == *OB* ]] && onb=1
  lb=0;  [[ "$STATUS" == *LB* ]] && lb=1
  echo "nut_ups_on_battery $onb" >> "$TMP"
  echo "nut_battery_low $lb" >> "$TMP"
  emit nut_battery_charge_percent    "$(get battery.charge)"
  emit nut_battery_runtime_seconds   "$(get battery.runtime)"
  emit nut_ups_load_percent          "$(get ups.load)"
  emit nut_input_voltage_volts       "$(get input.voltage)"
  emit nut_ups_realpower_nominal_watts "$(get ups.realpower.nominal)"
fi
chmod 644 "$TMP" && mv "$TMP" "$OUT"   # 同目錄 mktemp+mv=原子換檔
trap - EXIT
SCRIPT
chmod 755 /usr/local/bin/ups-metrics.sh

echo "== 2. 安裝 cron(每分鐘) =="
cat > /etc/cron.d/ups-metrics <<'CRON'
# 待辦49 電力模塊:UPS 指標每分鐘刷新(→ /var/lib/prometheus/node-exporter/ups.prom)
* * * * * root /usr/local/bin/ups-metrics.sh
CRON
chmod 644 /etc/cron.d/ups-metrics

echo "== 3. 首跑 + 驗證 =="
/usr/local/bin/ups-metrics.sh
cat /var/lib/prometheus/node-exporter/ups.prom
grep -q "nut_upsc_ok 1" /var/lib/prometheus/node-exporter/ups.prom || { echo "★ upsc 讀取失敗,查 NUT"; exit 1; }
sleep 1
curl -s http://127.0.0.1:9100/metrics | grep -c "^nut_" \
  && echo "== 完成:node_exporter 已吐 nut_* 指標,Prometheus 60s 內入庫,portal 電力頁自動亮 =="
