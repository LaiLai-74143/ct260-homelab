#!/usr/bin/env python3
"""
ha-notify: HA 家用自動化通知鏈(2026-07-09)— CT260 側動作腳本。

由 ntfy-webhook.py 白名單動作呼叫(CT270 HA rest_command → :5001 → 本腳本);
也可手動測試。子命令:
  fire <room>    火災警報:TG+ntfy(priority=max)雙推。room∈dad|ken|test
                 (test=鏈路測試文案,priority 降為 3,不嚇人)
  arrival        到家通知:ntfy+「撤銷(全關)」按鈕(按鈕→webhook ha-undo-arrival)
  undo-arrival   撤銷到家:HA API 關主燈×3+除濕機+冷氣

設定(均 600):~/.config/homelab/{ntfy,notify-telegram,ntfy-webhook,hass}.env
退出碼:fire/arrival=至少一路送達為 0;undo-arrival=全部服務呼叫成功為 0。
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
CONFIG_FILES = [
    HOME / ".config/homelab/ntfy.env",
    HOME / ".config/homelab/notify-telegram.env",
    HOME / ".config/homelab/ntfy-webhook.env",
    HOME / ".config/homelab/hass.env",
]

ROOMS = {"dad": "爸爸房間", "ken": "胤樺房間", "test": "測試"}

# 撤銷範圍=到家自動化(automations.yaml arrive_home_main_lights_derh_ac)開的東西,
# 改那邊的 entity 必同步這裡。
UNDO_CALLS = [
    ("light", "turn_off", {"entity_id": [
        "light.yeelink_colorb_7cbf_light",
        "light.yeelink_colorb_9feb_light",
        "light.yeelink_colorb_f923_light"]}),
    ("humidifier", "turn_off", {"entity_id": "humidifier.xiaomi_13l_59e5_dehumidifier"}),
    ("climate", "turn_off", {"entity_id": "climate.miir_ir02_7842_ir_aircondition_control"}),
]


def load_config():
    cfg = {}
    for cf in CONFIG_FILES:
        if not cf.exists():
            continue
        for raw in cf.read_text().splitlines():
            raw = raw.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                continue
            k, v = raw.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


CFG = load_config()


def _post_json(url, payload, headers, timeout=15):
    req = urllib.request.Request(
        url, data=json.dumps(payload, ensure_ascii=False).encode(),
        headers={"Content-Type": "application/json", **headers})
    urllib.request.urlopen(req, timeout=timeout).read()


def tg_send(text):
    token, chat = CFG.get("TELEGRAM_BOT_TOKEN"), CFG.get("TELEGRAM_CHAT_ID")
    if not token or not chat:
        print("tg: not configured")
        return False
    try:
        _post_json(f"https://api.telegram.org/bot{token}/sendMessage",
                   {"chat_id": chat, "text": text, "disable_web_page_preview": True}, {})
        print("tg: sent")
        return True
    except Exception as e:  # noqa: BLE001
        print(f"tg: FAILED {type(e).__name__}: {str(e)[:120]}")
        return False


def ntfy_send(title, message, priority=3, actions=None, tags=None):
    url, token = CFG.get("NTFY_URL"), CFG.get("NTFY_PUB_TOKEN")
    if not url or not token:
        print("ntfy: not configured")
        return False
    payload = {"topic": CFG.get("NTFY_TOPIC", "homelab"),
               "title": title, "message": message, "priority": priority}
    if tags:
        payload["tags"] = tags
    if actions:
        payload["actions"] = actions
    try:
        _post_json(url, payload, {"Authorization": f"Bearer {token}"}, timeout=10)
        print("ntfy: sent")
        return True
    except Exception as e:  # noqa: BLE001
        print(f"ntfy: FAILED {type(e).__name__}: {str(e)[:120]}")
        return False


def cmd_fire(room_code):
    room = ROOMS.get(room_code, room_code)
    is_test = room_code == "test"
    if is_test:
        title = "【測試】火警通知鏈路"
        msg = "這是 HA→CT260 火警通知鏈路測試,非真實警報。"
    else:
        title = f"🔥 火災警報:{room}"
        msg = f"{room}煙霧偵測器觸發!請立即確認現場。"
    ok_tg = tg_send(("🧪 " if is_test else "🔥🔥🔥 ") + title + "\n" + msg)
    ok_ntfy = ntfy_send(title, msg,
                        priority=3 if is_test else 5,
                        tags=["test_tube"] if is_test else ["rotating_light", "fire"])
    return 0 if (ok_tg or ok_ntfy) else 1


def cmd_arrival():
    # 按鈕打的是內網 :5001(審查確認限制):真到家=連上家中 WiFi 後可按;
    # 誤觸發(人不在家=行動網路)須先開 WireGuard(待辦24 手機 peer)才按得動,文案明示。
    # 長期選項=portal 轉發+一次性簽名(見 ForAI 註記),本輪不做。
    undo_btn = [{
        "action": "http", "label": "撤銷(全關)",
        "url": CFG.get("WEBHOOK_URL", "http://192.168.20.60:5001/run"),
        "method": "POST",
        "headers": {"Authorization": "Bearer " + CFG.get("WEBHOOK_TOKEN", ""),
                    "Content-Type": "application/json"},
        "body": json.dumps({"action": "ha-undo-arrival"}),
        "clear": True,
    }]
    ok = ntfy_send("🏠 到家自動化已執行",
                   "已開:胤樺房間主燈×3+除濕機(房間>30°C 會加開冷氣)。"
                   "誤觸發可按下方撤銷——按鈕走家內網:在家連 WiFi 直接按;"
                   "人不在家時先開 WireGuard 再按。",
                   priority=3, actions=undo_btn, tags=["house"])
    return 0 if ok else 1


def cmd_undo():
    url, token = CFG.get("HASS_URL"), CFG.get("HASS_TOKEN")
    if not url or not token or token.startswith("<"):
        print("undo: hass.env 未配置(HASS_URL/HASS_TOKEN)")
        return 1
    fails = []
    for domain, service, data in UNDO_CALLS:
        try:
            _post_json(f"{url}/api/services/{domain}/{service}", data,
                       {"Authorization": f"Bearer {token}"})
            print(f"undo: {domain}.{service} ok")
        except Exception as e:  # noqa: BLE001
            print(f"undo: {domain}.{service} FAILED {type(e).__name__}: {str(e)[:120]}")
            fails.append(f"{domain}.{service}")
    return 1 if fails else 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == "fire":
        if len(sys.argv) != 3:
            print("usage: ha-notify.py fire <dad|ken|test>")
            return 2
        return cmd_fire(sys.argv[2])
    if cmd == "arrival":
        return cmd_arrival()
    if cmd == "undo-arrival":
        return cmd_undo()
    print(f"unknown subcommand: {cmd}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
