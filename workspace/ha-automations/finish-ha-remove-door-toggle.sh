#!/bin/bash
# finish-ha-remove-door-toggle.sh — 移除 HA 關門切換自動化 + 清幽靈 registry 條目×2
# 背景(2026-07-10 使用者裁決):米家 App 本地場景(BE3600 Pro 中樞網關)已穩定接手
# 關門切燈;HA 版受 30 秒抽樣限制,且門開>30 秒時會二次切換=干擾源。
# agent 已先 automation.turn_off 止血;本腳本做永久移除:
#   段1 CT270 automations.yaml 移除 door_closed_toggle_lights 塊(自備份,冪等)
#   段2 automation.reload
#   段3 websocket 清幽靈(互鎖版+toggle 版;REST 無 registry 端點,借容器內 aiohttp;
#       token 讀 hass.env 嵌暫存檔 600,不經 argv)
#   段4 驗證:兩 id 皆不在,餘 3 條(到家/平日0550/火警)
# 在哪跑:CT260(codex@codex-ops),先 hl-unlock。
set -euo pipefail

# ── 段1:CT270 移除 yaml 塊 ──
cat > /tmp/.remove-toggle.py <<'PY'
import shutil, time
PATH = "/opt/homeassistant/config/automations.yaml"
src = open(PATH).read()
if "door_closed_toggle_lights" not in src:
    print("yaml 已無 toggle 塊,跳過")
    raise SystemExit(0)
shutil.copy2(PATH, f"{PATH}.before-remove-toggle-{time.strftime('%Y%m%d_%H%M%S')}")
head, _, rest = src.partition("\n- id: door_closed_toggle_lights")
nxt = rest.find("\n- id: ")
src = head + (rest[nxt:] if nxt != -1 else "")
src = src.rstrip() + "\n"
open(PATH, "w").write(src)
n = src.count("\n- id: ") + (1 if src.startswith("- id: ") else 0)
print(f"已移除 door_closed_toggle_lights;現有自動化 {n} 條")
PY
scp -q /tmp/.remove-toggle.py pve24:/tmp/.remove-toggle.py && rm -f /tmp/.remove-toggle.py
ssh pve24 "sudo pct push 270 /tmp/.remove-toggle.py /tmp/.remove-toggle.py && rm -f /tmp/.remove-toggle.py && \
           sudo pct exec 270 -- python3 /tmp/.remove-toggle.py && \
           sudo pct exec 270 -- rm -f /tmp/.remove-toggle.py"

# ── 段2:reload ──
python3 - <<'PYEOF'
import json, os, time, urllib.request
cfg = {}
for line in open(os.path.expanduser("~/.config/homelab/hass.env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); cfg[k] = v.strip()
req = urllib.request.Request(cfg["HASS_URL"] + "/api/services/automation/reload", method="POST",
    data=b"{}", headers={"Authorization": "Bearer " + cfg["HASS_TOKEN"], "Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=60)
time.sleep(3)
print("automation.reload 完成")
PYEOF

# ── 段3:websocket 清幽靈×2(不存在則略過)──
python3 - <<'PYEOF'
import os
cfg = {}
for line in open(os.path.expanduser("~/.config/homelab/hass.env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); cfg[k] = v.strip()
script = '''import asyncio, aiohttp
TOKEN = "%s"
GHOSTS = ["automation.men_chuang_ren_ti_5miao_nei_xian_hou_chu_fa_guan_zhu_deng",
          "automation.guan_men_qie_huan_zhu_deng"]
async def main():
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect("http://localhost:8123/api/websocket") as ws:
            await ws.receive_json()
            await ws.send_json({"type": "auth", "access_token": TOKEN})
            m = await ws.receive_json(); assert m["type"] == "auth_ok", m
            for i, g in enumerate(GHOSTS, start=1):
                await ws.send_json({"id": i, "type": "config/entity_registry/remove", "entity_id": g})
                r = await ws.receive_json()
                ok = r.get("success")
                print(g, "->", "removed" if ok else r.get("error", {}).get("message", "not found(略過)"))
asyncio.run(main())
''' % cfg["HASS_TOKEN"]
p = "/tmp/.ws-remove-ghost.py"
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, script.encode()); os.close(fd)
print("ws script ready")
PYEOF
scp -q /tmp/.ws-remove-ghost.py pve24:/tmp/.ws-remove-ghost.py && rm -f /tmp/.ws-remove-ghost.py
ssh pve24 "sudo pct push 270 /tmp/.ws-remove-ghost.py /opt/homeassistant/config/.tmp_ws_remove.py && rm -f /tmp/.ws-remove-ghost.py && \
           sudo pct exec 270 -- docker exec homeassistant python3 /config/.tmp_ws_remove.py; rc=\$?; \
           sudo pct exec 270 -- rm -f /opt/homeassistant/config/.tmp_ws_remove.py; exit \$rc"

# ── 段4:驗證 ──
python3 - <<'PYEOF'
import json, os, urllib.request
cfg = {}
for line in open(os.path.expanduser("~/.config/homelab/hass.env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); cfg[k] = v.strip()
req = urllib.request.Request(cfg["HASS_URL"] + "/api/states",
    headers={"Authorization": "Bearer " + cfg["HASS_TOKEN"]})
states = json.loads(urllib.request.urlopen(req, timeout=60).read())
autos = [s for s in states if s["entity_id"].startswith("automation.")]
ids = [s["attributes"].get("id") for s in autos]
eids = [s["entity_id"] for s in autos]
assert "door_closed_toggle_lights" not in ids, f"toggle 仍在: {ids}"
assert "door_motion_5s_lights_off" not in ids, f"互鎖仍在: {ids}"
assert "automation.guan_men_qie_huan_zhu_deng" not in eids, "toggle 幽靈仍在"
assert "automation.men_chuang_ren_ti_5miao_nei_xian_hou_chu_fa_guan_zhu_deng" not in eids, "互鎖幽靈仍在"
for want in ["arrive_home_main_lights_derh_ac", "weekday_0550_home_lights", "fire_alarm_notify_tg_ntfy"]:
    assert want in ids, f"{want} 不見了?"
print("驗證 ✓ 餘 3 條:", sorted(i for i in ids if i))
PYEOF
echo "完成。關門切燈自此由米家 App 本地場景負責;HA 留到家/平日0550/火警三條。"
