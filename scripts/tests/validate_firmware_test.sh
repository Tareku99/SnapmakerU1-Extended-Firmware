#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

set -euo pipefail

# Keep CI failures actionable without publishing fixture contents or environment data.
trap 'status=$?; echo "::error title=Validator self-test assertion failed::validate_firmware_test.sh line ${LINENO} (exit ${status})"; exit "$status"' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../validate_firmware.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/u1-validator-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

make_rootfs() {
  local rootfs="$1"
  mkdir -p \
    "$rootfs/bin" \
    "$rootfs/usr/bin" \
    "$rootfs/usr/local/bin" \
    "$rootfs/etc/init.d"

  printf '#!/bin/sh\nexit 0\n' > "$rootfs/bin/sh"
  printf '#!/bin/sh\nexit 0\n' > "$rootfs/usr/bin/env"
  printf '#!/bin/sh\nexit 0\n' > "$rootfs/usr/bin/python3"
  chmod +x "$rootfs/bin/sh" "$rootfs/usr/bin/env" "$rootfs/usr/bin/python3"

  printf '#!/bin/sh\nexit 0\n' > "$rootfs/etc/init.d/rcS"
  printf '#!/bin/sh\nexit 0\n' > "$rootfs/etc/init.d/S05firmware-upgrade-health"
  printf '#!/bin/sh\nexit 0\n' > "$rootfs/etc/init.d/S49extended-config"
  printf '#!/bin/sh\nexit 0\n' > "$rootfs/etc/init.d/S90lmd"
  chmod +x \
    "$rootfs/etc/init.d/rcS" \
    "$rootfs/etc/init.d/S05firmware-upgrade-health" \
    "$rootfs/etc/init.d/S49extended-config" \
    "$rootfs/etc/init.d/S90lmd"

  printf '#!/usr/bin/env python3\nprint("validator fixture")\n' \
    > "$rootfs/usr/local/bin/extended-config.py"
  chmod +x "$rootfs/usr/local/bin/extended-config.py"

  printf '#!/bin/sh\nexit 0\n' \
    > "$rootfs/usr/local/bin/firmware-upgrade-health.sh"
  chmod +x "$rootfs/usr/local/bin/firmware-upgrade-health.sh"
  printf '#!/usr/bin/env python3\npass\n' \
    > "$rootfs/usr/local/bin/firmware-upgrade-preflight.py"
  printf '#!/bin/sh\nexit 0\n' \
    > "$rootfs/usr/local/bin/firmware-upgrade-preflight.sh"
  chmod +x "$rootfs/usr/local/bin/firmware-upgrade-preflight.sh"

  printf '1.0.0-test\n' > "$rootfs/etc/FULLVERSION"
  printf 'test-build\n' > "$rootfs/etc/BUILD_VERSION"
  printf 'test-profile\n' > "$rootfs/etc/BUILD_PROFILE"
}

good_rootfs="$TEST_ROOT/good-rootfs"
make_rootfs "$good_rootfs"
bash "$VALIDATOR" \
  --rootfs "$good_rootfs" \
  --profile test-profile \
  --report "$TEST_ROOT/good-report.txt" \
  > "$TEST_ROOT/good.log"
grep -q "VALIDATION PASSED" "$TEST_ROOT/good.log"
grep -q "VALIDATION PASSED" "$TEST_ROOT/good-report.txt"

bad_rootfs="$TEST_ROOT/bad-rootfs"
cp -a "$good_rootfs" "$bad_rootfs"
printf '#!/bin/sh\r\nexit 0\r\n' > "$bad_rootfs/etc/init.d/S49extended-config"

if bash "$VALIDATOR" --rootfs "$bad_rootfs" > "$TEST_ROOT/bad.log" 2>&1; then
  echo "Validator accepted a CRLF init script." >&2
  exit 1
fi
grep -q "CRLF" "$TEST_ROOT/bad.log"

missing_interpreter_rootfs="$TEST_ROOT/missing-interpreter-rootfs"
cp -a "$good_rootfs" "$missing_interpreter_rootfs"
printf '#!/usr/bin/env definitely-missing-python\nprint("fixture")\n' \
  > "$missing_interpreter_rootfs/usr/local/bin/extended-config.py"
if bash "$VALIDATOR" --rootfs "$missing_interpreter_rootfs" > "$TEST_ROOT/missing.log" 2>&1; then
  echo "Validator accepted a missing shebang interpreter." >&2
  exit 1
fi
grep -q "env program is missing" "$TEST_ROOT/missing.log"

non_executable_rootfs="$TEST_ROOT/non-executable-rootfs"
cp -a "$good_rootfs" "$non_executable_rootfs"
chmod -x "$non_executable_rootfs/etc/init.d/S49extended-config"
if bash "$VALIDATOR" --rootfs "$non_executable_rootfs" > "$TEST_ROOT/mode.log" 2>&1; then
  echo "Validator accepted a non-executable init script." >&2
  exit 1
fi
grep -q "not executable" "$TEST_ROOT/mode.log"

non_executable_preflight_rootfs="$TEST_ROOT/non-executable-preflight-rootfs"
cp -a "$good_rootfs" "$non_executable_preflight_rootfs"
chmod -x \
  "$non_executable_preflight_rootfs/usr/local/bin/firmware-upgrade-preflight.sh"
if bash "$VALIDATOR" --rootfs "$non_executable_preflight_rootfs" \
    > "$TEST_ROOT/preflight-mode.log" 2>&1; then
  echo "Validator accepted a non-executable firmware preflight helper." >&2
  exit 1
fi
grep -q "usr/local/bin/firmware-upgrade-preflight.sh" "$TEST_ROOT/preflight-mode.log"
grep -q "not executable" "$TEST_ROOT/preflight-mode.log"

crlf_runtime_rootfs="$TEST_ROOT/crlf-runtime-rootfs"
cp -a "$good_rootfs" "$crlf_runtime_rootfs"
printf '#!/bin/sh\r\nexit 0\r\n' \
  > "$crlf_runtime_rootfs/etc/init.d/S49extended-config"
if bash "$VALIDATOR" --rootfs "$crlf_runtime_rootfs" \
    > "$TEST_ROOT/crlf-runtime.log" 2>&1; then
  echo "Validator accepted CRLF line endings in a runtime init script." >&2
  exit 1
fi
grep -q "S49extended-config contains CRLF or mixed line endings" \
  "$TEST_ROOT/crlf-runtime.log"

missing_preflight_parser_rootfs="$TEST_ROOT/missing-preflight-parser-rootfs"
cp -a "$good_rootfs" "$missing_preflight_parser_rootfs"
rm "$missing_preflight_parser_rootfs/usr/local/bin/firmware-upgrade-preflight.py"
if bash "$VALIDATOR" --rootfs "$missing_preflight_parser_rootfs" \
    > "$TEST_ROOT/preflight-parser.log" 2>&1; then
  echo "Validator accepted a rootfs missing the firmware container parser." >&2
  exit 1
fi
grep -q "usr/local/bin/firmware-upgrade-preflight.py" \
  "$TEST_ROOT/preflight-parser.log"

echo "Firmware validator self-test passed."
