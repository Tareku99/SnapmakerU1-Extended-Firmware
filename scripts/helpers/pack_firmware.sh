#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2025 @paxx12

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <input_dir> <output.bin>"
  exit 1
fi

set -eo pipefail

if [[ ! -d "$1" ]]; then
  echo "Error: Input directory $1 does not exist."
  exit 1
fi

if [[ -f "$2" ]] && [[ -z "$OVERWRITE" ]]; then
  echo "Error: Output file $2 already exists."
  exit 1
fi

IN_DIR="$(realpath "$1")"
OUT="$(realpath -m "$2")"
ROOT_DIR="$(realpath "$(dirname "$0")/../..")"

if [[ -z "${BASE_FIRMWARE:-}" && "${ALLOW_PROTECTED_PARTITION_CHANGE:-}" != "1" ]]; then
  echo "Error: BASE_FIRMWARE is required so protected package data can be compared." >&2
  echo "       An intentional debug-only misc change must set ALLOW_PROTECTED_PARTITION_CHANGE=1." >&2
  exit 1
fi
if [[ -n "${BASE_FIRMWARE:-}" && ! -f "$BASE_FIRMWARE" ]]; then
  echo "Error: BASE_FIRMWARE does not exist: $BASE_FIRMWARE" >&2
  exit 1
fi

cd "$IN_DIR"

echo ">> Repacking rk-rom.new.img"
"$ROOT_DIR/tools/rk2918_tools/afptool" -pack rk-unpacked rk-rom.new.img

echo ">> Repacking update.img"
"$ROOT_DIR/tools/rk2918_tools/img_maker" rk-loader.img rk-rom.new.img update.img

echo ">> Repacking output firmware"
"$ROOT_DIR/tools/upfile/upfile" pack "$OUT"

echo ">> Validating packed firmware..."
VALIDATION_ARGS=(
  --firmware "$OUT"
  --report "$OUT.validation.txt"
)
if [[ -n "${PROFILE:-}" ]]; then
  VALIDATION_ARGS+=(--profile "$PROFILE")
fi
if [[ -n "${BASE_FIRMWARE:-}" ]]; then
  VALIDATION_ARGS+=(--base-firmware "$BASE_FIRMWARE")
else
  echo "WARNING: Protected partition comparison is intentionally bypassed for this debug image." >&2
  VALIDATION_ARGS+=(--allow-protected-partition-change)
fi
bash "$ROOT_DIR/scripts/validate_firmware.sh" "${VALIDATION_ARGS[@]}"

echo ">> Done. Output written to $OUT"
