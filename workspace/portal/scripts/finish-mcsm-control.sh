#!/bin/bash
# finish-mcsm-control.sh — 落 MCSM_CTRL_KEY 到 CT201 portal.env,開通遊戲頁控制鍵。
#
# 前置(使用者在 MCSM 面板做):建/取一把「可操作 Fabric-MC 實例」的 API key
#   (該帳號需被指派此實例並允許操作;與唯讀玩家數用的 MCSM_API_KEY 分開,可獨立輪替),
#   把 key 寫進 CT260 ~/.config/homelab/mcsm-control.env(600,不入 git):
#       MCSM_CTRL_KEY=<那把 key>
# 本腳本:①驗證 key 能經 CT201 解析到實例(不真開停);②經檔案動線落 portal.env
#   (不經 pve24 ps);③force-recreate portal;④E2E 驗控制塊 enabled 與白名單。
# 安全界定:控制半徑=BFF 白名單三動作 open/stop/restart(不含 kill/檔案/設定);
#   允許 portal.hl+PC40 皆按(使用者裁決 2026-07-09)。
# 冪等:key 已在則跳過合併。回滾:portal.env 蓋回 .before-mcsmctrl-<TS> + force-recreate。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
SRC=~/.config/homelab/mcsm-control.env
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 讀控制 key(僅本機檔,不落 ps/argv) =="
[ -f "$SRC" ] || { echo "缺 $SRC——先在 MCSM 面板取可操作實例的 API key 寫入(見檔頭)"; exit 1; }
chmod 600 "$SRC"
CTRL_KEY=$(sed -n 's/^MCSM_CTRL_KEY=//p' "$SRC" | head -1)
[ -n "$CTRL_KEY" ] || { echo "$SRC 內無 MCSM_CTRL_KEY= 行"; exit 1; }

echo "== 1. 驗證 key 能解析實例(經 CT201 python 打 MCSM;key 全程只在檔案,不進 argv/ps) =="
printf 'apikey=%s\n' "$CTRL_KEY" > "$TMP/q"
scp -pq "$TMP/q" pve24:/tmp/mcsmq
ssh pve24 "sudo pct push 201 /tmp/mcsmq /tmp/mcsmq && rm -f /tmp/mcsmq"
# trap 保證失敗(MCSM 不通/斷言炸)也清掉含明文 key 的暫存檔(審查確認項)
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
trap \"rm -f /tmp/mcsmq\" EXIT
python3 - <<\"PYEOF\"
import json, urllib.parse, urllib.request
ak = [l.split(\"=\", 1)[1].strip() for l in open(\"/tmp/mcsmq\") if l.startswith(\"apikey=\")][0]
q = urllib.parse.urlencode({\"apikey\": ak, \"advanced\": \"true\"})
req = urllib.request.Request(\"http://10.70.70.20:23333/api/auth/?\" + q,
                             headers={\"X-Requested-With\": \"XMLHttpRequest\"})
d = json.loads(urllib.request.urlopen(req, timeout=8).read())
insts = (d.get(\"data\") or {}).get(\"instances\") or []
m = [i for i in insts if i.get(\"nickname\") == \"Fabric-MC\"]
assert m, \"key 可用但無 Fabric-MC 實例指派——面板把 Fabric-MC 指派給此帳號\"
i = m[0]
assert i.get(\"instanceUuid\") and i.get(\"daemonId\"), \"實例缺 uuid/daemonId\"
print(\"實例解析 ✓:\", i.get(\"nickname\"), (i.get(\"instanceUuid\") or \"\")[:8] + \"…\",
      \"| MCSM 狀態碼:\", i.get(\"status\"))
PYEOF
'"

echo "== 2. 落 portal.env(檔案動線,不經 pve24 ps) =="
printf 'MCSM_CTRL_KEY=%s\n' "$CTRL_KEY" > "$TMP/env-add"
scp -pq "$TMP/env-add" pve24:/tmp/portal-env-add
ssh pve24 "sudo pct push 201 /tmp/portal-env-add /tmp/portal-env-add && rm -f /tmp/portal-env-add"
ssh pve24 "sudo pct exec 201 -- sh -c '
set -e
touch /opt/portal/portal.env
if grep -q \"^MCSM_CTRL_KEY=\" /opt/portal/portal.env; then
  echo \"portal.env 已有 MCSM_CTRL_KEY,跳過合併\"
else
  cp /opt/portal/portal.env /opt/portal/portal.env.before-mcsmctrl-$TS
  cat /tmp/portal-env-add >> /opt/portal/portal.env
fi
rm -f /tmp/portal-env-add
chown root:root /opt/portal/portal.env && chmod 600 /opt/portal/portal.env
awk -F= \"/^MCSM_CTRL_KEY=/ {printf \\\"MCSM_CTRL_KEY_len=%d\\n\\\", length(\\\$2)}\" /opt/portal/portal.env
'"

echo "== 3. force-recreate portal(新 env 才進容器) =="
ssh pve24 "sudo pct exec 201 -- bash -c '
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Status}}\" | grep portal
'"

echo "== 4. E2E:控制塊 enabled=true + 白名單/CSRF gate(全走必被擋路徑,不真開停) =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
curl -s -m 8 http://127.0.0.1:8088/api/game | python3 -c \"
import json,sys
c=(json.load(sys.stdin).get(\\\"control\\\") or {})
assert c.get(\\\"enabled\\\") is True, \\\"控制塊仍 enabled=false(key 未進容器?)\\\"
print(\\\"control.enabled ✓\\\")\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -H \"X-Requested-With: XMLHttpRequest\" -H \"Remote-User: e2e\" \
  -d \"{\\\"action\\\":\\\"kill\\\"}\" http://127.0.0.1:8088/api/game/action)
[ \"\$code\" = 403 ] || { echo \"白名單回歸失敗:\$code\"; exit 1; }
echo \"kill(帶齊 header)→ 403 ✓(僅開放 open/stop/restart)\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"open\\\"}\" http://127.0.0.1:8088/api/game/action)
[ \"\$code\" = 403 ] || { echo \"CSRF gate 回歸失敗(無 XRW 應 403):\$code\"; exit 1; }
echo \"無 X-Requested-With → 403 ✓\"
'"

echo "== 完成(TS=$TS)。遊戲頁控制鍵已開通。實測:對停機中的伺服器按〔啟動〕,或運行中按〔重啟〕 =="
echo "回滾:cp /opt/portal/portal.env.before-mcsmctrl-$TS /opt/portal/portal.env + force-recreate portal"
