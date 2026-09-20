#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2025 @paxx12

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <upgrade.bin> <temp-dir> <output.bin> [overlays...]"
  exit 1
fi

if [[ $(id -u) -ne 0 ]]; then
  echo "Error: This script must be run as root (sudo) - squashfs operations require root privileges"
  exit 1
fi

set -eo pipefail

IN_FIRMWARE="$(realpath "$1")"
OUT_FIRMWARE="$(realpath -m "$3")"

export CREATE_FIRMWARE=1
export ROOT_DIR="$(realpath "$(dirname "$0")/..")"
export CACHE_DIR="$ROOT_DIR/tmp/cache"
export PATH="$ROOT_DIR/scripts/helpers:$PATH"
export BUILD_DIR="$(realpath -m "$2")"
export ROOTFS_DIR="$BUILD_DIR/rootfs"
export BOOT_IMG="$BUILD_DIR/rk-unpacked/boot.img"
export ROOTFS_IMG="$BUILD_DIR/rk-unpacked/rootfs.img"

# Cache dirs for build tools
export GOPATH="$ROOT_DIR/tmp/cache-go"
export CCACHE_DIR="$ROOT_DIR/tmp/ccache"
export CHROOT_CACHE="$ROOT_DIR/tmp/cache-chroot"

rm -rf "$BUILD_DIR"

shift 3

validate_build_scripts() {
  local overlay script_dir scriptfile first_line
  for overlay; do
    for script_dir in "$overlay/pre-scripts" "$overlay/scripts"; do
      [[ -d "$script_dir" ]] || continue
      while IFS= read -r -d '' scriptfile; do
        first_line="$(LC_ALL=C head -n 1 -- "$scriptfile" 2>/dev/null || true)"
        if [[ "$first_line" != '#!'* ]]; then
          echo "Error: build script has no shebang: $scriptfile"
          exit 1
        fi
        if LC_ALL=C grep -qU -- $'\r' "$scriptfile" 2>/dev/null; then
          echo "Error: build script contains CRLF or mixed line endings: $scriptfile"
          exit 1
        fi
        if [[ "$first_line" == *"/bash"* ]]; then
          bash -n "$scriptfile" || exit 1
        else
          sh -n "$scriptfile" || exit 1
        fi
      done < <(find "$script_dir" -type f -name '*.sh' -print0)
    done
  done
}

validate_build_scripts "$@"

check_perms() {
  local file="$1"
  local expected_uid="$2"
  local expected_gid="$3"

  if [[ ! -e "$file" ]]; then
    echo "Error: $file does not exist for ownership check."
    exit 1
  fi

  local actual_uid=$(stat -c '%u' "$file")
  local actual_gid=$(stat -c '%g' "$file")

  if [[ "$actual_uid" != "$expected_uid" ]] || [[ "$actual_gid" != "$expected_gid" ]]; then
    echo "Error: $file should be $expected_uid:$expected_gid, got $actual_uid:$actual_gid"
    echo "This system does not properly preserve file ownership in squashfs operations."
    exit 1
  fi
}

echo ">> Unpacking firmware..."
"$ROOT_DIR/scripts/helpers/unpack_firmware.sh" "$IN_FIRMWARE" "$BUILD_DIR"

echo ">> Extracting squashfs from rootfs.img..."
unsquashfs -d "$ROOTFS_DIR" "$BUILD_DIR/rk-unpacked/rootfs.img"

echo ">> Verifying ownership preservation..."
check_perms "$ROOTFS_DIR/etc/passwd" 0 0
check_perms "$ROOTFS_DIR/home/lava/bin/hwver.sh" 1000 1000
echo "   Ownership check passed"

if [[ -z "$CI" ]]; then
  echo ">> Restoring chroot cache..."
  mkdir -p "$CHROOT_CACHE" "$ROOTFS_DIR/cache"
  cp -a "$CHROOT_CACHE/." "$ROOTFS_DIR/cache/"
fi

for overlay; do
  if [[ ! -d "$overlay" ]]; then
    echo "!! Overlay directory '$overlay' does not exist, skipping."
    exit 1
  fi

  echo ">> Applying overlay $overlay..."
  if [[ -d "$overlay/pre-scripts/" ]]; then
    for scriptfile in "$overlay/pre-scripts/"*.sh; do
      echo "[+] Running pre-script: $(basename "$scriptfile")"
      ./"$scriptfile" "$ROOTFS_DIR"
    done
  fi

  if [[ -d "$overlay/patches/" ]]; then
    pushd "$overlay/patches/" > /dev/null
    # apply all .patch to their respective directories
    while read -r patchfile; do
      echo "[+] Applying patch: $(basename "$patchfile") in subdir $(dirname "$patchfile")"
      patch -F 0 --no-backup-if-mismatch -d "$ROOTFS_DIR/$(dirname "$patchfile")" -p1 < "$patchfile"
    done < <(find -type f -name "*.patch" | sort)
    popd > /dev/null
  fi

  if [[ -d "$overlay/root/" ]]; then
    echo ">> Copying custom files..."
    cp -rv "$overlay/root/." "$ROOTFS_DIR/"
  fi

  if [[ -d "$overlay/scripts/" ]]; then
    for scriptfile in "$overlay/scripts/"*.sh; do
      echo "[+] Running script: $(basename "$scriptfile")"
      ./"$scriptfile" "$ROOTFS_DIR"
    done
  fi
done

if [[ -z "$CI" ]]; then
  echo ">> Saving chroot cache..."
  cp -a "$ROOTFS_DIR/cache/." "$CHROOT_CACHE/"
  rm -rf "$ROOTFS_DIR/cache"
fi

# Runtime files added by the upgrade safety guard must remain executable in
# the squashfs even when the source checkout is on a filesystem without Unix
# mode bits (for example a Windows bind mount used by local Docker builds).
for runtime_file in \
  "$ROOTFS_DIR/etc/init.d/S05firmware-upgrade-health" \
  "$ROOTFS_DIR/usr/local/bin/firmware-upgrade-health.sh" \
  "$ROOTFS_DIR/usr/local/bin/firmware-upgrade-preflight.sh"; do
  if [[ -f "$runtime_file" ]]; then
    chmod 0755 "$runtime_file"
  fi
done

echo ">> Validating staged rootfs..."
ROOTFS_VALIDATION_ARGS=(
  --rootfs "$ROOTFS_DIR"
  --report "$BUILD_DIR/rootfs-validation.txt"
)
if [[ -n "${PROFILE:-}" ]]; then
  ROOTFS_VALIDATION_ARGS+=(--profile "$PROFILE")
fi
bash "$ROOT_DIR/scripts/validate_firmware.sh" "${ROOTFS_VALIDATION_ARGS[@]}"

echo ">> Create squash filesystem..."
mksquashfs "$ROOTFS_DIR" "$BUILD_DIR/rk-unpacked/rootfs-v2.img" -comp zstd

echo ">> Replace rootfs.img in firmware..."
mv -v "$BUILD_DIR/rk-unpacked"/{rootfs-v2,rootfs}.img

echo ">> Update version..."
git rev-parse --short HEAD >> "$BUILD_DIR/UPFILE_VERSION"

echo ">> Repacking firmware..."
BASE_FIRMWARE="$IN_FIRMWARE" \
  "$ROOT_DIR/scripts/helpers/pack_firmware.sh" "$BUILD_DIR" "$OUT_FIRMWARE"

echo ">> Done: $OUT_FIRMWARE"
