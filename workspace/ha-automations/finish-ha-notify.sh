#!/bin/bash
# finish-ha-notify.sh — HA 家用通知鏈部署(2026-07-09)
# 內容:①CT260 ntfy-webhook 第三把 token(WEBHOOK_TOKEN_HA)+三白名單動作(火警雙推/
#   到家 ntfy+撤銷鈕/撤銷執行);②CT270 HA rest_command+automations(火警自動化+到家
#   自動化尾掛通知);③xiaomi_miot 整合 reload(吃新設備);④人體感應器進來則自動落
#   「門窗+人體5秒互鎖關燈」自動化;⑤E2E(發測試通知到手機)。
# 在哪跑:CT260(codex@codex-ops),身份 codex,先 hl-unlock(要 ssh pve24)。
#   前置:~/.config/homelab/hass.env 的 HASS_TOKEN 已填(HA UI 長期存取權杖,見該檔說明)。
# 冪等:重跑無害(各段有既存檢查)。
# 回滾:CT260 ~/.local/bin/ntfy-webhook.py.before-ha-<TS> 蓋回+pkill 重拉;
#   CT270 /opt/homeassistant/config/{configuration,automations,secrets}.yaml.before-ha-<TS>
#   蓋回 + HA UI 開發者工具→YAML→重新載入自動化(或 docker restart homeassistant)。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
ENVDIR=~/.config/homelab
HASS_ENV=$ENVDIR/hass.env
WH_ENV=$ENVDIR/ntfy-webhook.env
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

need() { [ -f "$1" ] || { echo "缺檔案:$1"; exit 1; }; }
need "$SELF_DIR/automations-v2.yaml"; need "$SELF_DIR/rest-command.yaml"
need "$SELF_DIR/automation-door-motion.tpl.yaml"; need "$SELF_DIR/ct270-helper.py"
need "$SELF_DIR/patch-webhook.py"; need ~/.local/bin/ha-notify.py; need "$HASS_ENV"

# HA API 呼叫器:token 讀檔組請求,不經 argv/ps(交付規矩)
ha_api() { # ha_api <GET|POST> <path> [body-json]
  python3 - "$1" "$2" "${3:-}" <<'PYEOF'
import json, sys, urllib.request
cfg = {}
for line in open(f"{__import__('os').path.expanduser('~')}/.config/homelab/hass.env"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); cfg[k] = v.strip()
method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(cfg["HASS_URL"] + path, method=method,
                             data=body.encode() if body else None,
                             headers={"Authorization": "Bearer " + cfg["HASS_TOKEN"],
                                      "Content-Type": "application/json"})
try:
    r = urllib.request.urlopen(req, timeout=30)
    # 成功分支不截斷:/api/states、/api/services 整包遠超 4000 字元,下游要完整 JSON(審查高危)
    print(r.status); sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    print(e.code); sys.stdout.write(e.read().decode()[:400]); sys.exit(0)
PYEOF
}

echo "== 0. 前置:hass.env token 已填 + HA API 可達 =="
grep -q "^HASS_TOKEN=<" "$HASS_ENV" && { echo "hass.env 的 HASS_TOKEN 還是占位符,先照該檔說明取得權杖填入"; exit 1; }
out=$(ha_api GET /api/); echo "$out" | head -1 | grep -q "^200$" || { echo "HA API 驗證失敗:$out"; exit 1; }
echo "HA API token ✓"

echo "== 1. CT260:WEBHOOK_TOKEN_HA + webhook 補丁 + 重拉 =="
if ! grep -q "^WEBHOOK_TOKEN_HA=" "$WH_ENV"; then
  TOK=$(openssl rand -hex 32)
  [ ${#TOK} -eq 64 ] || { echo "openssl 生成 token 失敗"; exit 1; }
  cp -a "$WH_ENV" "$WH_ENV.before-ha-$TS"
  { echo ""; echo "# HA 家用通知鏈(2026-07-09):CT270 HA rest_command 專用,與 ntfy/portal 分開輪替"; \
    echo "WEBHOOK_TOKEN_HA=$TOK"; } >> "$WH_ENV"
  chmod 600 "$WH_ENV"
  echo "WEBHOOK_TOKEN_HA 已生成落 $WH_ENV"
else
  echo "WEBHOOK_TOKEN_HA 已存在,沿用"
fi
# 備份只在「尚未打補丁」時做,重跑不會把已補丁檔蓋成最新備份
grep -q "WEBHOOK_TOKEN_HA" ~/.local/bin/ntfy-webhook.py \
  || cp -a ~/.local/bin/ntfy-webhook.py ~/.local/bin/ntfy-webhook.py.before-ha-$TS
python3 "$SELF_DIR/patch-webhook.py"
pkill -f "ntfy-webhook.py" 2>/dev/null || true
sleep 1
setsid ~/.local/bin/ntfy-webhook-run.sh >/dev/null 2>&1 < /dev/null &
sleep 2
curl -s -m 4 http://127.0.0.1:5001/health | grep -q '"ok": *true' || { echo "webhook 重拉後 health 失敗"; exit 1; }
echo "webhook 重拉 ✓"

echo "== 1v. 驗證矩陣(不執行動作、不耗限速) =="
python3 - <<'PYEOF'
import json, os, urllib.request
cfg = {}
for line in open(os.path.expanduser("~/.config/homelab/ntfy-webhook.env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); cfg[k] = v.strip()
def hit(tok, body):
    req = urllib.request.Request("http://127.0.0.1:5001/run", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + tok,
                                          "Content-Type": "application/json"})
    try:
        return urllib.request.urlopen(req, timeout=10).status
    except urllib.error.HTTPError as e:
        return e.code
ha = cfg["WEBHOOK_TOKEN_HA"]
assert hit(ha, {"action": "__selftest__"}) == 403, "HA token+假動作應 403(token 沒生效?)"
print("HA token 生效(假動作 403)✓")
assert hit(ha, {"action": "notify-fire", "param": "bad room!"}) == 400, "壞 param 應 400"
print("notify-fire 白名單+param 驗證 ✓")
assert hit("wrong-token-000", {"action": "__selftest__"}) == 401, "錯 token 應 401"
print("錯 token 401 ✓")
PYEOF

echo "== 2. CT270:secrets + rest_command + automations =="
scp -q "$SELF_DIR/ct270-helper.py" pve24:/tmp/ct270-helper.py
ssh pve24 "sudo pct push 270 /tmp/ct270-helper.py /tmp/ct270-helper.py && rm -f /tmp/ct270-helper.py"

CONF=/opt/homeassistant/config
# 2a. secrets.yaml(token 經暫存檔,不進 argv)
if ! ssh pve24 "sudo pct exec 270 -- grep -q ct260_webhook_auth $CONF/secrets.yaml" 2>/dev/null; then
  python3 - <<PYEOF
import os
cfg = {}
for line in open(os.path.expanduser("~/.config/homelab/ntfy-webhook.env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); cfg[k] = v.strip()
open("$TMP/sec-add.yaml", "w").write(
    '\n# HA 家用通知鏈(2026-07-09):CT260 ntfy-webhook 第三把 token\n'
    f'ct260_webhook_auth: "Bearer {cfg["WEBHOOK_TOKEN_HA"]}"\n')
PYEOF
  scp -q "$TMP/sec-add.yaml" pve24:/tmp/sec-add.yaml
  ssh pve24 "sudo pct push 270 /tmp/sec-add.yaml /tmp/sec-add.yaml && rm -f /tmp/sec-add.yaml"
  ssh pve24 "sudo pct exec 270 -- sh -c 'touch $CONF/secrets.yaml && cp -a $CONF/secrets.yaml $CONF/secrets.yaml.before-ha-$TS && cat /tmp/sec-add.yaml >> $CONF/secrets.yaml && chmod 600 $CONF/secrets.yaml && rm -f /tmp/sec-add.yaml'"
  echo "secrets.yaml 已落 ct260_webhook_auth"
else
  echo "secrets.yaml 已有 ct260_webhook_auth,沿用"
fi

# 2b. configuration.yaml 追加 rest_command(冪等;斷言原檔無 rest_command 域防重複)
if ! ssh pve24 "sudo pct exec 270 -- grep -q ct260_notify_fire $CONF/configuration.yaml"; then
  ssh pve24 "sudo pct exec 270 -- grep -q '^rest_command:' $CONF/configuration.yaml" \
    && { echo "configuration.yaml 已有 rest_command 域但無 ct260_notify_fire——人工合併"; exit 1; }
  scp -q "$SELF_DIR/rest-command.yaml" pve24:/tmp/rest-command.yaml
  ssh pve24 "sudo pct push 270 /tmp/rest-command.yaml /tmp/rest-command.yaml && rm -f /tmp/rest-command.yaml"
  ssh pve24 "sudo pct exec 270 -- sh -c 'cp -a $CONF/configuration.yaml $CONF/configuration.yaml.before-ha-$TS && cat /tmp/rest-command.yaml >> $CONF/configuration.yaml && rm -f /tmp/rest-command.yaml'"
  echo "configuration.yaml 已加 rest_command"
else
  echo "configuration.yaml 已有 ct260_notify_fire,沿用"
fi

# 2c. automations.yaml 替換 v2(斷言=只有已知兩條,防蓋掉使用者新建的)
if ! ssh pve24 "sudo pct exec 270 -- grep -q fire_alarm_notify_tg_ntfy $CONF/automations.yaml"; then
  ssh pve24 "sudo pct exec 270 -- sh -c 'grep -q arrive_home_main_lights_derh_ac $CONF/automations.yaml && grep -q weekday_0550_home_lights $CONF/automations.yaml'" \
    || { echo "automations.yaml 缺既有兩條 id(檔已漂移)——人工核對"; exit 1; }
  nids=$(ssh pve24 "sudo pct exec 270 -- grep -c '^- id:' $CONF/automations.yaml")
  [ "$nids" = "2" ] || { echo "automations.yaml 有 $nids 條自動化(預期 2)——使用者新建過?人工合併"; exit 1; }
  scp -q "$SELF_DIR/automations-v2.yaml" pve24:/tmp/automations-v2.yaml
  ssh pve24 "sudo pct push 270 /tmp/automations-v2.yaml /tmp/automations-v2.yaml && rm -f /tmp/automations-v2.yaml"
  ssh pve24 "sudo pct exec 270 -- sh -c 'cp -a $CONF/automations.yaml $CONF/automations.yaml.before-ha-$TS && mv /tmp/automations-v2.yaml $CONF/automations.yaml'"
  echo "automations.yaml 已換 v2(到家+通知 / 平日0550 / 火警雙推)"
else
  echo "automations.yaml 已含火警自動化,沿用"
fi

echo "== 3. HA 設定檢查 + 載入 =="
out=$(ha_api POST /api/config/core/check_config)
echo "$out" | grep -q '"result": *"valid"' || { echo "HA check_config 不過:$out(備份檔在 $CONF/*.before-ha-$TS)"; exit 1; }
echo "check_config valid ✓"
if ha_api GET /api/services | grep -q '"rest_command"'; then
  ha_api POST /api/services/automation/reload '{}' >/dev/null
  echo "automation.reload ✓(rest_command 域已在)"
else
  echo "rest_command 域首次載入需重啟 HA(約 1-2 分鐘;米家 WiFi 設備啟動當下離線會暫 unavailable)"
  ssh pve24 "sudo pct exec 270 -- docker restart homeassistant" >/dev/null
  for i in $(seq 1 36); do
    sleep 5
    if ha_api GET /api/ 2>/dev/null | head -1 | grep -q "^200$"; then echo "HA 起來了(${i}x5s)"; break; fi
    [ "$i" = 36 ] || continue
    echo "HA 重啟 180s 未回 200,人工查 docker logs homeassistant"; exit 1
  done
fi
# 重啟後 /api/ 回 200 ≠ automation 元件載完(慢盤 HA 實測 20s 時 states 還是空)——輪詢等
echo "等待 automation 實體載入(最多 120s)…"
for i in $(seq 1 24); do
  if ha_api GET /api/states | python3 -c "
import json, sys
data = sys.stdin.read(); data = data[data.index('['):]
ids = [s['attributes'].get('id') for s in json.loads(data) if s['entity_id'].startswith('automation.')]
sys.exit(0 if 'fire_alarm_notify_tg_ntfy' in ids else 1)"; then
    echo "火警自動化已載入 ✓(第 $i 次輪詢)"; break
  fi
  [ "$i" = 24 ] && { echo "120s 後火警自動化仍未載入——人工查:pct exec 270 docker logs --tail 50 homeassistant"; exit 1; }
  sleep 5
done

echo "== 4. xiaomi_miot reload(吃新設備)+ 人體感應器偵測 =="
EID=$(ssh pve24 "sudo pct exec 270 -- python3 /tmp/ct270-helper.py entry-id")
[ -n "$EID" ] || { echo "找不到 xiaomi_miot entry"; exit 1; }
ha_api POST "/api/config/config_entries/entry/$EID/reload" '{}' | head -1
echo "整合 reload 送出,等 25s 雲端匯入…"
sleep 25
ssh pve24 "sudo pct exec 270 -- python3 /tmp/ct270-helper.py check-devices"
MOTION=$(ssh pve24 "sudo pct exec 270 -- python3 /tmp/ct270-helper.py list-motion" | grep -v '^$' || true)
if [ -z "$MOTION" ]; then
  echo "★ 人體感應器仍未進 HA——米家 app 確認設備已配對在同一家庭且在線;之後重跑本腳本即可(其餘段冪等跳過)"
elif [ "$(echo "$MOTION" | wc -l)" != "1" ]; then
  echo "★ 偵測到多顆 motion 實體,不自動選,人工指定後手動落自動化A:"; echo "$MOTION"
else
  echo "人體感應器:$MOTION"
  if ssh pve24 "sudo pct exec 270 -- grep -q door_motion_5s_lights_off $CONF/automations.yaml"; then
    echo "自動化A已在,跳過"
  else
    sed "s/__MOTION_ENTITY__/$MOTION/g" "$SELF_DIR/automation-door-motion.tpl.yaml" > "$TMP/autoA.yaml"
    scp -q "$TMP/autoA.yaml" pve24:/tmp/autoA.yaml
    ssh pve24 "sudo pct push 270 /tmp/autoA.yaml /tmp/autoA.yaml && rm -f /tmp/autoA.yaml"
    ssh pve24 "sudo pct exec 270 -- sh -c 'cat /tmp/autoA.yaml >> $CONF/automations.yaml && rm -f /tmp/autoA.yaml'"
    ha_api POST /api/services/automation/reload '{}' >/dev/null
    echo "自動化A(門窗+人體5秒互鎖關燈)已落+reload ✓"
  fi
fi

echo "== 5. E2E:經 webhook 發測試通知(手機應收到) =="
python3 - <<'PYEOF'
import json, os, urllib.request
cfg = {}
for line in open(os.path.expanduser("~/.config/homelab/ntfy-webhook.env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); cfg[k] = v.strip()
def hit(body):
    req = urllib.request.Request("http://127.0.0.1:5001/run", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + cfg["WEBHOOK_TOKEN_HA"],
                                          "Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=60)
    return r.status, json.loads(r.read())
st, out = hit({"action": "notify-fire", "param": "test"})
assert st == 200 and out["ok"], f"notify-fire test 失敗: {st} {out}"
print("notify-fire(test)→ 手機應收【測試】TG+ntfy 各一 ✓")
st, out = hit({"action": "notify-arrival"})
assert st == 200 and out["ok"], f"notify-arrival 失敗: {st} {out}"
print("notify-arrival → 手機應收🏠到家通知(附撤銷鈕,可實按驗證=會關主燈/除濕機/冷氣)✓")
PYEOF

echo ""
echo "== 完成(TS=$TS)。驗收清單 =="
echo "1. 手機:剛剛應收到【測試】火警 TG+ntfy、🏠到家通知(共 3 則)"
echo "2. 到家通知按〔撤銷(全關)〕→ 主燈×3/除濕機/冷氣被關(TG 會回報執行結果)"
echo "3. 人體感應器若上面顯示已進 HA:開門+5 秒內走動 → 主燈關(不靈就調自動化裡的 5 秒窗)"
echo "4. 真火警測法(可選):煙感按測試鈕 → TG+ntfy 高優先雙推"
