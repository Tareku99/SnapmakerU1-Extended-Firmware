#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

# Validate the outer upgrade container before handing it to the device updater.
# It checks container integrity without executing anything from the candidate
# firmware; it is not a cryptographic signature check.

set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <upgrade.bin>" >&2
  exit 2
fi

firmware="$1"
if [ ! -f "$firmware" ]; then
  echo "ERROR: Firmware file does not exist: $firmware" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: Python 3 is unavailable; refusing to upgrade." >&2
  exit 1
fi

size="$(stat -c%s "$firmware" 2>/dev/null || wc -c < "$firmware")"
min_size=$((50 * 1024 * 1024))
case "$size" in
  ''|*[!0-9]*)
    echo "ERROR: Could not determine firmware size." >&2
    exit 1
    ;;
esac
if [ "$size" -lt "$min_size" ]; then
  echo "ERROR: Firmware is only $((size / 1024)) KB; expected at least 50 MB, refusing to upgrade." >&2
  exit 1
fi

tmp_root="${FIRMWARE_UPGRADE_TMP_DIR:-/userdata/.tmp_upgrade}"
state_dir="${FIRMWARE_UPGRADE_STATE_DIR:-/userdata/.extended-firmware-upgrade}"
mkdir -p "$tmp_root"
tmpdir="$(mktemp -d "$tmp_root/preflight.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT HUP INT TERM

echo "Validating firmware container..."
parser="$(dirname "$0")/firmware-upgrade-preflight.py"
if ! python3 "$parser" "$firmware" "$tmpdir"; then
  echo "ERROR: Firmware container validation failed." >&2
  exit 1
fi

for required in update.img at32f403a.bin at32f415.bin MCU_DESC UPFILE_VERSION UPFILE_BUILD_DATE; do
  if [ ! -s "$tmpdir/$required" ]; then
    echo "ERROR: Firmware container is missing $required." >&2
    exit 1
  fi
done

magic="$(head -c 4 "$tmpdir/update.img" 2>/dev/null || true)"
case "$magic" in
  RKAF|RKFW)
    ;;
  *)
    echo "ERROR: update.img is not a valid Rockchip update image." >&2
    exit 1
    ;;
esac

# Preserve only non-sensitive candidate identity for the post-boot health
# gate. Images built by this repository carry a short commit stamp. A package
# without that identity can still be installed, but cannot be health-monitored.
metadata_dir="$state_dir"
metadata_file="$metadata_dir/preflight-metadata"
mkdir -p "$metadata_dir"
upfile_version="$(tr -d '\r\n' < "$tmpdir/UPFILE_VERSION")"
# The build appends git's short hash directly to the fixed-width UPFILE
# version field, so it may look like 1.6.0.267abcdef0 rather than a new line.
candidate_commit="$(printf '%s' "$upfile_version" | sed -n 's/.*\([0-9A-Fa-f]\{7\}\)$/\1/p')"
metadata_tmp="$metadata_file.tmp.$$"
{
  printf 'candidate_commit=%s\n' "$candidate_commit"
  printf 'candidate_upfile_version=%s\n' "$upfile_version"
} > "$metadata_tmp"
mv -f "$metadata_tmp" "$metadata_file"

echo "Firmware preflight passed ($((size / 1024 / 1024)) MB)."
