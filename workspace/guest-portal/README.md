# guest-portal —— 對外唯讀分享站(行程 + 借貸)

給受邀外人看的迷你入口:登入後顯示屋主未來 14 天行程(唯讀)+ 與該人相關的借貸往來。
比照 Vaultwarden 的對外模式(CF Tunnel → CT203 Caddy),**不經 Authelia / 單一入口**。

- 公網名:`schedule.lailai74143.com`(CF proxied;與 hl.* 零公網 record 戒律無關)
- 落點:**CT205 schedule**(VLAN60 DMZ,10.60.60.11)——對外服務放 DMZ,非個資節點 CT270
- 技術:BFF = 純 stdlib `http.server`(零 pip,比照 CT203/life-ops-mcp 最小攻擊面);
  前端 = Vite+React+Tailwind(沿用入口大廳視覺)
- 資料:**推不是拉**——CT260 `hl-write-guest`(cron */30)讀 GCal + NocoDB → `guest.json`
  → hl-push CT205;BFF 零憑證、零出站,只讀這份快照

## 架構

```
外人瀏覽器 ─ CF edge(TLS) ─ cloudflared(CT203)─ Caddy :80 host 分流
                                                   ├ schedule.*  → CT205:8300(本站)
                                                   └ 其餘(pw.*)→ DXP:50303(Vaultwarden,現況)
CT260 hl-write-guest(cron)─ hl-push ─▶ CT205 /opt/guest-portal/data/guest.json(唯讀快照)
CT260 hl-guest(帳號管理)─ 寫 ~/.config/homelab/guest-accounts.json(600,含 scrypt hash)
CT260 hl-guest-watch(cron */5)─ 拉 CT205 audit.jsonl ─ 登入異常 → TG
```

## 目錄

```
bff/app/          純 stdlib BFF
  server.py       http.server 入口(login/logout/me/data/health + SPA)
  security.py     scrypt 密碼雜湊、HMAC session 簽章、審計 JSONL
  store.py        載入 guest.json(mtime 快取)、每人資料過濾、登入鎖定
  fixtures/       mock 用 guest.json(GUEST_MODE=mock)
frontend/src/     登入頁 + 儀表板(Calendar / DebtsPanel)
scripts/          finish-* 部署腳本 + hl-guest / hl-write-guest / hl-guest-watch
```

## 部署 runbook(依序)

> 高風險項(建 CT、改 Caddy)走 finish 腳本,每步可回滾。CF 帳號不經 Agent,由你操作。

**段B-1｜建 CT205（在 pve24,root）**
```
# 先把腳本送到 pve24（在 CT260,codex 身份;別名使用者寫不進 /root → 用 /tmp）:
scp ~/workspace/guest-portal/scripts/finish-guest-portal-01-ct.sh pve24:/tmp/
# 到 pve24 執行(sudo 會要密碼,互動終端跑):
ssh pve24
sudo bash /tmp/finish-guest-portal-01-ct.sh
```
建 CT205（VLAN60 10.60.60.11,512M/1core/4G,net 從 CT203 複製 bridge=vmbr0/tag=60,
儲存 SSD-2,模板 debian-13),裝 python3、gp 服務帳號、SESSION_SECRET、systemd unit。

**段B-2｜部署 app（在 CT260）**
```
hl-unlock && bash ~/workspace/guest-portal/scripts/finish-guest-portal-02-deploy.sh
```
build 前端 → 打包 app+dist → 推 CT205 → 啟動 → /api/health。

**段C｜資料管線 + 帳號（在 CT260）**
```
bash ~/workspace/guest-portal/scripts/finish-guest-portal-04-pipeline.sh   # 裝腳本 + cron
hl-guest add 小明 [記賬人名]     # 建帳號,密碼印出一次;人名對 NocoDB People 驗證
hl-write-guest --dry-run         # 手動驗一次資料對不對(不推送)
```

**段D｜Caddy 分流 + CF（在 CT260,再到 Cloudflare）**
```
bash ~/workspace/guest-portal/scripts/finish-guest-portal-03-caddy.sh
```
然後在 Cloudflare Zero Trust → Tunnels → Public Hostname 加:
`schedule.lailai74143.com` → Service `HTTP` → `localhost:80`(與 Vaultwarden 同 tunnel)。

## 帳號管理(CT260)

★ 帳號併入 **NocoDB People 表**(2026-07-10 起,與記賬共用同一庫);圖形化管理 = NocoDB 內建 UI
  (PC40 開 `192.168.20.70:8080` → Life-Ops → People,看 portal_user_hash/portal_pw_hash/portal_enabled)。
  登入名(身分證字號)與密碼(管制標籤號)**都以 scrypt 雜湊寫入**,連 NocoDB UI 也讀不回明文。
  故 CLI 管理用「記賬人名」定位,登入才用身分證字號。

```
hl-guest setup                                     # 一次性:People 加 portal 三欄(冪等)
hl-guest add <身分證字號> <記賬人名> [--ask-pass]  # 新增;人名不在 People 會自動建該員
hl-guest passwd <記賬人名> [--ask-pass]            # 重設密碼(--ask-pass=互動輸入,不回顯)
hl-guest disable / enable <記賬人名>               # 停用 / 啟用
hl-guest rm <記賬人名>                             # 移除登入(清三欄;People 列保留=仍是記賬對象)
hl-guest list                                      # 列出(不顯示身分證字號)
```
登入三態:帳號不符→「查無此帳號,聯絡管理員新增」;帳號符密碼錯→「密碼錯誤」;都符→通過。
任何變更自動推送 CT205。忘記密碼只能 `passwd` 重設(雜湊不可逆);忘記登入名只能 `rm` 後重 `add`。
BFF(CT205)仍只讀推送的 guest.json 快照,永不直連 NocoDB=DMZ 隔離不變。

## 登入審計與異常告警

BFF 寫 `audit.jsonl`,`hl-guest-watch`(cron */5)按情景發 TG。★身分證字號只在「未知帳號嘗試」
(蜜罐)才落明文;已知帳號一律記「記賬人名」,身分證字號永不落地:
| 情景 | 記錄 | TG |
|---|---|---|
| 未知帳號嘗試(帳號雜湊不符) | IP/**輸入原文(身分證字號)**/**密碼原文** | 即報 |
| 已知帳號密碼錯 | IP/**記賬人名**/**密碼遮罩**(`GUEST_LOG_WRONG_PW=full` 可切全文) | fails=3 跨門檻 / 鎖定 |
| 登入成功 | IP/**記賬人名**/國別,**永不記密碼** | 新 IP / 非 TW |

app 側:同 (person 或輸入,ip) 15 分內錯 5 次鎖 15 分;登入名+密碼皆 scrypt(登入 O(N) 逐一比對);
session HMAC 簽章(存 person 非身分證字號,12h TTL,無狀態=登出後舊 token 至 exp 前仍有效,刻意取捨)。

## 斷網語意

CF/外網掛 = 此站掛(純對外服務,合理);內網一切不受影響;CT270/NocoDB/GCal 無新依賴。

## 本機 mock 驗收

```
cd bff && GUEST_MODE=mock GUEST_COOKIE_SECURE=0 GUEST_STATIC=../frontend/dist \
  python3 -m app.server         # :8300;demo 登入 A123456789/demo1234(小明)、B987654321/wang5678(老王)
```
