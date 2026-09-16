#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

assert_upgrade_is_guarded() {
  local file="$1"
  local upgrade_line preflight_line health_line

  upgrade_line="$(grep -n 'systemUpgrade\.sh.*upgrade.*all' "$file" | tail -n 1 | cut -d: -f1)"
  preflight_line="$(grep -n 'firmware-upgrade-preflight\.sh' "$file" | tail -n 1 | cut -d: -f1)"
  health_line="$(grep -n 'firmware-upgrade-health\.sh.*begin' "$file" | tail -n 1 | cut -d: -f1)"

  [[ -n "$upgrade_line" ]] || { echo "No full-image upgrade call found in $file" >&2; return 1; }
  [[ -n "$preflight_line" && "$preflight_line" -lt "$upgrade_line" ]] || {
    echo "Preflight does not guard the upgrade call in $file" >&2
    return 1
  }
  [[ -n "$health_line" && "$health_line" -lt "$upgrade_line" ]] || {
    echo "Post-boot health marker does not guard the upgrade call in $file" >&2
    return 1
  }
}

assert_upgrade_is_guarded \
  "$ROOT_DIR/overlays/firmware-extended/02-firmware-config/root/usr/local/share/firmware-config/functions/30_upgrade.yaml"
assert_upgrade_is_guarded \
  "$ROOT_DIR/overlays/firmware-extended/40-feature-upgrade-firmware/root/usr/local/share/firmware-config/functions/18_firmware_upgrade.yaml"

grep -q 'make validate-build' "$ROOT_DIR/scripts/dev/upgrade-firmware.sh"
grep -q 'firmware-upgrade-preflight\.sh /userdata/firmware_upgrade\.bin' \
  "$ROOT_DIR/scripts/dev/upgrade-firmware.sh"
grep -q 'firmware-upgrade-health\.sh begin /userdata/firmware_upgrade\.bin' \
  "$ROOT_DIR/scripts/dev/upgrade-firmware.sh"
grep -q 'systemUpgrade\.sh upgrade all /userdata/firmware_upgrade\.bin' \
  "$ROOT_DIR/scripts/dev/upgrade-firmware.sh"

echo "Firmware upgrade path guard tests passed."
