#!/bin/bash
# Safe Minecraft backup script inside PVE24 CT100.
#
# Role:
# - Notify players.
# - Stop Minecraft through MCSManager API.
# - Archive Minecraft world/config/mods.
# - Restart Minecraft and verify Java process.
# - Keep local backup retention inside CT100.
#
# Annotation policy:
# - This script keeps local shell constants at the top.
# - Do not depend on DNS for backup/runtime paths.
# - [CONST: ...] comments are for human/audit/grep only.

set -euo pipefail

# [CONST: PVE24_CT100_MCS_ENV] CT100 MCSManager API env file
ENV_FILE="/root/mcsm.env"

# [CONST: PVE24_CT100_MC_DIR] CT100 Minecraft server directory on 24Bay PVE
MC_DIR="/root/minecraft"

# [CONST: PVE24_CT100_MC_BACKUP_DIR] CT100 local Minecraft backup directory on 24Bay PVE
BACKUP_DIR="/root/mc-backups"

KEEP_LOCAL=14

JAVA_PATTERN="java.*fabric-server-launch.jar"

# [CONST: PVE24_CT100_SAFE_BACKUP_LOCK] CT100 safe Minecraft backup lock file
LOCK_FILE="/var/lock/mc-safe-backup.lock"

DATE="$(date +%F_%H-%M-%S)"
BACKUP_FILE="$BACKUP_DIR/minecraft-$DATE.tar.zst"
TMP_BACKUP_FILE="$BACKUP_FILE.partial"

STOP_REQUESTED=0
SERVER_RESTARTED=0
SUCCESS=0
# mc-autosleep(2026-07-10):備份前的運行狀態。備份前睡著 -> 備份後保持關機,
# 開機與否只由玩家活動決定(CT102 LimboAutoServer -> CT100 mc-gate)。
WAS_RUNNING=0

BACKUP_ITEMS=()

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}"
}

fail() {
    log "ERROR" "$*"
    exit 1
}

cleanup_partial() {
    if [ -e "$TMP_BACKUP_FILE" ]; then
        log "WARN" "Removing incomplete backup: $TMP_BACKUP_FILE"
        rm -f -- "$TMP_BACKUP_FILE"
    fi
}

api_check_status_200() {
    local response="$1"

    if echo "$response" | grep -q '"status"[[:space:]]*:[[:space:]]*200'; then
        return 0
    fi

    log "ERROR" "MCSManager API returned non-success response: $response"
    return 1
}

mcs_command() {
    local cmd="$1"
    local response

    response="$(curl -sS -G "$MCS_URL/api/protected_instance/command" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "X-Requested-With: XMLHttpRequest" \
        --data-urlencode "apikey=$MCS_API_KEY" \
        --data-urlencode "daemonId=$DAEMON_ID" \
        --data-urlencode "uuid=$INSTANCE_ID" \
        --data-urlencode "command=$cmd")"

    api_check_status_200 "$response"
}

mcs_stop() {
    local response

    response="$(curl -sS -G "$MCS_URL/api/protected_instance/stop" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "X-Requested-With: XMLHttpRequest" \
        --data-urlencode "apikey=$MCS_API_KEY" \
        --data-urlencode "daemonId=$DAEMON_ID" \
        --data-urlencode "uuid=$INSTANCE_ID")"

    api_check_status_200 "$response"
}

mcs_start() {
    local response

    # MCSManager open endpoint uses POST with query parameters.
    response="$(curl -sS -X POST "$MCS_URL/api/protected_instance/open?apikey=$MCS_API_KEY&daemonId=$DAEMON_ID&uuid=$INSTANCE_ID" \
        -H "X-Requested-With: XMLHttpRequest")"

    api_check_status_200 "$response"
}

wait_for_stop() {
    log "INFO" "Waiting for Minecraft Java process to stop."

    local i=0

    while [ "$i" -lt 180 ]; do
        if ! pgrep -f "$JAVA_PATTERN" >/dev/null; then
            log "OK" "Minecraft Java process stopped."
            return 0
        fi

        i=$((i + 1))
        sleep 1
    done

    return 1
}

wait_for_start() {
    log "INFO" "Waiting for Minecraft Java process to start."

    local i=0

    while [ "$i" -lt 180 ]; do
        if pgrep -f "$JAVA_PATTERN" >/dev/null; then
            log "OK" "Minecraft Java process detected."
            return 0
        fi

        i=$((i + 1))
        sleep 1
    done

    return 1
}

restart_on_failure() {
    local exit_code=$?

    trap - EXIT INT TERM

    if [ "$SUCCESS" -eq 1 ]; then
        cleanup_partial
        exit "$exit_code"
    fi

    log "ERROR" "Backup script exited abnormally with code $exit_code."

    cleanup_partial

    if [ "$STOP_REQUESTED" -eq 1 ] && [ "$SERVER_RESTARTED" -eq 0 ]; then
        log "WARN" "Server may be stopped. Attempting emergency restart."

        if mcs_start; then
            SERVER_RESTARTED=1
            wait_for_start || log "ERROR" "Emergency restart command sent, but Java process was not detected."
        else
            log "ERROR" "Emergency restart failed."
        fi
    fi

    exit "$exit_code"
}

prune_local_backups() {
    local files=()
    local count delete_count i

    mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'minecraft-*.tar.zst' -printf '%f\n' | sort)

    count="${#files[@]}"

    if [ "$count" -le "$KEEP_LOCAL" ]; then
        log "INFO" "Local backups: $count. No pruning needed."
        return 0
    fi

    delete_count=$((count - KEEP_LOCAL))

    log "INFO" "Local backups: $count. Deleting oldest $delete_count."

    for ((i=0; i<delete_count; i++)); do
        if [ -n "${files[$i]}" ]; then
            log "DELETE" "$BACKUP_DIR/${files[$i]}"
            rm -f -- "$BACKUP_DIR/${files[$i]}"
        fi
    done
}

build_backup_item_list() {
    BACKUP_ITEMS=()

    [ -d "$MC_DIR/world" ] || fail "Required world directory not found: $MC_DIR/world"

    local item
    for item in \
        world \
        config \
        mods \
        server.properties \
        ops.json \
        whitelist.json \
        banned-ips.json \
        banned-players.json \
        usercache.json \
        eula.txt \
        fabric-server-launcher.properties \
        start.sh
    do
        if [ -e "$MC_DIR/$item" ]; then
            BACKUP_ITEMS+=("$item")
        else
            log "WARN" "Optional backup item not found, skipping: $item"
        fi
    done
}

check_environment() {
    [ -f "$ENV_FILE" ] || fail "Missing env file: $ENV_FILE"

    # shellcheck disable=SC1090
    source "$ENV_FILE"

    : "${MCS_URL:?Missing MCS_URL in $ENV_FILE}"
    : "${MCS_API_KEY:?Missing MCS_API_KEY in $ENV_FILE}"
    : "${DAEMON_ID:?Missing DAEMON_ID in $ENV_FILE}"
    : "${INSTANCE_ID:?Missing INSTANCE_ID in $ENV_FILE}"

    [ -d "$MC_DIR" ] || fail "Minecraft directory not found: $MC_DIR"

    mkdir -p "$BACKUP_DIR"

    if ! touch "$BACKUP_DIR/.write-test.$$" 2>/dev/null; then
        fail "Backup directory is not writable: $BACKUP_DIR"
    fi

    rm -f "$BACKUP_DIR/.write-test.$$"

    find "$BACKUP_DIR" \
        -maxdepth 1 \
        -type f \
        -name '*.partial' \
        -print \
        -delete 2>/dev/null || true
}

main() {
    exec 200>"$LOCK_FILE" || fail "Cannot create lock file: $LOCK_FILE"

    # mc-autosleep:鎖與 mc-gate hook 共用;hook 鎖窗僅秒級(送出 open 即放),等得到
    if ! flock -w 120 200; then
        fail "Could not acquire backup lock within 120s."
    fi

    trap restart_on_failure EXIT INT TERM

    check_environment
    build_backup_item_list

    log "INFO" "Starting safe Minecraft backup: $BACKUP_FILE"

    if pgrep -f "$JAVA_PATTERN" >/dev/null; then
        WAS_RUNNING=1
        log "INFO" "Notifying players: 60 seconds before backup."
        mcs_command "say 伺服器將在 60 秒後停服備份，約數分鐘後恢復。"
        sleep 30

        log "INFO" "Notifying players: 30 seconds before backup."
        mcs_command "say 伺服器將在 30 秒後停服備份。"
        sleep 20

        log "INFO" "Running save-all flush."
        mcs_command "save-all flush"

        # Known limitation: this is a fixed wait. The subsequent stop command will also save worlds.
        sleep 15

        log "INFO" "Stopping Minecraft via MCSManager."
        STOP_REQUESTED=1
        mcs_stop

        wait_for_stop || fail "Minecraft Java process did not stop within timeout."
    else
        log "WARN" "Minecraft Java process is not running before backup. Backup will proceed without stop command."
    fi

    log "INFO" "Creating backup partial file: $TMP_BACKUP_FILE"

    cd "$MC_DIR"

    if ! tar --zstd -cf "$TMP_BACKUP_FILE" "${BACKUP_ITEMS[@]}"; then
        fail "tar backup failed."
    fi

    if [ ! -s "$TMP_BACKUP_FILE" ]; then
        fail "Backup partial file is empty: $TMP_BACKUP_FILE"
    fi

    mv -- "$TMP_BACKUP_FILE" "$BACKUP_FILE"

    log "OK" "Backup created: $BACKUP_FILE"

    if [ "$WAS_RUNNING" -eq 1 ]; then
        log "INFO" "Starting Minecraft via MCSManager."
        mcs_start
        SERVER_RESTARTED=1

        wait_for_start || fail "Minecraft Java process was not detected after start command."
    else
        log "INFO" "Server was already stopped before backup; leaving it stopped (mc-autosleep)."
    fi

    prune_local_backups

    SUCCESS=1
    trap - EXIT INT TERM
    cleanup_partial

    log "DONE" "Minecraft backup completed and server restart verified."
}

main "$@"
