#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

GIT_URL=https://github.com/paxx12/v4l2-mpp.git
GIT_SHA=131e5da933411ce47aef2c89be67c3c767432a02

if [[ -z "$CREATE_FIRMWARE" ]]; then
  echo "Error: This script should be run within the create_firmware.sh environment."
  exit 1
fi

set -eo pipefail

TARGET_DIR="$CACHE_DIR/v4l2-mpp"
cache_git.sh "$TARGET_DIR" "$GIT_URL" "$GIT_SHA"

# The pinned v4l2-mpp build extracts Live555 from a tarball whose config files
# are read-only. Its cross-compile path appends to the generated config after
# extraction, so make that one generated file writable before the dependency
# build starts. Keep this compatibility fix local to the pinned dependency;
# do not alter the source archive or the final firmware contents.
LIVE_MEDIA_SCRIPT="$TARGET_DIR/deps/compile_livemedia.sh"
if [[ ! -f "$LIVE_MEDIA_SCRIPT" ]]; then
  echo "Error: pinned v4l2-mpp dependency is missing $LIVE_MEDIA_SCRIPT."
  exit 1
fi
LIVE_MEDIA_DIR="$TARGET_DIR/deps/live"
if [[ -d "$LIVE_MEDIA_DIR" ]]; then
  chmod u+rwx "$LIVE_MEDIA_DIR"
  chmod u+rw "$LIVE_MEDIA_DIR"/config.armlinux* 2>/dev/null || true
fi
if ! grep -q '^  chmod u+w config\.armlinux-no-std-lib$' "$LIVE_MEDIA_SCRIPT"; then
  sed -i '/^  cp config\.armlinux config\.armlinux-no-std-lib$/a\  chmod u+w config.armlinux-no-std-lib' "$LIVE_MEDIA_SCRIPT"
fi

echo ">> Setting up cross-compilation environment..."
export CROSS_COMPILE=aarch64-linux-gnu-
export CC="${CROSS_COMPILE}gcc"
export CXX="${CROSS_COMPILE}g++"
export AR="${CROSS_COMPILE}ar"
export RANLIB="${CROSS_COMPILE}ranlib"
export STRIP="${CROSS_COMPILE}strip"

echo ">> Compiling dependencies..."
make -C "$TARGET_DIR" deps

echo ">> Compiling v4l2-mpp applications..."
make -C "$TARGET_DIR" install DESTDIR="$1"

echo ">> Validate binaries..."
stat "$1/usr/local/bin/capture-v4l2-jpeg-mpp" >/dev/null
stat "$1/usr/local/bin/capture-v4l2-raw-mpp" >/dev/null
stat "$1/usr/local/bin/stream-rtsp" >/dev/null
stat "$1/usr/local/bin/stream-webrtc" >/dev/null
stat "$1/usr/local/bin/stream-http.py" >/dev/null
stat "$1/usr/local/bin/control-v4l2.py" >/dev/null
echo ">> v4l2-mpp installation completed successfully."
