#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "Usage: $0 <target-file> <url> <sha256> [extract-dir]"
  exit 1
fi

TARGET="$1"
URL="$2"
SHA256="$3"
EXTRACT_DIR="$4"

TARGET_DIR="$(dirname "$TARGET")"
FILENAME="$(basename "$TARGET")"

set -e
mkdir -p "$TARGET_DIR"

TEMP_TARGET=""
cleanup() {
  if [[ -n "$TEMP_TARGET" ]]; then
    rm -f -- "$TEMP_TARGET"
  fi
}
trap cleanup EXIT

hash_matches() {
  echo "$SHA256  $1" | sha256sum --check --status
}

if [[ -f "$TARGET" ]] && hash_matches "$TARGET"; then
  echo ">> Verified cached $FILENAME"
else
  if [[ -f "$TARGET" ]]; then
    echo "[!] Cached checksum mismatch for $FILENAME; downloading a verified replacement"
  else
    echo ">> Downloading $FILENAME..."
  fi

  TEMP_TARGET="$TARGET.tmp.$$"
  rm -f -- "$TEMP_TARGET"
  if ! wget -O "$TEMP_TARGET" "$URL"; then
    echo "[!] Download failed for $FILENAME"
    exit 1
  fi
  if ! hash_matches "$TEMP_TARGET"; then
    echo "[!] SHA256 checksum mismatch for downloaded $FILENAME"
    exit 1
  fi
  mv -f -- "$TEMP_TARGET" "$TARGET"
  TEMP_TARGET=""
fi

echo ">> Verifying $TARGET checksum..."
if ! hash_matches "$TARGET"; then
  echo "[!] SHA256 checksum mismatch for $FILENAME"
  exit 1
fi

if [[ -z "$EXTRACT_DIR" ]]; then
  exit 0
fi

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

case "$FILENAME" in
  *.tar.gz)
    echo ">> Extracting $FILENAME..."
    tar -xzf "$TARGET" -C "$EXTRACT_DIR"
    ;;

  *.tar.xz)
    echo ">> Extracting $FILENAME..."
    tar -xJf "$TARGET" -C "$EXTRACT_DIR"
    ;;

  *.zip)
    echo ">> Extracting $FILENAME..."
    unzip -o "$TARGET" -d "$EXTRACT_DIR"
    ;;

  *)
    ;;
esac
