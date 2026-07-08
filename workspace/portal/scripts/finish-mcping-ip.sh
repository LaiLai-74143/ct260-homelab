#!/bin/bash
# finish-mcping-ip.sh — 待辦49:把 MCSM Fabric-MC 實例的狀態偵測 ping IP 由 127.0.0.1 改 10.70.70.20
# 原因:MC 伺服器 server-ip=10.70.70.20(只綁該 IP,不聽 127.0.0.1);MCSM 這版無 UI 欄位,
#      ping 目標存在 daemon 設定檔 pingConfig.ip。只改這一欄,不動 MC 進程、不重啟 daemon。
# 冪等:重跑無害(已是目標值則跳過)。回滾:cp <備份> 回原檔(daemon 下次 ping 週期即回舊值)。
set -euo pipefail
UUID=ae5eedd036f64640968539f28b810881
CFG="/opt/mcsmanager/daemon/data/InstanceConfig/$UUID.json"
NEW_IP=10.70.70.20
TS=$(date +%Y%m%d_%H%M%S)

echo "== 1. 備份 + 只改 pingConfig.ip(Python,保留其餘欄位/縮排風格) =="
ssh pve24 "sudo pct exec 100 -- python3 - '$CFG' '$NEW_IP' '$TS' <<'EOF'
import json, sys, shutil
cfg, new_ip, ts = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(cfg, encoding='utf-8'))
pc = d.get('pingConfig') or {}
if pc.get('ip') == new_ip:
    print('已是目標值,跳過(冪等)'); sys.exit(0)
shutil.copy2(cfg, f'/root/mcsm-instance-{ts}.json.bak')
pc['ip'] = new_ip
d['pingConfig'] = pc
json.dump(d, open(cfg, 'w', encoding='utf-8'), ensure_ascii=False)
print(f'pingConfig.ip -> {new_ip}(備份 /root/mcsm-instance-{ts}.json.bak)')
EOF"

echo "== 2. 等 daemon 下一個 ping 週期(最多 40s),輪詢 API mcPingOnline =="
KEY_CMD='sed -n "s/^MCSM_API_KEY=//p" /opt/portal/portal.env | tr -d "\047\042"'
for i in $(seq 1 8); do
  sleep 5
  RES=$(ssh pve24 "sudo pct exec 201 -- bash -c 'KEY=\$($KEY_CMD); curl -s -m5 -H \"X-Requested-With: XMLHttpRequest\" \"http://10.70.70.20:23333/api/instance?uuid=$UUID&daemonId=0c0d7ec736f24985836a8bbecbcb8788&apikey=\$KEY\"'" 2>/dev/null)
  ONLINE=$(printf '%s' "$RES" | grep -o '"mcPingOnline":[a-z]*' | cut -d: -f2)
  PLAYERS=$(printf '%s' "$RES" | grep -o '"currentPlayers":[0-9]*' | cut -d: -f2)
  echo "  第 ${i} 次:mcPingOnline=$ONLINE currentPlayers=$PLAYERS"
  [ "$ONLINE" = "true" ] && { echo "== ping 上線,玩家數已可取($PLAYERS);遊戲頁下次刷新即亮 =="; exit 0; }
done
echo "== 40s 內 mcPingOnline 仍 false。可能 daemon 需重讀設定(MCSM UI 重啟實例的 daemon 連線,"
echo "   或稍待更久);MC 伺服器本身未動。備份 /root/mcsm-instance-$TS.json.bak =="
exit 1
