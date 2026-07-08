#!/bin/bash
# finish-37-exporter.sh — DXP4800 node_exporter 三重修復(待辦37 順帶;需 NAS SSH 窗開著)
# 在 CT260 以一般使用者執行:bash ~/workspace/monitoring/finish-37-exporter.sh
# 修:1) 綁 0.0.0.0(base unit 舊值 .31.3 legacy,綁具體 IP 開機時 IP 未就緒起不來)
#     2) --no-collector.textfile(/var/lib/prometheus 不存在,每 15s ERROR 灌爆 user journal
#        →歷史被輪轉沖光=先前「dead-no-journal」之源)
#     3) unit 檔 world-writable 修 644(本地提權面)
# 回滾:override.conf.before-todo37-* 蓋回 + daemon-reload + restart。
set -euo pipefail
ssh dxp4800 "sh -s" <<'EOF'
set -e
cd ~/.config/systemd/user
cp prometheus-node-exporter.service.d/override.conf prometheus-node-exporter.service.d/override.conf.before-todo37-$(date +%Y%m%d_%H%M%S)
cat > prometheus-node-exporter.service.d/override.conf <<'CONF'
# 待辦37 修復(2026-07-09):綁 0.0.0.0=開機順序免疫(VLAN30 有防火牆、VLAN100 封閉 L2 島);
# --no-collector.textfile=止住 journal 每 15s ERROR 洪水(dead-no-journal 之源)。
[Service]
ExecStart=
ExecStart=/home/My-Big-Nas/.local/bin/prometheus-node-exporter --web.listen-address=:9100 --no-collector.textfile
CONF
chmod 644 prometheus-node-exporter.service prometheus-node-exporter.service.d/override.conf
systemctl --user daemon-reload
systemctl --user restart prometheus-node-exporter
sleep 2
systemctl --user is-active prometheus-node-exporter
err=$(journalctl --user -u prometheus-node-exporter --since '-1 min' --no-pager 2>/dev/null | grep -c "failed to read textfile" || true)
echo "textfile-errors(1min): $err"
EOF
ssh pve24 "sudo pct exec 201 -- curl -sm6 -o /dev/null -w 'CT201 scrape → %{http_code}\n' http://nas.home.arpa:9100/metrics"
ssh pve24 "curl -sm6 -o /dev/null -w 'pve24 VLAN100 快徑 → %{http_code}\n' http://192.168.100.2:9100/metrics"

echo "== 收納(待辦37):散落的 VM101 vzdump 歸位 Router_PVE_OpenWrt/dump/ =="
ssh dxp4800 'f=/volume3/Back_up/24BaysNAS_PVE/vzdump-qemu-101-2026_06_27-04_40_02.vma.zst
[ -f "$f" ] && mv "$f" /volume3/Back_up/Router_PVE_OpenWrt/dump/ && echo moved-ok || echo "已歸位或不存在(冪等)"'
echo "== 完成:預期 active + errors=0 + 兩路 200 + moved-ok =="
