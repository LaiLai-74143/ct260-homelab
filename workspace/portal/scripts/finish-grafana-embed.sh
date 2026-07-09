#!/bin/bash
# finish-grafana-embed.sh — portal 0.7.0 前置:CT201 Grafana 開 iframe 嵌入
#   GF_SECURITY_ALLOW_EMBEDDING=true(卸 X-Frame-Options,否則瀏覽器拒繪 iframe)
#   GF_AUTH_ANONYMOUS_ENABLED=true + ORG_ROLE=Viewer + HIDE_VERSION=true
#   (iframe 內沒有 Grafana 登入態,匿名不開只會渲染出登入頁)
# 曝險界定(2026-07-09 裁決,審查 sec-ux 鏡頭確認後明文):
#   匿名=Main Org. 正式 Viewer,不只「看兩張 dashboard」——OSS 無 datasource 權限,
#   匿名可 POST /api/ds/query 對 Prometheus/Loki 下任意唯讀查詢、/api/search 列全部
#   dashboard。接受理由:能碰到的位置僅 (a) PC40/VLAN80 直達 :3002(本就保留為排障
#   後備)(b) 過 Authelia 的 session(grafana.hl 外層防線不變)。snapshot 面順手關死
#   (GF_SNAPSHOTS_*=false),admin/編輯面照舊要登入。V7/監控告警文件同步此界定。
# 冪等:重跑無害(env 已在=跳過)。
# 回滾:compose 蓋回 /opt/monitoring/_backups/docker-compose.yml.before-grafana-embed-<TS>
#       + cd /opt/monitoring && docker compose up -d grafana
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 1. 讀現役 compose,冪等插入 GF_ 環境變數 =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "GF_SERVER_ROOT_URL" "$TMP/dc.yml" || { echo "compose 讀取失敗/無 GF_SERVER_ROOT_URL 錨點"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
want = {"GF_SECURITY_ALLOW_EMBEDDING": "true",
        "GF_AUTH_ANONYMOUS_ENABLED": "true",
        "GF_AUTH_ANONYMOUS_ORG_ROLE": "Viewer",
        "GF_AUTH_ANONYMOUS_HIDE_VERSION": "true",
        # 匿名開啟後把 snapshot 面關死(防匿名 POST /api/snapshots 落地持久分享)
        "GF_SNAPSHOTS_ENABLED": "false",
        "GF_SNAPSHOTS_EXTERNAL_ENABLED": "false"}
# 鍵已在但值錯(如 =false)必須原地改正——只看鍵不看值會跳過編輯,
# 重跑永遠走同一分支,XFO 驗證失敗卻無自癒路徑(審查 2026-07-09 確認項)
missing, fixed = [], []
for k, v in want.items():
    pl = re.compile(rf"^([ \t]*-[ \t]*){re.escape(k)}=(.*)$", re.M)
    pm = re.compile(rf"^([ \t]*){re.escape(k)}:[ \t]*(.*)$", re.M)
    m = pl.search(s) or pm.search(s)
    if not m:
        missing.append(k); continue
    cur = m.group(2).strip().strip('"').strip("'")
    if cur != v:
        if pl.search(s):
            s = pl.sub(lambda mm, k=k, v=v: f"{mm.group(1)}{k}={v}", s, count=1)
        else:
            s = pm.sub(lambda mm, k=k, v=v: f'{mm.group(1)}{k}: "{v}"', s, count=1)
        fixed.append(f"{k}: {cur}→{v}")
if not missing and not fixed:
    print("四鍵已齊備且值正確,不動 compose"); raise SystemExit
# 缺鍵者插入:錨在既有 GF_SERVER_ROOT_URL 那行,複製其縮排與風格(list 或 mapping 皆容)
if missing:
    m = re.search(r"^([ \t]*-[ \t]*)GF_SERVER_ROOT_URL=.*$", s, re.M)
    if m:
        ins = "".join(f"\n{m.group(1)}{k}={want[k]}" for k in missing)
    else:
        m = re.search(r"^([ \t]*)GF_SERVER_ROOT_URL:.*$", s, re.M)
        assert m, "錨點未命中:GF_SERVER_ROOT_URL 兩種風格皆不符"
        # mapping 風格:值必須加引號,裸 true 會被 YAML 解成布林、compose config 直接報型別錯
        ins = "".join(f'\n{m.group(1)}{k}: "{want[k]}"' for k in missing)
    s = s[:m.end()] + ins + s[m.end():]
open(p, "w").write(s)
print("compose edited — 新增:", missing or "無", "| 改值:", fixed or "無")
EOF

echo "== 2. 候選驗證 → 備份 → 換裝 → 重建 grafana(瞬斷數秒,Kuma 可能閃紅一次,無需處理) =="
scp -q "$TMP/dc.yml" pve24:/tmp/dc.grafana.yml
ssh pve24 "sudo pct push 201 /tmp/dc.grafana.yml /tmp/dc.grafana.yml && rm -f /tmp/dc.grafana.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.grafana.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-grafana-embed-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-grafana-embed-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.grafana.yml
cd /opt/monitoring && docker compose up -d grafana
for i in \$(seq 30); do curl -sf -m 3 http://127.0.0.1:3002/api/health >/dev/null && break; sleep 2; done
curl -sf -m 3 http://127.0.0.1:3002/api/health >/dev/null || { echo grafana 起不來,回滾見檔頭; exit 1; }
echo grafana-healthy
'"

echo "== 3. 驗證:匿名可讀兩張 dashboard + panel id 對照 + XFO 已卸 + 管理面仍鎖 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
curl -s -m 8 http://127.0.0.1:3002/api/dashboards/uid/homelab-overview | python3 -c \"
import json,sys
d=json.load(sys.stdin)
assert \\\"dashboard\\\" in d, f\\\"匿名讀取失敗:{d}——org 名非預設 Main Org.?補 GF_AUTH_ANONYMOUS_ORG_NAME=<實際 org 名> 再重跑\\\"
ids={p[\\\"id\\\"] for p in d[\\\"dashboard\\\"][\\\"panels\\\"]}
need={3,4,5,6,13,14}
assert need <= ids, f\\\"homelab-overview panel id 缺:{need-ids}(portal 嵌的 id 要跟著改)\\\"
print(\\\"homelab-overview 匿名可讀,panel ids ✓\\\")\"
curl -s -m 8 http://127.0.0.1:3002/api/dashboards/uid/openwrt-portscan-autoban | python3 -c \"
import json,sys
d=json.load(sys.stdin)
assert \\\"dashboard\\\" in d, f\\\"匿名讀取失敗:{d}\\\"
ids={p[\\\"id\\\"] for p in d[\\\"dashboard\\\"][\\\"panels\\\"]}
need={6,7,10}
assert need <= ids, f\\\"openwrt-portscan-autoban panel id 缺:{need-ids}(portal 嵌的 id 要跟著改)\\\"
print(\\\"openwrt-portscan-autoban 匿名可讀,panel ids ✓\\\")\"
if curl -sI -m 8 http://127.0.0.1:3002/login | grep -qi x-frame-options; then
  echo \"X-Frame-Options 仍在,embedding 未生效\"; exit 1
fi
echo \"XFO 已卸 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 http://127.0.0.1:3002/api/admin/settings)
{ [ \"\$code\" = 401 ] || [ \"\$code\" = 403 ]; } || { echo \"admin API 竟回 \$code(應 401/403)\"; exit 1; }
echo \"管理 API 匿名 \$code(仍鎖)✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 \"http://127.0.0.1:3002/d-solo/homelab-overview/homelab-overview?orgId=1&panelId=3\")
[ \"\$code\" = 200 ] || { echo \"d-solo 回 \$code\"; exit 1; }
echo \"d-solo 200 ✓\"
'"

echo "== 完成(TS=$TS)。後續:跑 finish-portal-070.sh 部署前端;手機 portal.hl 安全面板/設備總覽驗圖 =="
