#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT_DIR/overlays/firmware-extended/02-firmware-config/root/usr/local/bin/firmware-upgrade-health.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    grep -Eq "$pattern" "$file" || {
        echo "Expected '$pattern' in $file" >&2
        cat "$file" >&2 || true
        exit 1
    }
}

make_runtime() {
    local root="$1"
    mkdir -p "$root/etc/init.d" "$root/usr/local/bin" "$root/home/lava/printer_data/config/extended"
    printf '1.6.0\n' > "$root/etc/FULLVERSION"
    printf 'candidate-build-abc1234\n' > "$root/etc/BUILD_VERSION"
    printf 'extended\n' > "$root/etc/BUILD_PROFILE"
    for file in \
        "$root/etc/init.d/S49extended-config" \
        "$root/etc/init.d/S05firmware-upgrade-health" \
        "$root/etc/init.d/S60klipper" \
        "$root/etc/init.d/S61moonraker" \
        "$root/usr/local/bin/extended-config.py" \
        "$root/usr/local/bin/firmware-config.py" \
        "$root/usr/local/bin/firmware-upgrade-health.sh"; do
        printf '#!/bin/sh\n' > "$file"
    done
    mkdir -p "$root/state"
    printf 'candidate_commit=abc1234\n' > "$root/state/preflight-metadata"
    # The real U1 bootloader uses this historical spelling.
    printf 'android_slotsufix=_a\n' > "$root/cmdline"
}

run_helper() {
    env \
        FIRMWARE_UPGRADE_STATE_DIR="$1/state" \
        FIRMWARE_UPGRADE_METADATA_FILE="$1/state/preflight-metadata" \
        FIRMWARE_UPGRADE_CMDLINE_FILE="$1/cmdline" \
        FIRMWARE_UPGRADE_RUNTIME_ROOT="$1" \
        FIRMWARE_UPGRADE_PIDFILE="$1/pid" \
        FIRMWARE_UPGRADE_LOG="$1/health.log" \
        FIRMWARE_UPGRADE_MAX_CHECKS="${FIRMWARE_UPGRADE_MAX_CHECKS:-1}" \
        FIRMWARE_UPGRADE_STABLE_CHECKS="${FIRMWARE_UPGRADE_STABLE_CHECKS:-1}" \
        FIRMWARE_UPGRADE_POLL_INTERVAL=0 \
        FIRMWARE_UPGRADE_TEST_MODE=1 \
        FIRMWARE_UPGRADE_TEST_RESULT="${FIRMWARE_UPGRADE_TEST_RESULT:-pass}" \
        FIRMWARE_UPGRADE_UPDATE_ENGINE="$1/updateEngine" \
        /bin/sh "$HELPER" "$2" "${3:-}"
}

PASS_ROOT="$TEST_DIR/pass"
make_runtime "$PASS_ROOT"
printf 'candidate\n' > "$PASS_ROOT/candidate.bin"
run_helper "$PASS_ROOT" begin "$PASS_ROOT/candidate.bin"
printf 'another-candidate\n' > "$PASS_ROOT/second.bin"
if run_helper "$PASS_ROOT" begin "$PASS_ROOT/second.bin" > "$PASS_ROOT/pending.log" 2>&1; then
    echo "Health gate accepted a second upgrade while the first was pending." >&2
    exit 1
fi
assert_file_contains "$PASS_ROOT/pending.log" 'still being verified'
printf 'androidboot.slot_suffix=_b\n' > "$PASS_ROOT/cmdline"
FIRMWARE_UPGRADE_STABLE_CHECKS=3 FIRMWARE_UPGRADE_MAX_CHECKS=3 \
    run_helper "$PASS_ROOT" monitor
assert_file_contains "$PASS_ROOT/state/state" '^state=verified$'
assert_file_contains "$PASS_ROOT/state/state" '^health_attempts=3$'

STATE_WRITE_FAILURE_ROOT="$TEST_DIR/state-write-failure"
make_runtime "$STATE_WRITE_FAILURE_ROOT"
printf 'candidate\n' > "$STATE_WRITE_FAILURE_ROOT/candidate.bin"
mkdir -p "$STATE_WRITE_FAILURE_ROOT/fail-bin"
printf '#!/bin/sh\nexit 1\n' > "$STATE_WRITE_FAILURE_ROOT/fail-bin/mv"
chmod +x "$STATE_WRITE_FAILURE_ROOT/fail-bin/mv"
if PATH="$STATE_WRITE_FAILURE_ROOT/fail-bin:$PATH" \
    run_helper "$STATE_WRITE_FAILURE_ROOT" begin \
    "$STATE_WRITE_FAILURE_ROOT/candidate.bin" \
    > "$STATE_WRITE_FAILURE_ROOT/begin.log" 2>&1; then
    echo "Health gate accepted an upgrade after its pending-state write failed." >&2
    exit 1
fi
[[ ! -e "$STATE_WRITE_FAILURE_ROOT/state/state" ]] || {
    echo "Health gate left a pending state after the atomic state rename failed." >&2
    exit 1
}
[[ -z "$(find "$STATE_WRITE_FAILURE_ROOT/state" -maxdepth 1 \
    -name 'state.tmp.*' -print -quit)" ]] || {
    echo "Health gate left a temporary state file after the write failed." >&2
    exit 1
}

SYNC_FAILURE_ROOT="$TEST_DIR/sync-failure"
make_runtime "$SYNC_FAILURE_ROOT"
printf 'candidate\n' > "$SYNC_FAILURE_ROOT/candidate.bin"
mkdir -p "$SYNC_FAILURE_ROOT/fail-bin"
printf '#!/bin/sh\nexit 1\n' > "$SYNC_FAILURE_ROOT/fail-bin/sync"
chmod +x "$SYNC_FAILURE_ROOT/fail-bin/sync"
if PATH="$SYNC_FAILURE_ROOT/fail-bin:$PATH" \
    run_helper "$SYNC_FAILURE_ROOT" begin \
    "$SYNC_FAILURE_ROOT/candidate.bin" \
    > "$SYNC_FAILURE_ROOT/begin.log" 2>&1; then
    echo "Health gate accepted an upgrade after flushing its pending record failed." >&2
    exit 1
fi
assert_file_contains "$SYNC_FAILURE_ROOT/begin.log" \
    'Could not flush the pending upgrade record'
assert_file_contains "$SYNC_FAILURE_ROOT/state/state" '^state=pending$'

STALE_PENDING_ROOT="$TEST_DIR/stale-pending"
make_runtime "$STALE_PENDING_ROOT"
printf 'candidate\n' > "$STALE_PENDING_ROOT/candidate.bin"
FIRMWARE_UPGRADE_NOW=1000 \
    run_helper "$STALE_PENDING_ROOT" begin "$STALE_PENDING_ROOT/candidate.bin"
printf 'androidboot.slot_suffix=_b\n' > "$STALE_PENDING_ROOT/cmdline"
if FIRMWARE_UPGRADE_NOW=1900 \
    run_helper "$STALE_PENDING_ROOT" begin "$STALE_PENDING_ROOT/candidate.bin" \
    > "$STALE_PENDING_ROOT/recent.log" 2>&1; then
    echo "Health gate replaced a pending upgrade without an explicit reset." >&2
    exit 1
fi
assert_file_contains "$STALE_PENDING_ROOT/recent.log" 'reset the safety state'
run_helper "$STALE_PENDING_ROOT" reset
assert_file_contains "$STALE_PENDING_ROOT/state/state" '^state=reset$'
FIRMWARE_UPGRADE_NOW=1900 \
    run_helper "$STALE_PENDING_ROOT" begin "$STALE_PENDING_ROOT/candidate.bin"
assert_file_contains "$STALE_PENDING_ROOT/state/state" '^state=pending$'
assert_file_contains "$STALE_PENDING_ROOT/state/state" '^source_slot=B$'

UNMONITORED_ROOT="$TEST_DIR/unmonitored"
make_runtime "$UNMONITORED_ROOT"
: > "$UNMONITORED_ROOT/state/preflight-metadata"
printf 'stock-candidate\n' > "$UNMONITORED_ROOT/candidate.bin"
run_helper "$UNMONITORED_ROOT" begin "$UNMONITORED_ROOT/candidate.bin"
assert_file_contains "$UNMONITORED_ROOT/state/state" '^state=not_monitored$'
assert_file_contains "$UNMONITORED_ROOT/state/state" '^failure_reason=build_commit_missing$'
printf 'androidboot.slot_suffix=_b\n' > "$UNMONITORED_ROOT/cmdline"
run_helper "$UNMONITORED_ROOT" monitor
assert_file_contains "$UNMONITORED_ROOT/state/state" '^state=not_monitored$'
run_helper "$UNMONITORED_ROOT" status > "$UNMONITORED_ROOT/status.log"
assert_file_contains "$UNMONITORED_ROOT/status.log" 'not monitored'
run_helper "$UNMONITORED_ROOT" begin "$UNMONITORED_ROOT/candidate.bin"

STANDARD_MARKER_ROOT="$TEST_DIR/standard-marker"
make_runtime "$STANDARD_MARKER_ROOT"
printf 'androidboot.slot_suffix=_a\n' > "$STANDARD_MARKER_ROOT/cmdline"
printf 'candidate\n' > "$STANDARD_MARKER_ROOT/candidate.bin"
run_helper "$STANDARD_MARKER_ROOT" begin "$STANDARD_MARKER_ROOT/candidate.bin"
assert_file_contains "$STANDARD_MARKER_ROOT/state/state" '^source_slot=A$'

ROLLBACK_ROOT="$TEST_DIR/rollback"
make_runtime "$ROLLBACK_ROOT"
printf 'candidate\n' > "$ROLLBACK_ROOT/candidate.bin"
printf 'candidate-build-wrong-commit\n' > "$ROLLBACK_ROOT/etc/BUILD_VERSION"
cat > "$ROLLBACK_ROOT/updateEngine" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FIRMWARE_UPGRADE_TEST_ENGINE_LOG"
EOF
chmod +x "$ROLLBACK_ROOT/updateEngine"
export FIRMWARE_UPGRADE_TEST_ENGINE_LOG="$ROLLBACK_ROOT/engine.log"
run_helper "$ROLLBACK_ROOT" begin "$ROLLBACK_ROOT/candidate.bin"
printf 'androidboot.slot_suffix=_b\n' > "$ROLLBACK_ROOT/cmdline"
FIRMWARE_UPGRADE_TEST_RESULT=pass FIRMWARE_UPGRADE_MAX_CHECKS=1 run_helper "$ROLLBACK_ROOT" monitor
assert_file_contains "$ROLLBACK_ROOT/state/state" '^state=rollback_requested$'
assert_file_contains "$ROLLBACK_ROOT/engine.log" '^--misc=other --reboot$'
run_helper "$ROLLBACK_ROOT" monitor
[[ "$(wc -l < "$ROLLBACK_ROOT/engine.log")" -eq 1 ]] || {
    echo "Health gate requested the backup-slot rollback more than once." >&2
    exit 1
}

SERVICE_FAILURE_ROOT="$TEST_DIR/service-failure"
make_runtime "$SERVICE_FAILURE_ROOT"
printf 'candidate\n' > "$SERVICE_FAILURE_ROOT/candidate.bin"
cp "$ROLLBACK_ROOT/updateEngine" "$SERVICE_FAILURE_ROOT/updateEngine"
export FIRMWARE_UPGRADE_TEST_ENGINE_LOG="$SERVICE_FAILURE_ROOT/engine.log"
run_helper "$SERVICE_FAILURE_ROOT" begin "$SERVICE_FAILURE_ROOT/candidate.bin"
printf 'androidboot.slot_suffix=_b\n' > "$SERVICE_FAILURE_ROOT/cmdline"
FIRMWARE_UPGRADE_TEST_RESULT=fail FIRMWARE_UPGRADE_MAX_CHECKS=1 \
    run_helper "$SERVICE_FAILURE_ROOT" monitor
assert_file_contains "$SERVICE_FAILURE_ROOT/state/state" '^state=rollback_requested$'
assert_file_contains "$SERVICE_FAILURE_ROOT/engine.log" '^--misc=other --reboot$'

ROLLBACK_FAILURE_ROOT="$TEST_DIR/rollback-failure"
make_runtime "$ROLLBACK_FAILURE_ROOT"
printf 'candidate\n' > "$ROLLBACK_FAILURE_ROOT/candidate.bin"
cp "$ROLLBACK_ROOT/updateEngine" "$ROLLBACK_FAILURE_ROOT/updateEngine"
printf 'exit 1\n' >> "$ROLLBACK_FAILURE_ROOT/updateEngine"
export FIRMWARE_UPGRADE_TEST_ENGINE_LOG="$ROLLBACK_FAILURE_ROOT/engine.log"
run_helper "$ROLLBACK_FAILURE_ROOT" begin "$ROLLBACK_FAILURE_ROOT/candidate.bin"
printf 'androidboot.slot_suffix=_b\n' > "$ROLLBACK_FAILURE_ROOT/cmdline"
if FIRMWARE_UPGRADE_TEST_RESULT=fail FIRMWARE_UPGRADE_MAX_CHECKS=1 \
    run_helper "$ROLLBACK_FAILURE_ROOT" monitor; then
    echo "Health gate reported success after the vendor rollback request failed." >&2
    exit 1
fi
assert_file_contains "$ROLLBACK_FAILURE_ROOT/state/state" '^state=rollback_failed$'
assert_file_contains "$ROLLBACK_FAILURE_ROOT/state/state" \
    '^failure_reason=vendor_backup_switch_failed$'

UNKNOWN_SLOT_ROOT="$TEST_DIR/unknown-slot"
make_runtime "$UNKNOWN_SLOT_ROOT"
printf 'candidate\n' > "$UNKNOWN_SLOT_ROOT/candidate.bin"
printf 'androidboot.slot_suffix=_c\n' > "$UNKNOWN_SLOT_ROOT/cmdline"
if run_helper "$UNKNOWN_SLOT_ROOT" begin "$UNKNOWN_SLOT_ROOT/candidate.bin" \
    > "$UNKNOWN_SLOT_ROOT/begin.log" 2>&1; then
    echo "Health gate accepted an upgrade without a recognized active slot." >&2
    exit 1
fi
assert_file_contains "$UNKNOWN_SLOT_ROOT/begin.log" 'Could not determine the active firmware slot'
[[ ! -f "$UNKNOWN_SLOT_ROOT/state/state" ]] || {
    echo "Health gate persisted a pending upgrade with an unknown active slot." >&2
    exit 1
}

CONFLICTING_SLOT_ROOT="$TEST_DIR/conflicting-slot"
make_runtime "$CONFLICTING_SLOT_ROOT"
printf 'candidate\n' > "$CONFLICTING_SLOT_ROOT/candidate.bin"
printf 'androidboot.slot_suffix=_b android_slotsufix=_a\n' > \
    "$CONFLICTING_SLOT_ROOT/cmdline"
if run_helper "$CONFLICTING_SLOT_ROOT" begin \
    "$CONFLICTING_SLOT_ROOT/candidate.bin" > \
    "$CONFLICTING_SLOT_ROOT/begin.log" 2>&1; then
    echo "Health gate accepted conflicting active-slot markers." >&2
    exit 1
fi
assert_file_contains "$CONFLICTING_SLOT_ROOT/begin.log" \
    'Could not determine the active firmware slot'
[[ ! -f "$CONFLICTING_SLOT_ROOT/state/state" ]] || {
    echo "Health gate persisted a pending upgrade with conflicting slot markers." >&2
    exit 1
}

NOT_SWITCHED_ROOT="$TEST_DIR/not-switched"
make_runtime "$NOT_SWITCHED_ROOT"
printf 'candidate\n' > "$NOT_SWITCHED_ROOT/candidate.bin"
cp "$ROLLBACK_ROOT/updateEngine" "$NOT_SWITCHED_ROOT/updateEngine"
export FIRMWARE_UPGRADE_TEST_ENGINE_LOG="$NOT_SWITCHED_ROOT/engine.log"
run_helper "$NOT_SWITCHED_ROOT" begin "$NOT_SWITCHED_ROOT/candidate.bin"
FIRMWARE_UPGRADE_TEST_RESULT=fail FIRMWARE_UPGRADE_MAX_CHECKS=1 run_helper "$NOT_SWITCHED_ROOT" monitor
assert_file_contains "$NOT_SWITCHED_ROOT/state/state" '^state=not_switched$'
[[ ! -f "$NOT_SWITCHED_ROOT/engine.log" ]] || {
    echo "Health gate requested rollback even though the active slot did not change." >&2
    exit 1
}

echo "Firmware upgrade health-gate tests passed."
