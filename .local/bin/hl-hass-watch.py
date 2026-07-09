#!/usr/bin/env python3
"""
hl-hass-watch: HA 米家整合健康看門狗(待辦5,2026-07-09)— CT260 cron 每 10 分。

背景:xiaomi_miot 的小米雲 service_token 會過期(偶發,數週~數月),過期後全米家
實體 unavailable——火警偵測啞火且無人知曉(2026-07-09 實際發生)。本腳本獨立於 HA
(CT260 側輪詢 HA API),HA 本體掛掉同樣告警。

判定:哨兵實體(煙感×2/門窗/除濕機/主燈/冷氣)unavailable ≥ THRESHOLD,或 HA API
不可達 → 疑似整合級故障(單一設備離線不吵)。連續 2 次檢查(≈20 分)才告警(去抖);
狀態轉變發 ntfy+TG,持續故障每 6h 重發,恢復發一則解除。

狀態檔:~/.local/state/homelab-notify/hass-watch.json
設定:~/.config/homelab/{hass,ntfy,notify-telegram}.env(600)
cron:*/10 * * * * flock -n ~/.local/state/homelab-notify/.hasswatch.lock python3 ~/.local/bin/hl-hass-watch.py
"""
import json
import os
import time
import urllib.request
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
STATE_FILE = HOME / ".local/state/homelab-notify/hass-watch.json"
CONFIG_FILES = [
    HOME / ".config/homelab/hass.env",
    HOME / ".config/homelab/ntfy.env",
    HOME / ".config/homelab/notify-telegram.env",
]

# 哨兵實體:煙感為核心(火警偵測有效性),其餘攤開設備類型避免單點誤判
SENTINELS = [
    "binary_sensor.lumi_mcn02_600a_smoke_status",
    "binary_sensor.lumi_mcn02_61d2_smoke_status",
    "binary_sensor.isa_dw2hl_4226_magnet_sensor",
    "humidifier.xiaomi_13l_59e5_dehumidifier",
    "light.yeelink_colorb_7cbf_light",
    "climate.miir_ir02_7842_ir_aircondition_control",
]
THRESHOLD = 4          # ≥4/6 unavailable 判整合級故障
CONFIRM_RUNS = 2       # 連續 N 次才告警(cron */10 → 約 20 分)
REALERT_SEC = 6 * 3600 # 持續故障重發間隔


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


def notify(title, message, priority=4):
    sent = False
    tok, chat = CFG.get("TELEGRAM_BOT_TOKEN"), CFG.get("TELEGRAM_CHAT_ID")
    if tok and chat:
        try:
            _post_json(f"https://api.telegram.org/bot{tok}/sendMessage",
                       {"chat_id": chat, "text": f"{title}\n{message}",
                        "disable_web_page_preview": True}, {})
            sent = True
        except Exception:  # noqa: BLE001
            pass
    url, ntok = CFG.get("NTFY_URL"), CFG.get("NTFY_PUB_TOKEN")
    if url and ntok:
        try:
            _post_json(url, {"topic": CFG.get("NTFY_TOPIC", "homelab"),
                             "title": title, "message": message,
                             "priority": priority, "tags": ["warning", "house"]},
                       {"Authorization": f"Bearer {ntok}"})
            sent = True
        except Exception:  # noqa: BLE001
            pass
    return sent


def check():
    """回傳 (bad: bool, detail: str)。"""
    base, tok = CFG.get("HASS_URL"), CFG.get("HASS_TOKEN")
    if not base or not tok or tok.startswith("<"):
        return False, "hass.env 未配置(不判)"
    unavail = []
    for eid in SENTINELS:
        try:
            req = urllib.request.Request(f"{base}/api/states/{eid}",
                                         headers={"Authorization": f"Bearer {tok}"})
            st = json.loads(urllib.request.urlopen(req, timeout=10).read()).get("state")
        except Exception as e:  # noqa: BLE001  API 掛/404 都算壞
            st = f"api-err:{type(e).__name__}"
        if st in ("unavailable",) or str(st).startswith("api-err"):
            unavail.append(f"{eid.split('.')[-1]}={st}")
    bad = len(unavail) >= THRESHOLD
    return bad, f"{len(unavail)}/{len(SENTINELS)} 離線" + (":" + "; ".join(unavail[:4]) if unavail else "")


def main():
    bad, detail = check()
    now = int(time.time())
    st = {"streak": 0, "alerting": False, "last_alert": 0}
    if STATE_FILE.exists():
        try:
            st.update(json.loads(STATE_FILE.read_text()))
        except Exception:  # noqa: BLE001
            pass

    if bad:
        st["streak"] += 1
        should = (not st["alerting"] and st["streak"] >= CONFIRM_RUNS) or \
                 (st["alerting"] and now - st["last_alert"] >= REALERT_SEC)
        if should:
            notify("⚠️ HA 米家整合疑似離線",
                   f"{detail}。火警偵測可能啞火!最常見原因=小米雲 token 過期:"
                   f"HA(192.168.20.70:8123)→設定→整合→Xiaomi Miot Auto→「重新設定」"
                   f"重輸帳密(勿刪除重加,會產生 _2 實體);報 Too many failures 就等"
                   f" 30-60 分再試。")
            st["alerting"] = True
            st["last_alert"] = now
    else:
        if st["alerting"]:
            notify("✅ HA 米家整合恢復", detail, priority=3)
        st = {"streak": 0, "alerting": False, "last_alert": 0}

    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(st))
    print(("BAD " if bad else "OK ") + detail)


if __name__ == "__main__":
    main()
