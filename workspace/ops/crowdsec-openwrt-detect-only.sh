#!/bin/sh
# crowdsec-openwrt-detect-only.sh — CrowdSec 在 OpenWrt「只偵測不封鎖」安裝(觀察兩週用)。
# 在哪跑:OpenWrt(VM101)root。從 CT260 一鍵:  ssh openwrt-auto 'sh -s' < ~/workspace/ops/crowdsec-openwrt-detect-only.sh
# 使用者決策(2026-07-18):裝偵測-only,兩週後對照自製 portscan-autoban 命中差異再決定要不要上 bouncer。
# ★ 明確不做:不裝 crowdsec-firewall-bouncer、不 cscli bouncers add、不新增/改任何 nft table/chain。
# 掃描發現+2026-07-18 實裝踩過、本腳本已處理的三顆地雷:
#   ① LAPI 預設 127.0.0.1:8080 已被 AdGuardHome 佔用 → 改 8081(不然 crowdsec 起不來)。
#   ② BusyBox logread 檔案格式≠RFC3164、hub dropbear parser 只認 PAM 訊息 → 3b 兩個自訂 parser,
#      裝完仍『強制』cscli explain 實測(全 unparsed=靜默失效,alerts 永遠掛零卻不報錯)。
#   ③ 沒有 source: cmd 這種資料源 → uci 加掛 log_file(不動 log_ip 遠端轉發),file 源 tail。
set -u
NEWPORT=8081

echo "===== 0) 前置檢查(arch / 資源 / 8080 佔用)====="
uname -m; grep -i arch /etc/openwrt_release 2>/dev/null
free | awk '/Mem/{print "RAM 可用約 "$4/1024" MB"}'; df -h / | tail -1
echo "8080 佔用者(預期 AdGuardHome,故 LAPI 改 $NEWPORT):"; netstat -tlnp 2>/dev/null | grep ':8080 ' || ss -tlnp 2>/dev/null | grep ':8080 '

echo "===== 1) apk 安裝 crowdsec 本體(不裝 bouncer)====="
apk update || { echo '!! apk update 失敗'; exit 1; }
apk add crowdsec || { echo '!! crowdsec 安裝失敗'; exit 1; }
cscli version || { echo '!! cscli 不可用'; exit 1; }

echo "===== 2) 改 LAPI 埠 8080→$NEWPORT(避開 AdGuardHome)====="
for f in /etc/crowdsec/config.yaml /etc/crowdsec/local_api_credentials.yaml; do
  [ -f "$f" ] && { cp "$f" "$f.before-portfix"; sed -i "s/127.0.0.1:8080/127.0.0.1:$NEWPORT/g; s#localhost:8080#localhost:$NEWPORT#g" "$f"; }
done
grep -R "$NEWPORT" /etc/crowdsec/config.yaml /etc/crowdsec/local_api_credentials.yaml 2>/dev/null | head

echo "===== 3) acquis:logd 加掛本機檔(log_file),crowdsec 用 file 源 tail ====="
# ★ 2026-07-18 實戰教訓:CrowdSec 沒有 source: cmd 這種資料源(config 直接 fatal)。
#   正解:uci 加 log_file(與既有 log_ip 遠端轉發「並存」——/etc/init.d/log 起兩個獨立
#   logread instance;絕不能改 log_ip,那是往 10.80.80.11:1514 監控棧的現役轉發)。
uci set system.@system[0].log_file='/var/log/messages'
uci commit system
/etc/init.d/log reload
sleep 2
[ -s /var/log/messages ] && echo "  /var/log/messages 出檔了" || { echo '!! log_file 沒出檔'; exit 1; }
cat > /etc/crowdsec/acquis.yaml <<'ACQ'
# logd 加掛的本機檔(log_file);遠端轉發 10.80.80.11:1514 不受影響
source: file
filenames:
  - /var/log/messages
labels:
  type: syslog
ACQ
echo "  acquis.yaml 已寫(file 源 /var/log/messages)"

echo "===== 3b) 自訂 parser ×2:BusyBox 檔案格式 + 無 PAM dropbear ====="
# 地雷②實測:logread -F 檔案格式=「Day Mon DD HH:MM:SS YYYY fac.sev prog[pid]: msg」,
# 標準 syslog-logs 解不出 → s00 自訂 grok 接手;hub 版 dropbear parser 只認
# "Bad PAM password attempt",OpenWrt dropbear 無 PAM、訊息是 "Bad password attempt" → s01 補洞。
mkdir -p /etc/crowdsec/parsers/s00-raw /etc/crowdsec/parsers/s01-parse
cat > /etc/crowdsec/parsers/s00-raw/openwrt-logread.yaml <<'PARSER'
filter: "evt.Line.Labels.type == 'syslog'"
onsuccess: next_stage
name: local/openwrt-logread
description: "OpenWrt logread file format -> program/message"
pattern_syntax:
  OPENWRT_LOGTIME: '%{DAY} %{MONTH} +%{MONTHDAY} %{TIME} %{YEAR}'
nodes:
  - grok:
      pattern: '^%{OPENWRT_LOGTIME:logtime} %{DATA:facility}\.%{NOTSPACE:severity} %{SYSLOGPROG}: %{GREEDYDATA:message}'
      apply_on: Line.Raw
statics:
  - parsed: logsource
    value: syslog
  - target: evt.StrTime
    expression: evt.Parsed.logtime
PARSER
cat > /etc/crowdsec/parsers/s01-parse/openwrt-dropbear-logs.yaml <<'PARSER'
onsuccess: next_stage
filter: "evt.Parsed.program == 'dropbear'"
name: local/openwrt-dropbear-logs
description: "Parse OpenWrt (non-PAM) dropbear auth failures"
nodes:
  - grok:
      pattern: "Bad password attempt for '%{DATA:user}' from %{IP:source_ip}:%{INT:port}"
      apply_on: message
  - grok:
      pattern: "Max auth tries reached - user '%{DATA:user}' from %{IP:source_ip}:%{INT:port}"
      apply_on: message
statics:
  - meta: service
    value: dropbear
  - meta: target_user
    expression: evt.Parsed.user
  - meta: source_ip
    expression: evt.Parsed.source_ip
  - meta: log_type
    value: ssh_failed-auth
PARSER
echo "  兩個自訂 parser 已寫"

echo "===== 4) hub 更新 + 裝偵測用 collection/parser(不裝任何 bouncer)====="
cscli hub update
cscli collections install crowdsecurity/linux || true
cscli collections install crowdsecurity/sshd || true
cscli parsers install crowdsecurity/dropbear-logs || true   # OpenWrt 用 dropbear 非 openssh

echo "===== 5) 啟動 crowdsec(僅 alert/decision,無 bouncer→不會真封鎖)====="
/etc/init.d/crowdsec enable
/etc/init.d/crowdsec restart
sleep 5
/etc/init.d/crowdsec status 2>/dev/null || ps | grep -c '[c]rowdsec'

echo ""
echo "########################################################################"
echo "# ★★ 地雷② 驗證:logread 格式能不能被 crowdsec 解析?親眼看下面輸出 ★★"
echo "########################################################################"
tail -30 /var/log/messages > /tmp/logread.sample
printf "%s\n" "$(date '+%a %b %e %T %Y') authpriv.warn dropbear[9999]: Bad password attempt for 'testuser' from 203.0.113.99:4444" >> /tmp/logread.sample
echo "--- cscli explain(dropbear 樣本行要走到 parser success 🟢 才算過)---"
cscli explain --file /tmp/logread.sample --type syslog 2>&1 | tail -40
echo ""
echo "--- cscli metrics(acquis 有沒有讀進 line)---"; cscli metrics 2>&1 | sed -n '1,25p'
echo "--- cscli alerts list(裝完幾分鐘內可能還空,但若一直掛零+上面 explain 全 unparsed=地雷②中了)---"
cscli alerts list 2>&1 | head

echo ""
echo "===== 觀察期兩週指引 ====="
echo "· 定期看:cscli alerts list / cscli decisions list;對照 logread | grep Portscan-Tripwire 的自製命中。"
echo "· 全程不跑 cscli bouncers add、不裝 firewall-bouncer、不動 nft。兩週後回報命中差異再議上不上封鎖。"
echo "· 回滾:/etc/init.d/crowdsec disable && /etc/init.d/crowdsec stop && apk del crowdsec;"
echo "        uci delete system.@system[0].log_file && uci commit system && /etc/init.d/log reload(未動 nft/log_ip,零殘留)。"
