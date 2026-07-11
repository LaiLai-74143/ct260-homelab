#!/bin/sh
# hl-claude-tmux-run: 重開機自動拉起 claude 常駐 tmux session(Remote Control 用)。
# 冪等:session 已存在即退出;只掛 cron @reboot,不做 */N 自癒——
#   使用者手動 tmux kill-session -t claude 時應保持死亡,不與人搶。
# 起法比照手動慣例:先開 shell 的 session 再 send-keys 進 claude,
#   claude 退出時 session 仍在,可 attach 察看殘骸。
# claude remote-control(子指令=server mode):註冊整個 workspace 目錄為遠端
#   目標(選單顯示 workspace · codex-ops · N of 32),手機/PC/web 可隨時對它
#   「開新對話」,由常駐 server 在本機 spawn session。三個坑,都踩過:
#   純 claude=只有本機 TUI;--remote-control 旗標=只曝光單一 session,
#   不能遠端開新對話;server mode 才是選單裡那個 workspace 條目。
# PATH 帶 npm-global:claude CLI 需要 node(cron 環境不含)。
PATH=/home/codex/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
export PATH
TERM="${TERM:-xterm-256color}"
export TERM

SESSION=claude

tmux has-session -t "$SESSION" 2>/dev/null && exit 0
tmux new-session -d -s "$SESSION" -c /home/codex/workspace
tmux send-keys -t "$SESSION" 'claude remote-control' Enter
