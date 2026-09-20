#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

assert_in_order() {
  local file="$1"
  shift
  local previous_line=0 pattern line

  for pattern in "$@"; do
    line="$(grep -nE -- "$pattern" "$file" | head -n 1 | cut -d: -f1 || true)"
    if [[ -z "$line" ]]; then
      echo "Expected pattern '$pattern' in $file" >&2
      return 1
    fi
    if [[ "$line" -le "$previous_line" ]]; then
      echo "Upgrade safety steps are out of order in $file near '$pattern'" >&2
      return 1
    fi
    previous_line="$line"
  done
}

CONFIG_UPGRADE="$ROOT_DIR/overlays/firmware-extended/02-firmware-config/root/usr/local/share/firmware-config/functions/30_upgrade.yaml"
CHANNEL_UPGRADE="$ROOT_DIR/overlays/firmware-extended/40-feature-upgrade-firmware/root/usr/local/share/firmware-config/functions/18_firmware_upgrade.yaml"
DEV_UPGRADE="$ROOT_DIR/scripts/dev/upgrade-firmware.sh"

grep -Eq '^build:[[:space:]]+validate-build$' "$ROOT_DIR/Makefile" || {
  echo "The standard build target does not require full package validation." >&2
  exit 1
}
grep -Fq -- '--report "$(OUTPUT_FILE).validation.txt"' "$ROOT_DIR/Makefile" || {
  echo "The validated build does not produce its validation report." >&2
  exit 1
}

for workflow in "$ROOT_DIR"/.github/workflows/*; do
  [[ -f "$workflow" ]] || continue
  if grep -Fq 'make build' "$workflow" && \
      ! grep -Fq 'make test-validation' "$workflow"; then
    echo "Firmware build workflow is missing the validator self-test: $workflow" >&2
    exit 1
  fi
done

assert_in_order "$CONFIG_UPGRADE" \
  'firmware-upgrade-preflight\.sh /userdata/url_upgrade\.bin' \
  'firmware-upgrade-health\.sh begin /userdata/url_upgrade\.bin' \
  'systemUpgrade\.sh upgrade all /userdata/url_upgrade\.bin'
assert_in_order "$CONFIG_UPGRADE" \
  'firmware-upgrade-preflight\.sh "\$1"' \
  'firmware-upgrade-health\.sh begin "\$1"' \
  'systemUpgrade\.sh upgrade all "\$1"'
assert_in_order "$CHANNEL_UPGRADE" \
  'firmware-upgrade-preflight\.sh", BIN_FILE' \
  'firmware-upgrade-health\.sh", "begin", BIN_FILE' \
  'systemUpgrade\.sh", "upgrade", "all", BIN_FILE'
assert_in_order "$DEV_UPGRADE" \
  'make validate-build' \
  'sshpass .* scp' \
  'sshpass .* ssh' \
  'firmware-upgrade-preflight\.sh /userdata/firmware_upgrade\.bin' \
  'firmware-upgrade-health\.sh begin /userdata/firmware_upgrade\.bin' \
  'systemUpgrade\.sh upgrade all /userdata/firmware_upgrade\.bin'

echo "Firmware upgrade path guard tests passed."
