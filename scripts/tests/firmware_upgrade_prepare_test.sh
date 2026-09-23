#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT_DIR/overlays/firmware-extended/02-firmware-config/root/usr/local/bin/firmware-upgrade-prepare.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

PREFLIGHT="$TEST_DIR/preflight.sh"
HEALTH="$TEST_DIR/health.sh"
CALLS="$TEST_DIR/calls"

cat > "$PREFLIGHT" <<'EOF'
#!/bin/sh
printf 'preflight:%s\n' "$1" >> "$FIRMWARE_UPGRADE_TEST_CALLS"
exit 0
EOF
cat > "$HEALTH" <<'EOF'
#!/bin/sh
printf 'health:%s:%s\n' "$1" "$2" >> "$FIRMWARE_UPGRADE_TEST_CALLS"
exit 0
EOF
chmod +x "$PREFLIGHT" "$HEALTH"

run_prepare() {
    FIRMWARE_UPGRADE_TMP_DIR="$TEST_DIR/tmp" \
    FIRMWARE_UPGRADE_PREFLIGHT_BIN="$PREFLIGHT" \
    FIRMWARE_UPGRADE_HEALTH_BIN="$HEALTH" \
    FIRMWARE_UPGRADE_TEST_CALLS="$CALLS" \
    /bin/sh "$HELPER" "$1"
}

printf 'single firmware payload\n' > "$TEST_DIR/single.bin"
run_prepare "$TEST_DIR/single.bin"
grep -Fq "preflight:$TEST_DIR/single.bin" "$CALLS"
grep -Fq "health:begin:$TEST_DIR/single.bin" "$CALLS"

HEALTH_FAIL="$TEST_DIR/health-fail.sh"
cat > "$HEALTH_FAIL" <<'EOF'
#!/bin/sh
printf 'health-failed:%s:%s\n' "$1" "$2" >> "$FIRMWARE_UPGRADE_TEST_CALLS"
exit 1
EOF
chmod +x "$HEALTH_FAIL"
if ! HEALTH="$HEALTH_FAIL" run_prepare "$TEST_DIR/single.bin" \
    > "$TEST_DIR/health-failure.log" 2>&1; then
    echo "Optional health-state preparation blocked a valid firmware candidate." >&2
    exit 1
fi
grep -Fq "WARNING: Post-boot health monitoring could not be prepared" \
    "$TEST_DIR/health-failure.log"

printf 'zip firmware payload\n' > "$TEST_DIR/one.bin"
python3 - "$TEST_DIR/one.zip" "$TEST_DIR/one.bin" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.write(sys.argv[2], "one.bin")
PY
run_prepare "$TEST_DIR/one.zip"
cmp "$TEST_DIR/one.zip" <(printf 'zip firmware payload\n')

printf 'first\n' > "$TEST_DIR/first.bin"
printf 'second\n' > "$TEST_DIR/second.bin"
python3 - "$TEST_DIR/two.zip" "$TEST_DIR/first.bin" "$TEST_DIR/second.bin" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.write(sys.argv[2], "first.bin")
    archive.write(sys.argv[3], "second.bin")
PY
if run_prepare "$TEST_DIR/two.zip" > "$TEST_DIR/two.log" 2>&1; then
    echo "Preparation accepted an archive containing multiple firmware files." >&2
    exit 1
fi
grep -Fq "Expected exactly one .bin" "$TEST_DIR/two.log"

echo "Firmware upgrade preparation tests passed."
