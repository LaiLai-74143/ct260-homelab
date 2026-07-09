"""Grafana 同源反代(待辦49 0.8.1,2026-07-09)。

問題:portal.hl(HTTPS)嵌 grafana.hl 的 d-solo iframe 掛掉——跨子網域 + Authelia
的 SameSite=lax session cookie 在 iframe 子請求被瀏覽器擋,forward_auth 拿不到
session → 302 auth.hl → iframe 導航失敗(灰色錯誤頁)。:3002 直連(LAN http)沒
Authelia 故 0.7.0 LAN 版能渲染,但 portal.hl 版一直掛。

解法:讓圖表走 portal 自己的網域——BFF 反代 /grafana/* → Grafana :3002(匿名 Viewer,
伺服器對伺服器)。iframe 變同源相對路徑 → 無混合內容、無跨網域 cookie、iframe 裡
不碰 Authelia,portal.hl 與 :8088 兩邊一致。

d-solo HTML 用 <base href="/"> + 相對資產 + bootData.appSubUrl="";只需把這兩處改寫
成 /grafana 前綴(等同 serve_from_sub_path 的效果,但只在 proxy 層,不動 Grafana 設定、
不影響 grafana.hl 直連)。其餘 public/api/ds 皆透明轉發。

曝險:能到 portal 者(:8088=PC40;portal.hl=Authelia 認證)可經此讀 Grafana——與既有
匿名 Viewer 於 :3002 的曝險同級(見監控告警 §7),不新增外露面。不轉發 client cookie
給 Grafana(免把 authelia_session 漏進 Grafana log)。
"""
import os

import httpx
from fastapi import Request
from fastapi.responses import Response

UPSTREAM = os.environ.get("GRAFANA_UPSTREAM", "http://10.80.80.11:3002")
PREFIX = "/grafana"
_TIMEOUT = httpx.Timeout(30.0, connect=5.0)

# 不轉發給上游:host(讓 httpx 自填)、cookie(免漏 authelia_session)、
# accept-encoding(拿無壓縮好改寫)、hop-by-hop。
# ★ authorization/proxy-authorization 必擋(審查 2026-07-09 高危):Grafana 預設啟
#   HTTP Basic Auth 且 admin/admin 弱密,透傳 Authorization 等於讓能到 portal 的人
#   `curl -u admin:admin /grafana/api/admin/...` 以伺服器管理員接管——遠逾「匿名
#   Viewer 唯讀」界線。x-webauth-* 一併擋(防日後啟 auth.proxy 被標頭冒名)。
_DROP_REQ = {"host", "cookie", "accept-encoding", "connection", "content-length", "keep-alive",
             "authorization", "proxy-authorization",
             "x-webauth-user", "x-webauth-groups", "x-webauth-email", "x-webauth-role", "x-webauth-name"}
# 管理/寫入面前綴一律 403(縱深防禦;匿名 Viewer 本就無權,此為明示第二道)。
# 圖表渲染只需 d-solo HTML + public 資產 + api/ds/query + avatar,不碰這些。
_DENY_PREFIXES = ("api/admin", "admin/", "api/datasources", "api/serviceaccounts",
                  "api/auth/keys", "api/users", "api/orgs")
# 不回給 client:hop-by-hop + 由 Response 重算的、Grafana 匿名可能設的 cookie
_DROP_RESP = {"connection", "keep-alive", "transfer-encoding", "content-encoding",
              "content-length", "set-cookie"}


async def proxy(request: Request, path: str) -> Response:
    if path.lower().lstrip("/").startswith(_DENY_PREFIXES):
        return Response("此路徑不經 portal 反代(僅圖表渲染)", status_code=403)
    body = await request.body()
    req_headers = {k: v for k, v in request.headers.items() if k.lower() not in _DROP_REQ}
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            up = await client.request(request.method, f"{UPSTREAM}/{path}",
                                      params=request.query_params, content=body or None,
                                      headers=req_headers, follow_redirects=False)
    except httpx.HTTPError as e:
        return Response(f"Grafana 上游連線失敗:{type(e).__name__}", status_code=502)

    ct = up.headers.get("content-type", "")
    data = up.content
    if "text/html" in ct:
        # 只改 d-solo 初始 HTML 的兩處:資產基底 + API 前綴(bootData.appSubUrl)
        text = data.decode("utf-8", "replace")
        text = text.replace('<base href="/"', f'<base href="{PREFIX}/"')
        text = (text.replace('"appSubUrl":""', f'"appSubUrl":"{PREFIX}"')
                    .replace('"appSubUrl": ""', f'"appSubUrl":"{PREFIX}"'))
        data = text.encode("utf-8")

    headers = {k: v for k, v in up.headers.items() if k.lower() not in _DROP_RESP}
    return Response(content=data, status_code=up.status_code, headers=headers,
                    media_type=ct or None)
