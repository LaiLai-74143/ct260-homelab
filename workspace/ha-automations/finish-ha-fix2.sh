#!/bin/bash
# finish-ha-fix2.sh — 修 xiaomi_miot 刪除重加後的 _2 實體後綴 + 落自動化A(2026-07-09)
# 背景:米雲登入失效後使用者刪除重加整合,舊實體條目佔名 → 全部新實體被加 _2,
#   既有自動化(到家/0550/火警)與撤銷鏈引用的原 ID 全數失效。
# 做什麼:①停 HA→清孤兒 registry 條目+_2 改回原名(fix-entity-registry.py,自備份)→啟 HA;
#   ②輪詢載入+驗證關鍵實體回原名;③落自動化A(門窗+人體5秒互鎖,motion 已進 HA);④E2E 提示。
# 在哪跑:CT260(codex@codex-ops),先 hl-unlock。冪等:重跑無害。
# 回滾:cp /root/_backups/core.entity_registry.before-fix2-<TS> 回 .storage + docker restart homeassistant
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
CONF=/opt/homeassistant/config
MOTION=binary_sensor.xiaomi_pir1_709a_motion_sensor

ha_api() {
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
    print(r.status); sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    print(e.code); sys.stdout.write(e.read().decode()[:400]); sys.exit(0)
except Exception as e:
    print("000", type(e).__name__); sys.exit(0)
PYEOF
}

echo "== 1. registry 手術(停 HA→清孤兒+_2 改名→啟 HA) =="
if ssh pve24 "sudo pct exec 270 -- python3 -c \"
import json
er = json.load(open('$CONF/.storage/core.entity_registry'))['data']['entities']
import sys; sys.exit(0 if any(e.get('platform')=='xiaomi_miot' and e['entity_id'].endswith('_2') for e in er) else 1)\""; then
  scp -q "$SELF_DIR/fix-entity-registry.py" pve24:/tmp/fix-er.py
  ssh pve24 "sudo pct push 270 /tmp/fix-er.py /tmp/fix-er.py && rm -f /tmp/fix-er.py"
  ssh pve24 "sudo pct exec 270 -- bash -c '
set -e
mkdir -p /root/_backups
docker stop homeassistant >/dev/null && echo HA-stopped
python3 /tmp/fix-er.py
docker start homeassistant >/dev/null && echo HA-started
'"
else
  echo "registry 已無 _2 後綴,跳過手術(不停 HA)"
fi

echo "== 2. 等 HA 起來+automation 載入(最多 180s) =="
for i in $(seq 1 36); do
  sleep 5
  ha_api GET /api/ | head -1 | grep -q "^200$" && { echo "HA API 回來(${i}x5s)"; break; }
  [ "$i" = 36 ] && { echo "HA 180s 未回,人工查 docker logs homeassistant"; exit 1; }
done
for i in $(seq 1 24); do
  if ha_api GET /api/states | python3 -c "
import json, sys
data = sys.stdin.read(); data = data[data.index('['):]
ids = [s['attributes'].get('id') for s in json.loads(data) if s['entity_id'].startswith('automation.')]
sys.exit(0 if 'fire_alarm_notify_tg_ntfy' in ids else 1)"; then
    echo "自動化已載入 ✓"; break
  fi
  [ "$i" = 24 ] && { echo "automation 120s 未載入"; exit 1; }
  sleep 5
done

echo "== 3. 驗證關鍵實體回原名(先等 xiaomi_miot 平台就緒,最多 120s) =="
# automation 載入 ≠ xiaomi_miot 雲端 setup 完成(30-60s),查太早會 404 誤報(2026-07-09 實踩)
for i in $(seq 1 24); do
  ha_api GET /api/states/humidifier.xiaomi_13l_59e5_dehumidifier | head -1 | grep -q "^200$" \
    && { echo "xiaomi_miot 平台就緒(${i}x5s)"; break; }
  [ "$i" = 24 ] && { echo "120s 後 xiaomi_miot 實體仍 404——查 docker logs homeassistant 的 xiaomi_miot 錯誤"; exit 1; }
  sleep 5
done
for eid in humidifier.xiaomi_13l_59e5_dehumidifier light.yeelink_colorb_7cbf_light \
           light.yeelink_colorb_9feb_light light.yeelink_colorb_f923_light \
           climate.miir_ir02_7842_ir_aircondition_control \
           binary_sensor.lumi_mcn02_600a_smoke_status binary_sensor.lumi_mcn02_61d2_smoke_status \
           binary_sensor.isa_dw2hl_4226_magnet_sensor $MOTION; do
  st=$(ha_api GET /api/states/$eid | python3 -c "
import sys
lines = sys.stdin.read().split(chr(10), 1)
if lines[0] != '200': print('HTTP-' + lines[0]); raise SystemExit
import json; print(json.loads(lines[1])['state'])")
  printf "%-58s %s\n" "$eid" "$st"
  case "$st" in HTTP-*) echo "★ 實體缺失:$eid"; exit 1;; esac
done
echo "(unavailable 屬正常波動=設備離線;HTTP-404 才是名字問題)"

echo "== 4. 落自動化A(門窗+人體5秒互鎖關主燈) =="
if ssh pve24 "sudo pct exec 270 -- grep -q door_motion_5s_lights_off $CONF/automations.yaml"; then
  echo "自動化A已在,跳過"
else
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  sed "s/__MOTION_ENTITY__/$MOTION/g" "$SELF_DIR/automation-door-motion.tpl.yaml" > "$TMP/autoA.yaml"
  scp -q "$TMP/autoA.yaml" pve24:/tmp/autoA.yaml
  ssh pve24 "sudo pct push 270 /tmp/autoA.yaml /tmp/autoA.yaml && rm -f /tmp/autoA.yaml"
  ssh pve24 "sudo pct exec 270 -- sh -c 'cat /tmp/autoA.yaml >> $CONF/automations.yaml && rm -f /tmp/autoA.yaml'"
  ha_api POST /api/services/automation/reload '{}' >/dev/null
  echo "自動化A已落+reload ✓"
fi

echo "== 5. 安裝 HA 米家看門狗 cron(每 10 分;token 過期/整合離線→ntfy+TG 告警) =="
if crontab -l 2>/dev/null | grep -q hl-hass-watch; then
  echo "cron 已在,跳過"
else
  ( crontab -l 2>/dev/null; \
    echo "# hl-hass-watch: HA 米家整合健康看門狗(待辦5, added 2026-07-09)"; \
    echo "*/10 * * * * /usr/bin/flock -n /home/codex/.local/state/homelab-notify/.hasswatch.lock /usr/bin/python3 /home/codex/.local/bin/hl-hass-watch.py >/dev/null 2>&1" ) | crontab -
  echo "cron 已裝(*/10)"
fi
python3 ~/.local/bin/hl-hass-watch.py

echo ""
echo "== 完成。驗收 =="
echo "1. 撤銷鏈實測:手機按上次到家通知的〔撤銷(全關)〕,或跑:"
echo "   ~/.local/bin/ha-notify.py undo-arrival   (會真關主燈/除濕機/冷氣)"
echo "2. 互鎖實測:開胤樺房間門+5 秒內在門口走動 → 主燈應關(雲端輪詢有延遲,多試幾次)"
echo "3. HA UI 確認自動化三+1 條都在、米家實體無 _2 後綴"
