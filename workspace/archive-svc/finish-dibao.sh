#!/bin/bash
# finish-dibao.sh — 邸報管線(待辦49 0.19.0)收尾兩件:
#   1) CT260 dibao-ingest cron(05:20/17:20 台北,flock 防重入)
#   2) 驗證:archive-svc rev 0190a、dibao 乾跑、晨報 top-7 出 7 條
# 在哪跑:CT260(codex@codex-ops)~/workspace/archive-svc/。冪等:重跑無害。
# 前置(Agent 已完成,本腳本只驗不改):archive-svc 0190a 已裝+在跑、
#   dibao-ingest.py 已裝 ~/.local/bin、homelab-notify.py 已改(備份在
#   ~/_backups/homelab-notify.py.before-dibao-*)。
# 回滾:crontab 刪 dibao-ingest 兩行;notify 蓋回上述備份;
#   svc 蓋回 0180b(~/workspace 用 git checkout)後重啟。
set -euo pipefail

echo "== 0. 前檢 =="
[ -x ~/.local/bin/dibao-ingest.py ] || { echo "缺 ~/.local/bin/dibao-ingest.py"; exit 1; }
curl -s -m 4 http://127.0.0.1:5003/health | grep -q '"rev": "0190b"' \
  || { echo "archive-svc 非 0190b(先跑 Agent 的安裝段或查 log)"; exit 1; }
grep -q 'fetch_dibao_top7' ~/.local/bin/homelab-notify.py \
  || { echo "homelab-notify.py 未含邸報段(改動遺失?)"; exit 1; }
grep -q '^ARCHIVE_TOKEN=' ~/.config/homelab/archive.env || { echo "缺 ARCHIVE_TOKEN"; exit 1; }

echo "== 1. cron:dibao-ingest 台北 05:20/17:20(系統 UTC → 21:20/09:20;照 write-brief '0 22' 慣例)=="
( crontab -l 2>/dev/null | grep -v 'dibao-ingest' || true ;
  echo '# dibao-ingest: 邸報抓取歸納(FreshRSS→DeepSeek 評分→archive-svc);UTC 21:20/09:20=台北 05:20/17:20 (待辦#49 0.19, added 2026-07-12)' ;
  echo '20 21,9 * * * /usr/bin/flock -n /home/codex/.local/state/archive-svc/.dibao.lock /usr/bin/python3 /home/codex/.local/bin/dibao-ingest.py' ) | crontab -
echo "cron 行數(應為1):$(crontab -l | grep -c 'dibao-ingest.py' || true)"

echo "== 2. dibao 乾跑冒煙(拉 5 條,真 FreshRSS+DeepSeek,不入庫) =="
python3 ~/.local/bin/dibao-ingest.py --dry-run --limit 5 >/dev/null \
  && echo "dibao dry-run ✓(細節見 ~/.local/state/archive-svc/dibao.log 尾行)" \
  || { echo "dibao dry-run 失敗,見 dibao.log"; exit 1; }

echo "== 3. 晨報冒煙:--write-brief --dry-run 應出今日訊息(邸報 top-7 或 fallback) =="
python3 ~/.local/bin/homelab-notify.py --write-brief --dry-run >/dev/null 2>&1
python3 - <<'EOF'
import json, os
d = json.load(open(os.path.expanduser("~/.local/state/homelab-notify/brief.json")))
secs = [s for s in d["sections"] if s["h"] == "今日訊息"]
assert secs, "brief 缺今日訊息段"
n = len(secs[0]["body"].split(";"))
print(f"今日訊息條數:{n}(邸報有件時應為 7;fallback 為 5-8)")
assert 1 <= n <= 8, "條數異常"
EOF

echo "== 完成。邸報班次:05:20/17:20;晨報 06:00 自動取前一日 top-7。"
echo "   portal 前端要看到邸報頁,還需跑 finish-portal-0190.sh。=="
