#!/bin/bash
# finish-sweep-leftovers.sh — 打掃窗分類器攔下的兩件(2026-07-10)
# 在哪跑:CT260(codex@codex-ops):bash ~/workspace/ops/finish-sweep-leftovers.sh
# ① CT203/204/205 停用無用 sshd listener(皆無 authorized_keys+root pw locked,
#    本無登入途徑,關掉純減攻擊面;V7 §10.7/§10.8 待裁決項=採「停用」)
# ② pve24 孤兒 tailscaled 程序(節點已裁、unit disabled,程序殘留)——需 pve24 root,
#    本腳本只印指令請你在 pve24 root 下貼上。
# 回滾:pct exec <id> -- systemctl enable --now ssh.service
set -euo pipefail

echo "== 1. CT203/204/205 停用 sshd =="
for id in 203 204 205; do
  ssh pve24 "sudo /usr/sbin/pct exec $id -- sh -c 'systemctl disable --now ssh.service ssh.socket >/dev/null 2>&1 || true; echo CT$id ssh.service=\$(systemctl is-active ssh.service 2>&1)'"
done

echo
echo "== 2. pve24 孤兒 tailscaled(請在 pve24 root 下手動執行以下兩行) =="
echo "  pkill -x tailscaled; sleep 1; pgrep -x tailscaled || echo tailscaled-gone"
echo "  systemctl is-enabled tailscaled 2>&1   # 預期 disabled/not-found"
echo
echo "== 完成後回報,我更新 V7(sshd 停用+孤兒清理兩條劃掉) =="
