#!/bin/sh
# hl-wol-watch — 困死救援看門狗(★在 OpenWrt VM101 以 root 身份、經 cron */5 執行)
# 場景(缺改記錄 2026-07-11 邊界②):UPS 斷電後 pve24(T+3m)/DXP(T+10m)已軟關機,
#   市電在 killpower 熄燈前回來 → UPS 輸出從未中斷 → BIOS AC-recovery 等不到來電邊沿,
#   主機被晾在 S5。兩機 WoL 均已在 BIOS/UGOS 開啟(2026-07-11 使用者確認),由本腳本補喚醒。
# 邏輯:連續 2 輪(約 10 分)ping 不到 → 對該主機丟 etherwake magic packet ×3;
#   每主機 3600s 冷卻;恢復即清狀態。對開機中/已開機主機發 WoL 無副作用;
#   全屋斷電時 OpenWrt 自己也死,通電重啟後 cron 自然接手,無需 @reboot(busybox crond 不支援)。
# 停用(計畫性關機維護必用,否則 10 分後會被喚醒):
#   touch /etc/hl-wol-watch.off(持久)或 /tmp/hl-wol-watch.off(重開機自動失效)
# 部署:OpenWrt /usr/local/bin/hl-wol-watch + /etc/crontabs/root(*/5)
# SoT:CT260 ~/workspace/ops/hl-wol-watch.sh;日誌:logread -e hl-wol-watch
set -u

[ -f /etc/hl-wol-watch.off ] && exit 0
[ -f /tmp/hl-wol-watch.off ] && exit 0

STATE=/tmp/hl-wol-watch
mkdir -p "$STATE"
COOLDOWN=3600
NEED_FAILS=2

wake_check() {
  name=$1; ip=$2; mac=$3; iface=$4
  if ping -c 3 -W 2 "$ip" >/dev/null 2>&1; then
    if [ -f "$STATE/$name.fails" ]; then
      logger -t hl-wol-watch "$name back online, state cleared"
      rm -f "$STATE/$name.fails" "$STATE/$name.last"
    fi
    return 0
  fi
  n=$(cat "$STATE/$name.fails" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$STATE/$name.fails"
  if [ "$n" -lt "$NEED_FAILS" ]; then
    logger -t hl-wol-watch "$name unreachable ($n/$NEED_FAILS), observing"
    return 0
  fi
  now=$(date +%s)
  last=$(cat "$STATE/$name.last" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt "$COOLDOWN" ]; then
    return 0
  fi
  echo "$now" > "$STATE/$name.last"
  logger -t hl-wol-watch "$name unreachable >=${NEED_FAILS} rounds, sending WoL to $mac via $iface (x3)"
  i=0
  while [ "$i" -lt 3 ]; do
    /usr/bin/etherwake -i "$iface" "$mac" 2>&1 | logger -t hl-wol-watch
    i=$((i + 1))
    sleep 1
  done
}

# name      ip            mac                iface(該主機 WoL NIC 所在 VLAN 的 L2 介面)
wake_check pve24   192.168.20.5 00:e2:69:90:72:8b eth1.20
wake_check dxp4800 192.168.30.3 6c:1f:f7:a7:64:55 eth1.30
