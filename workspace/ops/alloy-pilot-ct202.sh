#!/bin/bash
# alloy-pilot-ct202.sh — promtail→Grafana Alloy 遷移「先導試點」(CT202 squid/fwdproxy)。
# 在哪跑:CT260(codex),整段可複製:  bash ~/workspace/ops/alloy-pilot-ct202.sh
# 經 ssh pve24-auto → sudo pct exec 202 操作;需 pve24 sudo(自動化專鑰 pve24-auto 已具)。
# 設計原則(2026-07-18 占位 token 事故教訓):
#   ① 不停 promtail、不切服務——只做「影子跑」(shadow):alloy 帶額外標籤 pilot="alloy-shadow"
#      並存送 Loki,證明管線正確才由使用者手動切換(腳本末印出切換+回滾指令,不自動執行)。
#   ② 驗證打「會壞的那一層」=去 Loki 查得到影子資料才算過,不看 alloy 自己說 ready。
#   ③ 版本/sha256 比照 promtail 當初紀律:下載後核 checksum 再用。
set -uo pipefail
CT=202
ALLOY_VER="1.17.1"
LOKI="http://10.80.80.11:3100"
# 在 CT202 內跑任意指令:base64 傳輸,避開 ssh→sudo→pct exec→bash -lc 多層引號地獄。
# (舊版 bash -lc "\$1" 的 $1 被轉義成字面、遠端無 positional 參數→恆空指令、靜默假成功。)
PX() {
  local b64; b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  ssh pve24-auto "sudo /usr/sbin/pct exec $CT -- bash -lc 'echo $b64 | base64 -d | bash -l'"
}

echo "===== 0) 基線:promtail 現況 + Loki 目前有 ct202 資料 ====="
PX 'ps -ef | grep -c "[p]romtail" ; echo "promtail 進程數(≥1=活)"'
curl -sG "$LOKI/loki/api/v1/label/host/values" | grep -o 'ct202' | head -1 \
  && echo "  ✓ Loki host 標籤含 ct202(基線在)" || echo "  ⚠ 基線查無 ct202,先查清再繼續"

echo "===== 1) 備份 CT202 promtail 設定(不刪、切換後留 24-48h 回滾窗)====="
TS=$(date +%Y%m%d-%H%M%S)
PX "cp /etc/promtail/config.yml /etc/promtail/config.yml.before-alloy-$TS && echo 備份=config.yml.before-alloy-$TS"

echo "===== 2) 下載 Alloy $ALLOY_VER(amd64)到 CT202 + sha256 核對 ====="
# apt.grafana.com 有 deb,但為與 promtail 手動二進位同構、避免動 CT202 的 apt 來源,用 GitHub 靜態 zip。
# v1.17.1 只出單一 SHA256SUMS 彙總檔(無逐檔 .sha256);下載保留原檔名才對得上校驗行。
# ★ 用 /var/tmp(磁碟)不用 /tmp:CT202 的 /tmp 是 tmpfs,LXC 裡 tmpfs 吃容器記憶體配額,
#   zip(~130MB)+解壓(~400MB)會撐爆 512M cgroup 直接 OOM(2026-07-18 預檢抓到)。
PX "command -v unzip >/dev/null || apt-get install -y unzip"
PX "cd /var/tmp && rm -f alloy-linux-amd64.zip SHA256SUMS alloy-linux-amd64 && \
  curl -fsSL -O https://github.com/grafana/alloy/releases/download/v$ALLOY_VER/alloy-linux-amd64.zip && \
  curl -fsSL -O https://github.com/grafana/alloy/releases/download/v$ALLOY_VER/SHA256SUMS && \
  grep alloy-linux-amd64.zip SHA256SUMS | sha256sum -c - && \
  unzip -o alloy-linux-amd64.zip && mv alloy-linux-amd64 /usr/local/bin/alloy && chmod +x /usr/local/bin/alloy && \
  rm -f alloy-linux-amd64.zip && /usr/local/bin/alloy --version | head -1" \
  || { echo '!! 下載或校驗失敗,中止(未動任何現役服務)'; exit 1; }

echo "===== 3) promtail config.yml → Alloy River 設定(自動轉換,人工必須覆核)====="
PX "mkdir -p /etc/alloy && \
  /usr/local/bin/alloy convert --source-format=promtail --output=/etc/alloy/config.alloy /etc/promtail/config.yml && \
  echo '--- 轉出的 config.alloy(請逐段覆核:squid 的 {access,cache}.log glob、journal relabel、Loki push URL)---' && \
  cat /etc/alloy/config.alloy"
echo ""
echo ">>> 停一下:上面 config.alloy 若 squid glob 或 journal relabel 有走樣,先手改再進第 4 步。"

echo "===== 4) 影子跑(不動 promtail):alloy 前景起,注入 pilot=alloy-shadow 標籤送 Loki ====="
echo "在 CT202 上執行(這步會前景卡住,另開視窗或 tmux;驗證完 Ctrl-C 收):"
cat <<'SHADOW'
  # 先在 shadow.alloy 的 loki.write 區塊手加 external_labels { pilot = "alloy-shadow" }
  # (River 語法,加在 endpoint 內),這樣影子送的資料帶 pilot 標籤、查得出「是 alloy 送的」
  # 而非 promtail;http 埠 12345 是 alloy 預設 UI,不撞 promtail 的 9080。
  ssh pve24-auto "sudo /usr/sbin/pct exec 202 -- bash -lc '
    cp /etc/alloy/config.alloy /tmp/shadow.alloy
    # ←此處手動編 /tmp/shadow.alloy,在 loki.write 的 endpoint {...} 內加一行 external_labels
    /usr/local/bin/alloy run /tmp/shadow.alloy --server.http.listen-addr=127.0.0.1:12345 \
      --stability.level=generally-available
  '"
SHADOW
echo ""
echo "  另開視窗,發 canary 並到 Loki 查『帶 pilot 標籤』的影子資料(這才是會壞的那一層):"
cat <<VERIFY
  ssh pve24-auto "sudo /usr/sbin/pct exec 202 -- logger -t alloy-pilot canary-\$(date +%s)"
  sleep 8
  curl -sG "$LOKI/loki/api/v1/query" --data-urlencode 'query={pilot="alloy-shadow"} |= "canary"' \
    | grep -o 'alloy-pilot' && echo "  ✓ 帶 pilot 標籤查得到 canary=確定是 Alloy 管線送的,設定正確"
VERIFY
echo ""
echo "===== 5) 影子過關後,由使用者手動切換(privileged;本腳本不執行)====="
cat <<'CUTOVER'
  # 切換(維運 session,有 systemctl 權限):
  ssh pve24-auto "sudo /usr/sbin/pct push 202 <alloy.service> /etc/systemd/system/alloy.service"
  # 停 promtail(保留 binary+unit 當回滾)、起 alloy:
  ssh pve24-auto "sudo /usr/sbin/pct exec 202 -- bash -lc 'systemctl disable --now promtail; systemctl enable --now alloy'"
  # 切後驗證:重發 canary,{host=\"ct202\"} 查得到、job 標籤集合(journal/squid)與切換前一致。
  # 回滾:systemctl disable --now alloy; systemctl enable --now promtail(binary/unit 都還在)。
CUTOVER
echo "先導完成。穩定 24-48h 再滾 CT270→CT100(順修 mcsmanager 死路徑)→CT201(syslog receiver 最兇)→CT260→VM300。"
