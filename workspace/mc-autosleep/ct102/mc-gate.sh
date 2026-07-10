#!/bin/bash
# CT102 /opt/velocity/mc-gate.sh —— LimboAutoServer start/stop 指令的唯一出口。
# 打 CT100 mc-gate hook(:25580),由 hook 走 MCSM protected_instance 穩定路徑。
# token 在 /opt/velocity/mc-gate.env(600 velocity:velocity),不進本檔、不進插件 config。
set -euo pipefail
case "${1:-}" in start|stop) ;; *) echo "usage: mc-gate.sh start|stop" >&2; exit 2;; esac
source /opt/velocity/mc-gate.env   # GATE_URL / GATE_TOKEN
exec curl -fsS -m 10 -X POST -H "Authorization: Bearer ${GATE_TOKEN}" "${GATE_URL}/$1"
