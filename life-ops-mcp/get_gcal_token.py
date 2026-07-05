#!/usr/bin/env python3
"""One-time Google Calendar OAuth (installed-app, manual copy) -> refresh token.

Prereq: ~/.config/homelab/gcal.env with GCAL_CLIENT_ID / GCAL_CLIENT_SECRET
(from a "Desktop app" OAuth client). Run interactively:  python3 get_gcal_token.py
Writes GCAL_REFRESH_TOKEN back into the same env file.
"""
import os, json, urllib.parse, urllib.request

ENV = os.path.expanduser("~/.config/homelab/gcal.env")
REDIRECT = "http://127.0.0.1:9099"          # loopback; we copy the code by hand
SCOPE = "https://www.googleapis.com/auth/calendar"

def load():
    d = {}
    for line in open(ENV):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1); d[k] = v.strip().strip('"').strip("'")
    return d

def save(d):
    with open(ENV, "w") as f:
        for k, v in d.items():
            f.write(f"{k}={v}\n")
    os.chmod(ENV, 0o600)

def main():
    cfg = load()
    cid, sec = cfg.get("GCAL_CLIENT_ID"), cfg.get("GCAL_CLIENT_SECRET")
    if not cid or not sec:
        print("缺 GCAL_CLIENT_ID / GCAL_CLIENT_SECRET，先填 " + ENV); return
    auth = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
        "client_id": cid, "redirect_uri": REDIRECT, "response_type": "code",
        "scope": SCOPE, "access_type": "offline", "prompt": "consent"})
    print("\n1) 用任何瀏覽器打開下面網址，登入 lailai74143@gmail.com 並同意：\n")
    print(auth)
    print("\n2) 同意後瀏覽器會跳到 127.0.0.1:9099/?code=...（頁面載不出來是正常的）。")
    print("   把網址列「整段」或其中的 code= 值複製貼回來。\n")
    raw = input("貼上重導後的網址或 code： ").strip()
    if "code=" in raw:
        # 從 code= 之後抓到下一個 & 為止（不管前面有沒有 scheme/host 都適用）
        code = urllib.parse.unquote(raw.split("code=", 1)[1].split("&", 1)[0])
    else:
        code = raw
    data = urllib.parse.urlencode({
        "code": code, "client_id": cid, "client_secret": sec,
        "redirect_uri": REDIRECT, "grant_type": "authorization_code"}).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
    try:
        tok = json.loads(urllib.request.urlopen(req, timeout=20).read())
    except urllib.error.HTTPError as e:
        print("交換失敗：", e.read().decode()[:300]); return
    rt = tok.get("refresh_token")
    if not rt:
        print("沒拿到 refresh_token（回應：%s）。請確認 OAuth client 是 Desktop app、且用了 prompt=consent。" % tok); return
    cfg["GCAL_REFRESH_TOKEN"] = rt
    save(cfg)
    print("\n✅ 成功：refresh token 已寫入", ENV, "（chmod600）。跟 Claude 說一聲即可建日曆工具。")

if __name__ == "__main__":
    import urllib.error
    main()
