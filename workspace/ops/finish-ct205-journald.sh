#!/bin/bash
# finish-ct205-journald.sh — CT205 journald 243/CREDENTIALS 修復(同 CT202 病根)
# 根因:nesting=0 的 unprivileged LXC 撞 systemd 257 憑證機制(Debian 13)。
# 修法:開 nesting + 重啟(CT202 已同法修癒,2026-07-10)。
# 在哪跑:CT260(codex@codex-ops)一般使用者:bash ~/workspace/ops/finish-ct205-journald.sh
# 影響:CT205 重啟=guest-portal(schedule.lailai74143.com)中斷約 15 秒。
# 回滾:pct set 205 -features nesting=0(journald 會再壞,不建議)。
set -euo pipefail

echo "== 1. 開 nesting + 重啟 CT205 =="
ssh pve24 'sudo /usr/sbin/pct set 205 -features nesting=1 && sudo /usr/sbin/pct reboot 205'
sleep 12

echo "== 2. 驗證 =="
ssh pve24 'echo "journald=$(sudo /usr/sbin/pct exec 205 -- systemctl is-active systemd-journald)";
sudo /usr/sbin/pct exec 205 -- sh -c "curl -sm4 -o /dev/null -w \"guest-portal=%{http_code}\n\" localhost:8300/"'

echo "== 完成:journald=active 且 guest-portal=200/302 即全綠 =="
