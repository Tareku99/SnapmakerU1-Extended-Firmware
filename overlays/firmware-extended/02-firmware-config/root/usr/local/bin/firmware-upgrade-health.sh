#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

# A/B upgrade health gate.
#
# This helper deliberately uses only the existing vendor updateEngine command
# to select the other boot slot. It never writes, erases, or parses the misc
# partition itself. The state file lives in /userdata so it is visible to
# both firmware slots and survives a reboot.

set -u

STATE_DIR="${FIRMWARE_UPGRADE_STATE_DIR:-/userdata/.extended-firmware-upgrade}"
STATE_FILE="$STATE_DIR/state"
METADATA_FILE="${FIRMWARE_UPGRADE_METADATA_FILE:-$STATE_DIR/preflight-metadata}"
PIDFILE="${FIRMWARE_UPGRADE_PIDFILE:-/var/run/firmware-upgrade-health.pid}"
LOGFILE="${FIRMWARE_UPGRADE_LOG:-/var/log/firmware-upgrade-health.log}"
CMDLINE_FILE="${FIRMWARE_UPGRADE_CMDLINE_FILE:-/proc/cmdline}"
RUNTIME_ROOT="${FIRMWARE_UPGRADE_RUNTIME_ROOT:-}"
UPDATE_ENGINE="${FIRMWARE_UPGRADE_UPDATE_ENGINE:-updateEngine}"
MAX_CHECKS="${FIRMWARE_UPGRADE_MAX_CHECKS:-36}"
STABLE_CHECKS="${FIRMWARE_UPGRADE_STABLE_CHECKS:-3}"
POLL_INTERVAL="${FIRMWARE_UPGRADE_POLL_INTERVAL:-5}"
STALE_PENDING_SECONDS="${FIRMWARE_UPGRADE_STALE_PENDING_SECONDS:-900}"

runtime_path() {
    if [ -n "$RUNTIME_ROOT" ]; then
        printf '%s%s\n' "$RUNTIME_ROOT" "$1"
    else
        printf '%s\n' "$1"
    fi
}

now() {
    if [ -n "${FIRMWARE_UPGRADE_NOW:-}" ]; then
        printf '%s\n' "$FIRMWARE_UPGRADE_NOW"
    else
        date +%s
    fi
}

log() {
    message="$*"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >&2
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$LOGFILE" 2>/dev/null || true
}

read_value() {
    key="$1"
    [ -f "$STATE_FILE" ] || return 0
    sed -n "s/^${key}=//p" "$STATE_FILE" | tail -n 1
}

load_state() {
    state="$(read_value state)"
    source_slot="$(read_value source_slot)"
    active_slot="$(read_value active_slot)"
    candidate_sha256="$(read_value candidate_sha256)"
    candidate_file="$(read_value candidate_file)"
    candidate_commit="$(read_value candidate_commit)"
    candidate_upfile_version="$(read_value candidate_upfile_version)"
    started_at="$(read_value started_at)"
    health_started_at="$(read_value health_started_at)"
    health_attempts="$(read_value health_attempts)"
    verified_at="$(read_value verified_at)"
    failure_reason="$(read_value failure_reason)"
    rollback_attempted="$(read_value rollback_attempted)"
}

write_state() {
    mkdir -p "$STATE_DIR" || return 1
    old_umask="$(umask)"
    umask 077
    tmp_file="$STATE_FILE.tmp.$$"
    {
        printf 'state=%s\n' "${state:-}"
        printf 'source_slot=%s\n' "${source_slot:-}"
        printf 'active_slot=%s\n' "${active_slot:-}"
        printf 'candidate_sha256=%s\n' "${candidate_sha256:-}"
        printf 'candidate_file=%s\n' "${candidate_file:-}"
        printf 'candidate_commit=%s\n' "${candidate_commit:-}"
        printf 'candidate_upfile_version=%s\n' "${candidate_upfile_version:-}"
        printf 'started_at=%s\n' "${started_at:-}"
        printf 'health_started_at=%s\n' "${health_started_at:-}"
        printf 'health_attempts=%s\n' "${health_attempts:-0}"
        printf 'verified_at=%s\n' "${verified_at:-}"
        printf 'failure_reason=%s\n' "${failure_reason:-}"
        printf 'rollback_attempted=%s\n' "${rollback_attempted:-0}"
    } > "$tmp_file" && mv -f "$tmp_file" "$STATE_FILE"
    umask "$old_umask"
}

current_slot() {
    suffix="$(sed -n 's/.*androidboot\.slot_suffix=\(_[ab]\).*/\1/p' "$CMDLINE_FILE" 2>/dev/null | head -n 1)"
    case "$suffix" in
        _a) printf 'A\n' ;;
        _b) printf 'B\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

safe_reason() {
    printf '%s' "$*" | tr '[:space:]' '_' | tr -cd 'A-Za-z0-9_.:-'
}

set_health_started() {
    if [ -z "${health_started_at:-}" ]; then
        health_started_at="$(now)"
        health_attempts=0
        write_state || return 1
    fi
}

check_first_line_has_no_cr() {
    file="$1"
    [ -f "$file" ] || return 1
    first_line="$(head -n 1 "$file" 2>/dev/null || true)"
    clean_line="$(printf '%s' "$first_line" | tr -d '\r')"
    [ "$first_line" = "$clean_line" ]
}

check_runtime_files() {
    for relative in \
        /etc/FULLVERSION \
        /etc/BUILD_VERSION \
        /etc/BUILD_PROFILE \
        /etc/init.d/S49extended-config \
        /etc/init.d/S60klipper \
        /etc/init.d/S61moonraker \
        /usr/local/bin/extended-config.py \
        /usr/local/bin/firmware-config.py \
        /usr/local/bin/firmware-upgrade-health.sh; do
        file="$(runtime_path "$relative")"
        [ -s "$file" ] || return 1
    done

    for relative in \
        /etc/init.d/S49extended-config \
        /etc/init.d/S60klipper \
        /etc/init.d/S61moonraker \
        /usr/local/bin/extended-config.py \
        /usr/local/bin/firmware-config.py \
        /usr/local/bin/firmware-upgrade-health.sh; do
        check_first_line_has_no_cr "$(runtime_path "$relative")" || return 1
    done

    if [ -n "${candidate_commit:-}" ]; then
        build_version="$(tr -d '\r\n' < "$(runtime_path /etc/BUILD_VERSION)" 2>/dev/null || true)"
        case "$build_version" in
            *"$candidate_commit"*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

curl_command() {
    if [ -x "$(runtime_path /usr/local/bin/curl)" ]; then
        printf '%s\n' "$(runtime_path /usr/local/bin/curl)"
    elif command -v curl >/dev/null 2>&1; then
        command -v curl
    else
        return 1
    fi
}

check_core_services() {
    if [ "${FIRMWARE_UPGRADE_TEST_MODE:-0}" = 1 ]; then
        [ "${FIRMWARE_UPGRADE_TEST_RESULT:-fail}" = pass ]
        return $?
    fi

    curl_bin="$(curl_command 2>/dev/null || true)"
    [ -n "$curl_bin" ] || return 1

    server_info="$($curl_bin -fsS --max-time 5 http://127.0.0.1:7125/server/info 2>/dev/null)" || return 1
    printf '%s' "$server_info" | grep -Eq '"klippy_connected"[[:space:]]*:[[:space:]]*true' || return 1

    printer_info="$($curl_bin -fsS --max-time 5 http://127.0.0.1:7125/printer/info 2>/dev/null)" || return 1
    printf '%s' "$printer_info" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"ready"' || return 1

    config_file="$(runtime_path /home/lava/printer_data/config/extended/extended2.cfg)"
    config_helper="$(runtime_path /usr/local/bin/extended-config.py)"
    config_enabled="true"
    if [ -x "$config_helper" ] && [ -f "$config_file" ]; then
        config_enabled="$($config_helper get "$config_file" web firmware_config true 2>/dev/null || printf 'true')"
    fi
    if [ "$config_enabled" = true ]; then
        "$curl_bin" -fsS --max-time 5 http://127.0.0.1:9091/api/status >/dev/null 2>&1 || return 1
    fi
    return 0
}

check_candidate() {
    check_runtime_files || return 1
    check_core_services || return 1
    return 0
}

begin_upgrade() {
    firmware="$1"
    [ -f "$firmware" ] || {
        echo "ERROR: Firmware file does not exist: $firmware" >&2
        return 1
    }

    mkdir -p "$STATE_DIR" || return 1
    load_state
    current="$(current_slot)"
    case "$current" in
        A|B) ;;
        *)
            echo "ERROR: Could not determine the active firmware slot; upgrade was not started." >&2
            return 1
            ;;
    esac
    if [ "${state:-}" = pending ] && [ "${source_slot:-}" != "$current" ]; then
        echo "ERROR: An upgrade is already pending on slot $source_slot." >&2
        return 1
    fi
    if [ "${state:-}" = pending ] && [ -n "${started_at:-}" ]; then
        case "$started_at" in
            ''|*[!0-9]*) age=$((STALE_PENDING_SECONDS + 1)) ;;
            *) age=$(( $(now) - started_at )) ;;
        esac
        if [ "$age" -lt "$STALE_PENDING_SECONDS" ]; then
            echo "ERROR: An upgrade is already being verified; wait for reboot or recovery." >&2
            return 1
        fi
    fi

    state=pending
    source_slot="$current"
    active_slot="$current"
    candidate_file="$(basename "$firmware")"
    candidate_commit="$(sed -n 's/^candidate_commit=//p' "$METADATA_FILE" 2>/dev/null | tail -n 1)"
    candidate_upfile_version="$(sed -n 's/^candidate_upfile_version=//p' "$METADATA_FILE" 2>/dev/null | tail -n 1)"
    candidate_sha256=unavailable
    if command -v sha256sum >/dev/null 2>&1; then
        candidate_sha256="$(sha256sum "$firmware" 2>/dev/null | awk '{print $1}')"
        [ -n "$candidate_sha256" ] || candidate_sha256=unavailable
    fi
    started_at="$(now)"
    health_started_at=
    health_attempts=0
    verified_at=
    failure_reason=
    rollback_attempted=0
    write_state || return 1
    log "Upgrade marked pending: source=$source_slot candidate=$candidate_file sha256=$candidate_sha256"
}

mark_verified() {
    active_slot="$(current_slot)"
    state=verified
    verified_at="$(now)"
    failure_reason=
    write_state || return 1
    log "Upgrade verified successfully on slot $active_slot"
}

mark_not_switched() {
    state=not_switched
    active_slot="$(current_slot)"
    failure_reason="slot_did_not_change"
    write_state || return 1
    log "Upgrade was not verified: active slot remained $active_slot"
}

rollback_once() {
    active_slot="$(current_slot)"
    if [ "$active_slot" = unknown ] || [ "$source_slot" = unknown ] || [ "$active_slot" = "$source_slot" ]; then
        mark_not_switched
        return 0
    fi
    if [ "${rollback_attempted:-0}" = 1 ]; then
        state=rollback_failed
        failure_reason="rollback_already_attempted"
        write_state || true
        log "Rollback was already attempted; refusing to loop"
        return 1
    fi

    rollback_attempted=1
    state=rollback_requested
    failure_reason="$(safe_reason "${failure_reason:-health_check_failed}")"
    write_state || return 1
    sync
    log "Health check failed on slot $active_slot; requesting one vendor backup-slot reboot"

    if "$UPDATE_ENGINE" --misc=other --reboot >> "$LOGFILE" 2>&1; then
        return 0
    fi

    state=rollback_failed
    failure_reason="vendor_backup_switch_failed"
    write_state || true
    log "Vendor backup-slot request failed; leaving printer running for manual recovery"
    return 1
}

monitor() {
    [ -f "$STATE_FILE" ] || return 0
    load_state
    [ "${state:-}" = pending ] || return 0
    set_health_started || return 1

    stable=0
    attempt=0
    last_reason=health_check_failed
    while [ "$attempt" -lt "$MAX_CHECKS" ]; do
        attempt=$((attempt + 1))
        health_attempts="$attempt"
        active_slot="$(current_slot)"
        if [ "$active_slot" = "$source_slot" ]; then
            stable=0
            last_reason=slot_did_not_change
        elif [ "$active_slot" = unknown ]; then
            stable=0
            last_reason=active_slot_unknown
        elif check_candidate; then
            stable=$((stable + 1))
            last_reason=health_check_passed
            if [ "$stable" -ge "$STABLE_CHECKS" ]; then
                mark_verified
                return 0
            fi
        else
            stable=0
            last_reason=health_check_failed
        fi
        write_state || true
        if [ "$attempt" -lt "$MAX_CHECKS" ] && [ "$POLL_INTERVAL" -gt 0 ]; then
            sleep "$POLL_INTERVAL"
        fi
    done

    failure_reason="$last_reason"
    active_slot="$(current_slot)"
    if [ "$active_slot" = "$source_slot" ] || [ "$active_slot" = unknown ]; then
        mark_not_switched
        return 0
    fi
    rollback_once
}

status() {
    if [ ! -f "$STATE_FILE" ]; then
        printf 'idle\n'
        return 0
    fi
    load_state
    current="$(current_slot)"
    case "${state:-unknown}" in
        pending)
            printf 'pending: candidate=%s, version=%s, active=%s, source=%s, checks=%s\n' \
                "${candidate_file:-unknown}" "${candidate_upfile_version:-unknown}" \
                "$current" "${source_slot:-unknown}" "${health_attempts:-0}"
            ;;
    verified)
            printf 'verified: slot=%s, build=%s\n' "$current" "$(cat "$(runtime_path /etc/BUILD_VERSION)" 2>/dev/null || printf 'unknown')"
            ;;
        rollback_requested)
            printf 'rollback requested: failed slot=%s, backup=%s\n' "$current" "${source_slot:-unknown}"
            ;;
        rollback_failed)
            printf 'rollback failed: manual recovery required (active=%s)\n' "$current"
            ;;
        not_switched)
            printf 'not switched: updater did not select a new slot (active=%s)\n' "$current"
            ;;
        *)
            printf '%s: active=%s\n' "${state:-unknown}" "$current"
            ;;
    esac
}

start_monitor() {
    [ -f "$STATE_FILE" ] || return 0
    load_state
    [ "${state:-}" = pending ] || return 0
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$(dirname "$PIDFILE")" "$(dirname "$LOGFILE")" 2>/dev/null || true
    /bin/sh "$0" monitor >> "$LOGFILE" 2>&1 &
    printf '%s\n' "$!" > "$PIDFILE"
}

stop_monitor() {
    if [ -f "$PIDFILE" ]; then
        pid="$(cat "$PIDFILE" 2>/dev/null || true)"
        case "$pid" in
            ''|*[!0-9]*) ;;
            *) kill "$pid" 2>/dev/null || true ;;
        esac
        rm -f "$PIDFILE"
    fi
}

case "${1:-}" in
    begin)
        [ "$#" -eq 2 ] || { echo "Usage: $0 begin <firmware-file>" >&2; exit 2; }
        begin_upgrade "$2"
        ;;
    monitor)
        monitor
        ;;
    start)
        start_monitor
        ;;
    stop)
        stop_monitor
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {begin <firmware-file>|monitor|start|stop|status}" >&2
        exit 2
        ;;
esac
