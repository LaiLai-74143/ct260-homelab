#!/bin/bash
# finish-ha-ghost-clean.sh — 清除舊自動化 door_motion_5s_lights_off 的幽靈 registry 條目
# (yaml 已移除,但 entity registry 殘留 restored=True 的 unavailable 實體,UI 會多一條殭屍)。
# 作法:websocket config/entity_registry/remove,從 HA 容器內打 localhost:8123(容器有 aiohttp)。
# token 讀 hass.env 嵌入暫存檔(600)→ scp → pct push → docker exec → 兩端即刪,不經 argv。
# 在哪跑:CT260(codex@codex-ops),先 hl-unlock。冪等:幽靈不在就跳過。
set -euo pipefail

GHOST="automation.men_chuang_ren_ti_5miao_nei_xian_hou_chu_fa_guan_zhu_deng"

rc=0
python3 - "$GHOST" <<'PYEOF' || rc=$?
import json, os, sys, urllib.request
ghost = sys.argv[1]
cfg = {}
for line in open(os.path.expanduser("~/.config/homelab/hass.env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); cfg[k] = v.strip()
req = urllib.request.Request(cfg["HASS_URL"] + "/api/states/" + ghost,
    headers={"Authorization": "Bearer " + cfg["HASS_TOKEN"]})
try:
    urllib.request.urlopen(req, timeout=30)
except Exception as e:
    if getattr(e, "code", None) == 404:
        print("幽靈已不在,跳過"); raise SystemExit(10)
    raise
script = '''import asyncio, aiohttp
TOKEN = "%s"
GHOST = "%s"
async def main():
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect("http://localhost:8123/api/websocket") as ws:
            await ws.receive_json()
            await ws.send_json({"type": "auth", "access_token": TOKEN})
            m = await ws.receive_json(); assert m["type"] == "auth_ok", m
            await ws.send_json({"id": 1, "type": "config/entity_registry/remove", "entity_id": GHOST})
            r = await ws.receive_json()
            assert r.get("success"), r
            print("registry remove ok:", GHOST)
asyncio.run(main())
''' % (cfg["HASS_TOKEN"], ghost)
p = "/tmp/.ws-remove-ghost.py"
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, script.encode()); os.close(fd)
print("script ready:", p)
PYEOF
[ "$rc" = 10 ] && exit 0
[ "$rc" != 0 ] && exit "$rc"

scp -q /tmp/.ws-remove-ghost.py pve24:/tmp/.ws-remove-ghost.py && rm -f /tmp/.ws-remove-ghost.py
ssh pve24 "sudo pct push 270 /tmp/.ws-remove-ghost.py /opt/homeassistant/config/.tmp_ws_remove.py && rm -f /tmp/.ws-remove-ghost.py && \
           sudo pct exec 270 -- docker exec homeassistant python3 /config/.tmp_ws_remove.py; rc=\$?; \
           sudo pct exec 270 -- rm -f /opt/homeassistant/config/.tmp_ws_remove.py; exit \$rc"

# 驗證:幽靈應 404
python3 - "$GHOST" <<'PYEOF'
import os, sys, urllib.request
ghost = sys.argv[1]
cfg = {}
for line in open(os.path.expanduser("~/.config/homelab/hass.env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); cfg[k] = v.strip()
req = urllib.request.Request(cfg["HASS_URL"] + "/api/states/" + ghost,
    headers={"Authorization": "Bearer " + cfg["HASS_TOKEN"]})
try:
    urllib.request.urlopen(req, timeout=30)
    raise SystemExit("幽靈仍在?")
except Exception as e:
    if getattr(e, "code", None) == 404:
        print("驗證 ✓ 幽靈實體已清除")
    else:
        raise
PYEOF
echo "完成。"
