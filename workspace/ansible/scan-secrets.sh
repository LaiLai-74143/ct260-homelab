#!/usr/bin/env bash
# scan-secrets.sh:backups/ 憑證掃描 gate(待辦48,沿用待辦36 掃描精神)。
# 政策:明文秘鑰/已知 token 格式/私鑰 → 擋下;密碼「雜湊」($2a/$2b/$2y/$5$/$6$)可入 private repo。
# 跑 config-backup.yml 之後、git commit 之前必跑;有 HIT 先處理(剔除檔案或改 host_vars 排除)再 commit。
set -uo pipefail
d="$(cd "$(dirname "$0")" && pwd)/backups"
[ -d "$d" ] || { echo "scan-secrets: no backups/ dir"; exit 0; }
hits=0

# 1) 已知 token 格式 + 私鑰塊(TG bot、GitHub、Slack、AWS、PEM)
if grep -rnIE 'ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}' "$d"; then
  hits=1
fi

# 1b) uci wireguard 金鑰(base64 44 字;待辦24):redact 後應為 **REDACTED**,見明文即擋
if grep -rnIE "option (private_key|preshared_key) '[A-Za-z0-9+/]{42,}='" "$d"; then
  hits=1
fi

# 2) 明文密碼/秘鑰賦值(排除:雜湊、HA !secret 引用、空值/布林、環境變數引用)
if grep -rnIE '(password|passwd|secret|api_key|apikey|auth_key|access_key)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^"'"'"'[:space:]$!][^"'"'"'[:space:]]{5,}' "$d" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE '\$2[aby]\$|\$5\$|\$6\$|!secret |: *(null|false|true|""|'"''"') *$|passwordfile|password_file|_hash|REDACTED'; then
  hits=1
fi

if [ "$hits" -eq 0 ]; then
  echo "scan-secrets: clean ($(find "$d" -type f | wc -l) files)"
else
  echo "scan-secrets: 上列 HIT——勿 commit,先剔除或加排除規則" >&2
  exit 1
fi
