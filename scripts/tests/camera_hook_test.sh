#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
HOOK_SOURCE="$SCRIPT_DIR/../../overlays/firmware-extended/60-app-camera/root/etc/hooks/lmd.d/20-camera-selection.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/u1-camera-hook-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

make_case() {
  local name="$1"
  local result="$2"
  local case_dir="$TEST_ROOT/$name"
  local helper="$case_dir/extended-config.py"
  local hook="$case_dir/20-camera-selection.sh"

  mkdir -p "$case_dir"
  printf '#!/bin/sh\n%s\n' "$result" > "$helper"
  chmod +x "$helper"
  sed "s|/usr/local/bin/extended-config.py|$helper|g" \
    "$HOOK_SOURCE" > "$hook"
  printf '%s\n' "$hook"
}

run_hook() {
  local hook="$1"
  env -u LD_PRELOAD sh -c 'hook="$1"; shift; . "$hook" "$@"' sh "$hook" start
}

sh -n "$HOOK_SOURCE"

snapmaker_hook="$(make_case snapmaker 'printf "snapmaker\\n"')"
if ! snapmaker_output="$(run_hook "$snapmaker_hook" 2>&1)"; then
  echo "Camera hook failed in the normal Snapmaker mode." >&2
  exit 1
fi
if [[ -n "$snapmaker_output" ]]; then
  echo "Camera hook produced unexpected output in Snapmaker mode: $snapmaker_output" >&2
  exit 1
fi

paxx12_hook="$(make_case paxx12 'printf "paxx12\\n"')"
paxx12_output="$(run_hook "$paxx12_hook" 2>&1)"
grep -q "Starting lmd in v4l2-imposter mode" <<<"$paxx12_output"

none_hook="$(make_case none 'printf "none\\n"')"
none_output="$(run_hook "$none_hook" 2>&1)"
grep -q "Internal camera is disabled" <<<"$none_output"

failure_hook="$(make_case helper-failure 'exit 1')"
failure_output="$(run_hook "$failure_hook" 2>&1)"
grep -q "Failed to read the internal camera setting" <<<"$failure_output"

empty_hook="$(make_case helper-empty 'printf "\\n"')"
empty_output="$(run_hook "$empty_hook" 2>&1)"
grep -q "setting is empty" <<<"$empty_output"

unknown_hook="$(make_case unknown 'printf "unexpected-value\\n"')"
unknown_output="$(run_hook "$unknown_hook" 2>&1)"
grep -q "Unknown internal camera setting" <<<"$unknown_output"

echo "Camera hook regression tests passed."
