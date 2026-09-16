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
        "$root/etc/init.d/S60klipper" \
        "$root/etc/init.d/S61moonraker" \
        "$root/usr/local/bin/extended-config.py" \
        "$root/usr/local/bin/firmware-config.py" \
        "$root/usr/local/bin/firmware-upgrade-health.sh"; do
        printf '#!/bin/sh\n' > "$file"
    done
    mkdir -p "$root/state"
    printf 'candidate_commit=abc1234\n' > "$root/state/preflight-metadata"
    printf 'androidboot.slot_suffix=_a\n' > "$root/cmdline"
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
printf 'androidboot.slot_suffix=_b\n' > "$PASS_ROOT/cmdline"
run_helper "$PASS_ROOT" monitor
assert_file_contains "$PASS_ROOT/state/state" '^state=verified$'

ROLLBACK_ROOT="$TEST_DIR/rollback"
make_runtime "$ROLLBACK_ROOT"
printf 'candidate\n' > "$ROLLBACK_ROOT/candidate.bin"
printf 'candidate-build-wrong-commit\n' > "$ROLLBACK_ROOT/etc/BUILD_VERSION"
cat > "$ROLLBACK_ROOT/updateEngine" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "${FIRMWARE_UPGRADE_TEST_ENGINE_LOG}"
EOF
chmod +x "$ROLLBACK_ROOT/updateEngine"
export FIRMWARE_UPGRADE_TEST_ENGINE_LOG="$ROLLBACK_ROOT/engine.log"
run_helper "$ROLLBACK_ROOT" begin "$ROLLBACK_ROOT/candidate.bin"
printf 'androidboot.slot_suffix=_b\n' > "$ROLLBACK_ROOT/cmdline"
FIRMWARE_UPGRADE_TEST_RESULT=fail FIRMWARE_UPGRADE_MAX_CHECKS=1 run_helper "$ROLLBACK_ROOT" monitor
assert_file_contains "$ROLLBACK_ROOT/state/state" '^state=rollback_requested$'
assert_file_contains "$ROLLBACK_ROOT/engine.log" '^--misc=other --reboot$'

NOT_SWITCHED_ROOT="$TEST_DIR/not-switched"
make_runtime "$NOT_SWITCHED_ROOT"
printf 'candidate\n' > "$NOT_SWITCHED_ROOT/candidate.bin"
run_helper "$NOT_SWITCHED_ROOT" begin "$NOT_SWITCHED_ROOT/candidate.bin"
FIRMWARE_UPGRADE_TEST_RESULT=fail FIRMWARE_UPGRADE_MAX_CHECKS=1 run_helper "$NOT_SWITCHED_ROOT" monitor
assert_file_contains "$NOT_SWITCHED_ROOT/state/state" '^state=not_switched$'

echo "Firmware upgrade health-gate tests passed."
