#!/bin/bash
# finish-22b-passphrase.sh — 待辦22 互動段:給 ops 鑰上密碼+首次解鎖+鎖定態演示。
# 前置:finish-22-keylock.sh(非互動段)已跑完。root 執行法:
#   su - codex -c 'bash ~/workspace/monitoring/finish-22b-passphrase.sh'
set -euo pipefail
OPS=~/.ssh/ct260_ops_ed25519

echo "== 8. ★互動:給 ops 鑰上密碼(自訂,輸兩次;之後 hl-unlock 用同一密碼) =="
ssh-keygen -p -f "$OPS"
ssh-keygen -y -P '' -f "$OPS" >/dev/null 2>&1 && { echo "鑰仍未加密?中止"; exit 1; } || echo "ops 鑰已靜態加密 ✔"

echo ""
echo "== 9. ★互動:首次解鎖(輸一次密碼,快取 6h) =="
~/.local/bin/hl-unlock
ssh -o BatchMode=yes pve24 'echo unlocked-path-ok'

echo ""
echo "== 10. 鎖定態演示:上鎖→直連面應失敗→再解鎖由你決定 =="
~/.local/bin/hl-lock
ssh -o BatchMode=yes -o ConnectTimeout=6 pve24 'echo x' 2>/dev/null && { echo "★異常:鎖定後仍可直連"; exit 1; } || echo "鎖定驗證 ✔(直連面已封)"
~/.local/bin/watchdog-ct201.sh >/dev/null && echo "鎖定下 watchdog 仍通 ✔(自動軌不受鎖)"
echo ""
echo "== 完成。日常:要幹活時 hl-unlock(6h 自動失效);agent 碰鎖會請你解鎖。 =="
echo "   現在是上鎖狀態;要繼續讓 agent 幹活就跑一次 hl-unlock。"
