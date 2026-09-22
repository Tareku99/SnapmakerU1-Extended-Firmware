#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

# Prepare one firmware candidate for the vendor updater. This is the single
# path used by upload, URL, channel, and developer-triggered upgrades.
# It may replace a ZIP at the supplied path with its one contained .bin file,
# then runs the container preflight and records the pending health state.

set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <firmware-or-zip>" >&2
  exit 2
fi

firmware="$1"
if [ ! -f "$firmware" ]; then
  echo "ERROR: Firmware file does not exist: $firmware" >&2
  exit 1
fi

PREFLIGHT_BIN="${FIRMWARE_UPGRADE_PREFLIGHT_BIN:-/usr/local/bin/firmware-upgrade-preflight.sh}"
HEALTH_BIN="${FIRMWARE_UPGRADE_HEALTH_BIN:-/usr/local/bin/firmware-upgrade-health.sh}"
tmp_root="${FIRMWARE_UPGRADE_TMP_DIR:-/userdata/.tmp_upgrade}"
mkdir -p "$tmp_root"
zipdir="$(mktemp -d "$tmp_root/zip_unpack.XXXXXX")"
cleanup() {
  rm -rf "$zipdir"
}
trap cleanup EXIT HUP INT TERM

magic="$(head -c 2 "$firmware" 2>/dev/null || true)"
case "$magic" in
  PK)
    command -v unzip >/dev/null 2>&1 || {
      echo "ERROR: unzip is unavailable; cannot prepare firmware archive." >&2
      exit 1
    }
    echo "Detected .zip archive, extracting..."
    if ! unzip -q "$firmware" -d "$zipdir"; then
      echo "ERROR: Failed to extract firmware archive." >&2
      exit 1
    fi
    bin_count="$(find "$zipdir" -type f -iname '*.bin' -print | awk 'NF { count++ } END { print count + 0 }')"
    if [ "$bin_count" -ne 1 ]; then
      echo "ERROR: Expected exactly one .bin file in the archive; found $bin_count." >&2
      exit 1
    fi
    binfile="$(find "$zipdir" -type f -iname '*.bin' -print -quit)"
    replacement="$firmware.tmp.$$"
    cp "$binfile" "$replacement"
    mv -f "$replacement" "$firmware"
    echo "Extracted firmware from archive."
    ;;
esac

if ! "$PREFLIGHT_BIN" "$firmware"; then
  echo "ERROR: Firmware preflight failed; the upgrade was not started." >&2
  exit 1
fi

if ! /bin/sh "$HEALTH_BIN" begin "$firmware"; then
  echo "ERROR: Could not record the pending upgrade; the upgrade was not started." >&2
  exit 1
fi

echo "Firmware candidate prepared for upgrade."
