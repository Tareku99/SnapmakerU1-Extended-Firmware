#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

# Inspect a staged U1 rootfs or a complete upgrade.bin. This script never
# sources packaged code, chroots, flashes, reboots, or contacts a printer.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage:
  validate_firmware.sh --rootfs ROOTFS [--profile PROFILE] [--report FILE]
  validate_firmware.sh --firmware IMAGE --base-firmware BASE \
      [--profile PROFILE] [--report FILE]
  validate_firmware.sh --firmware IMAGE --allow-protected-partition-change \
      [--profile PROFILE] [--report FILE]
EOF
}

MODE=""
TARGET=""
BASE_FIRMWARE=""
PROFILE=""
REPORT=""
ALLOW_PROTECTED_PARTITION_CHANGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rootfs|--firmware|--base-firmware|--profile|--report)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      case "$1" in
        --rootfs) MODE="rootfs"; TARGET="$2" ;;
        --firmware) MODE="firmware"; TARGET="$2" ;;
        --base-firmware) BASE_FIRMWARE="$2" ;;
        --profile) PROFILE="$2" ;;
        --report) REPORT="$2" ;;
      esac
      shift 2
      ;;
    --allow-protected-partition-change)
      ALLOW_PROTECTED_PARTITION_CHANGE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$MODE" || -z "$TARGET" ]]; then
  usage >&2
  exit 2
fi

if [[ "$MODE" == "firmware" && -z "$BASE_FIRMWARE" && \
    "$ALLOW_PROTECTED_PARTITION_CHANGE" -ne 1 ]]; then
  echo "A base firmware is required for protected package validation." >&2
  echo "Use --allow-protected-partition-change only for the intentional debug-misc image." >&2
  exit 2
fi

ROOT_DIR="$(realpath "$(dirname "$0")/..")"
FAILURES=0
ROOTFS_PATH=""
TMP_DIR=""

if [[ -n "$REPORT" ]]; then
  REPORT="$(realpath -m "$REPORT")"
  mkdir -p "$(dirname "$REPORT")"
  : > "$REPORT"
fi

say() {
  printf '%s\n' "$*"
  if [[ -n "$REPORT" ]]; then
    printf '%s\n' "$*" >> "$REPORT"
  fi
}

fail() {
  say "FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

for command_name in find file grep head realpath sha256sum stat python3 git \
    tr bash sh dd cmp awk readlink; do
  need_command "$command_name"
done
if [[ "$MODE" == "firmware" ]]; then
  need_command unsquashfs
fi
[[ "$FAILURES" -eq 0 ]] || exit 1

check_shebang() {
  local file_path="$1"
  local first_line="$2"
  local rest interpreter argument command_name command_path

  rest="${first_line#\#!}"
  read -r interpreter argument _ <<< "$rest"
  if [[ -z "$interpreter" || "$interpreter" != /* ]]; then
    fail "$file_path has an empty or relative shebang interpreter"
    return
  fi
  if [[ ! -x "$ROOTFS_PATH$interpreter" ]]; then
    fail "$file_path shebang interpreter is missing or not executable: $interpreter"
  fi
  [[ "$interpreter" == */env ]] || return

  if [[ "$argument" == "-S" ]]; then
    rest="${rest#* -S}"
    read -r command_name _ <<< "$rest"
  else
    command_name="$argument"
  fi
  if [[ -z "$command_name" || "$command_name" == -* ]]; then
    fail "$file_path has an invalid env shebang"
    return
  fi
  if [[ "$command_name" == /* ]]; then
    command_path="$ROOTFS_PATH$command_name"
    [[ -x "$command_path" ]] || fail "$file_path env program is missing: $command_name"
    return
  fi
  for command_path in "$ROOTFS_PATH/usr/local/bin/$command_name" \
      "$ROOTFS_PATH/usr/bin/$command_name" "$ROOTFS_PATH/bin/$command_name" \
      "$ROOTFS_PATH/usr/sbin/$command_name" "$ROOTFS_PATH/sbin/$command_name"; do
    [[ -x "$command_path" ]] && return
  done
  fail "$file_path env program is missing from the target rootfs: $command_name"
}

check_runtime_file() {
  local file_path="$1"
  local relative first_line="" mime="" runtime=0 is_text=0 must_be_lf=0
  relative="${file_path#"$ROOTFS_PATH"/}"

  case "$relative" in
    etc/init.d/*|etc/hooks/*|etc/profile*|\
    usr/local/bin/*|usr/local/sbin/*|usr/sbin/*|\
    bin/*|sbin/*|\
    usr/local/share/firmware-config/*|usr/local/share/spoollink/*)
      runtime=1
      ;;
  esac
  case "$relative" in
    etc/init.d/*|etc/hooks/*|etc/profile*|\
    usr/local/bin/*|usr/local/sbin/*|bin/*|sbin/*|\
    *.sh|*.bash)
      must_be_lf=1
      ;;
  esac

  mime="$(file -b --mime-type "$file_path" 2>/dev/null || true)"
  case "$mime" in
    text/*|application/json|application/*script*)
      is_text=1
      ;;
  esac
  if [[ "$is_text" -eq 1 && "$runtime" -eq 1 ]]; then
    # Only read a first line after file(1) has established that this is text.
    # Reading the head of every binary executable through command substitution
    # produces NUL-byte warnings and can corrupt the checker's input.
    first_line="$(LC_ALL=C head -n 1 -- "$file_path" 2>/dev/null || true)"
    if [[ "$runtime" -eq 1 ]]; then
      if [[ "$must_be_lf" -eq 1 || -x "$file_path" ]]; then
        if LC_ALL=C grep -qU -- $'\r' "$file_path" 2>/dev/null; then
          fail "$relative contains CRLF or mixed line endings"
        fi
      fi
      if [[ "$first_line" == '#!'* ]]; then
        check_shebang "$file_path" "${first_line%$'\r'}"
      fi
    fi
  fi

  if [[ "$is_text" -eq 1 && "$runtime" -eq 1 ]]; then
    case "$relative" in
      *.sh|*.bash|etc/init.d/*|etc/hooks/*)
        if [[ "$first_line" == *"/bash"* ]]; then
          bash -n "$file_path" >/dev/null 2>&1 || fail "$relative failed bash syntax validation"
        else
          sh -n "$file_path" >/dev/null 2>&1 || fail "$relative failed sh syntax validation"
        fi
        ;;
    esac
  fi
}

validate_python_file() {
  local file_path="$1"
  if ! python3 - "$file_path" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
  then
    fail "${file_path#"$ROOTFS_PATH"/} failed Python syntax validation"
  fi
}

validate_json_file() {
  local file_path="$1"
  if ! python3 - "$file_path" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
json.loads(path.read_text(encoding="utf-8"))
PY
  then
    fail "${file_path#"$ROOTFS_PATH"/} failed JSON validation"
  fi
}

validate_yaml_file() {
  local file_path="$1"
  if ! python3 - "$file_path" <<'PY'
import pathlib
import sys
import yaml

path = pathlib.Path(sys.argv[1])
yaml.safe_load(path.read_text(encoding="utf-8"))
PY
  then
    fail "${file_path#"$ROOTFS_PATH"/} failed YAML validation"
  fi
}

validate_rootfs() {
  ROOTFS_PATH="$(realpath "$1")"
  if [[ ! -d "$ROOTFS_PATH" ]]; then
    fail "rootfs directory does not exist: $ROOTFS_PATH"
    return
  fi

  local required file_path
  local required_paths=(
    etc/init.d/rcS
    etc/init.d/S49extended-config
    etc/init.d/S90lmd
    usr/local/bin/extended-config.py
  )
  for required in "${required_paths[@]}"; do
    file_path="$ROOTFS_PATH/$required"
    if [[ ! -f "$file_path" ]]; then
      fail "required runtime file is missing: $required"
    elif [[ ! -x "$file_path" ]]; then
      fail "required runtime file is not executable: $required"
    fi
  done

  for required in etc/FULLVERSION etc/BUILD_VERSION; do
    file_path="$ROOTFS_PATH/$required"
    [[ -s "$file_path" ]] || fail "required build metadata is missing or empty: $required"
  done

  if [[ -n "$PROFILE" ]]; then
    file_path="$ROOTFS_PATH/etc/BUILD_PROFILE"
    if [[ ! -s "$file_path" ]]; then
      fail "expected profile metadata is missing: etc/BUILD_PROFILE"
    elif [[ "$(tr -d '\r\n' < "$file_path")" != "$PROFILE" ]]; then
      fail "profile mismatch in etc/BUILD_PROFILE"
    fi
  fi

  if [[ -d "$ROOTFS_PATH/etc/init.d" ]]; then
    while IFS= read -r -d '' file_path; do
      [[ -x "$file_path" ]] || fail "init script is not executable: ${file_path#"$ROOTFS_PATH"/}"
    done < <(find "$ROOTFS_PATH/etc/init.d" -maxdepth 1 -type f -name 'S??*' -print0)
  fi

  local runtime_root
  for runtime_root in "$ROOTFS_PATH/etc/init.d" \
      "$ROOTFS_PATH/etc/hooks" "$ROOTFS_PATH/etc/profile.d" \
      "$ROOTFS_PATH/usr/local/bin" "$ROOTFS_PATH/usr/local/sbin" \
      "$ROOTFS_PATH/bin" "$ROOTFS_PATH/sbin" \
      "$ROOTFS_PATH/usr/local/share/firmware-config" \
      "$ROOTFS_PATH/usr/local/share/spoollink"; do
    [[ -d "$runtime_root" ]] || continue
    while IFS= read -r -d '' file_path; do
      check_runtime_file "$file_path"
    done < <(find "$runtime_root" -type f -print0)
  done
  for file_path in "$ROOTFS_PATH/etc/profile" "$ROOTFS_PATH/etc/inittab"; do
    [[ -f "$file_path" ]] && check_runtime_file "$file_path"
  done

  local python_root
  for python_root in "$ROOTFS_PATH/usr/local/bin" \
      "$ROOTFS_PATH/usr/local/sbin" "$ROOTFS_PATH/home/lava/klipper/klippy" \
      "$ROOTFS_PATH/home/lava/moonraker/moonraker" \
      "$ROOTFS_PATH/usr/local/share/firmware-config" \
      "$ROOTFS_PATH/usr/local/share/spoollink"; do
    [[ -d "$python_root" ]] || continue
    while IFS= read -r -d '' file_path; do
      validate_python_file "$file_path"
    done < <(find "$python_root" -type f -name '*.py' -print0)
  done

  local functions_dir="$ROOTFS_PATH/usr/local/share/firmware-config/functions"
  if [[ -d "$functions_dir" ]]; then
    if ! python3 -c 'import yaml' >/dev/null 2>&1; then
      fail "PyYAML is required to validate firmware-config YAML"
    else
      while IFS= read -r -d '' file_path; do
        validate_yaml_file "$file_path"
      done < <(find "$functions_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
    fi
    while IFS= read -r -d '' file_path; do
      validate_json_file "$file_path"
    done < <(find "$functions_dir" -type f -name '*.json' -print0)
  fi

  while IFS= read -r -d '' file_path; do
    local link_target resolved
    local relative="${file_path#"$ROOTFS_PATH"/}"
    link_target="$(readlink "$file_path")"
    case "$relative" in
      # These targets are created by mounts or generated services at runtime.
      dev/*|etc/dropbear|etc/mtab|home/lava/printer_data|\
      var/lib/dbus|var/lock)
        continue
        ;;
    esac
    [[ "$link_target" == /dev/* || "$link_target" == /proc/* || \
       "$link_target" == /sys/* ]] && continue
    if [[ "$link_target" == /* ]]; then
      resolved="$(realpath -m -s "$ROOTFS_PATH$link_target")"
    else
      resolved="$(realpath -m -s "$(dirname "$file_path")/$link_target")"
    fi
    case "$resolved" in
      "$ROOTFS_PATH"|$ROOTFS_PATH/*) ;;
      *) fail "symlink escapes rootfs: ${file_path#"$ROOTFS_PATH"/} -> $link_target"; continue ;;
    esac
  done < <(find "$ROOTFS_PATH" -type l -print0)

  local file_result description
  while IFS= read -r file_result; do
    description="${file_result#*: }"
    if [[ "$description" == ELF* && "$description" != *ARM* && \
        "$description" != *aarch64* ]]; then
      fail "non-ARM ELF in rootfs: ${file_result%%: *}"
    fi
  done < <(find "$ROOTFS_PATH" -type f -exec file {} +)
}

validate_package() {
  local image="$1"
  local candidate_dir="$TMP_DIR/candidate"
  local base_dir required file_path magic package_file

  if ! bash "$ROOT_DIR/scripts/helpers/unpack_firmware.sh" "$image" "$candidate_dir"; then
    fail "firmware package could not be unpacked"
    return
  fi

  for required in update.img rk-loader.img rk-rom.img UPFILE_VERSION \
      UPFILE_BUILD_DATE at32f403a.bin at32f415.bin MCU_DESC; do
    [[ -s "$candidate_dir/$required" ]] || fail "required UPFILE entry is missing: $required"
  done
  magic="$(dd if="$candidate_dir/update.img" bs=1 count=4 2>/dev/null || true)"
  [[ "$magic" == RKAF || "$magic" == RKFW ]] || \
    fail "update.img does not have RKAF or RKFW magic"

  package_file="$candidate_dir/rk-unpacked/package-file"
  for required in package-file parameter.txt boot.img misc.img rootfs.img \
      oem.img uboot.img userdata.img; do
    file_path="$candidate_dir/rk-unpacked/$required"
    [[ -s "$file_path" ]] || fail "required package file is missing: $required"
  done
  for required in uboot_a uboot_b misc boot_a boot_b system_a system_b oem userdata; do
    awk -v expected="$required" '$1 == expected { found = 1 } END { exit(found ? 0 : 1) }' \
      "$package_file" >/dev/null 2>&1 || fail "partition missing from package-file: $required"
  done

  if [[ -n "$BASE_FIRMWARE" ]]; then
    base_dir="$TMP_DIR/base"
    if ! bash "$ROOT_DIR/scripts/helpers/unpack_firmware.sh" \
        "$BASE_FIRMWARE" "$base_dir"; then
      fail "base firmware package could not be unpacked"
    else
      cmp -s "$package_file" "$base_dir/rk-unpacked/package-file" || \
        fail "package-file differs from the approved base"
      cmp -s "$candidate_dir/rk-unpacked/parameter.txt" \
        "$base_dir/rk-unpacked/parameter.txt" || \
        fail "parameter.txt differs from the approved base"
      cmp -s "$candidate_dir/rk-unpacked/misc.img" \
        "$base_dir/rk-unpacked/misc.img" || \
        fail "misc.img differs from the approved base"
    fi
  fi

  ROOTFS_PATH="$TMP_DIR/rootfs"
  if unsquashfs -d "$ROOTFS_PATH" "$candidate_dir/rk-unpacked/rootfs.img" \
      >/dev/null 2>&1; then
    validate_rootfs "$ROOTFS_PATH"
  else
    fail "rootfs.img could not be extracted as SquashFS"
  fi

  if [[ -n "$REPORT" ]]; then
    local source_commit source_branch source_state source_line source_path
    local image_relative="" report_relative=""
    source_commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'unavailable')"
    source_branch="$(git -C "$ROOT_DIR" symbolic-ref --short -q HEAD 2>/dev/null || printf 'detached')"
    source_state="dirty"
    if git -C "$ROOT_DIR" diff --quiet --ignore-submodules -- && \
        git -C "$ROOT_DIR" diff --cached --quiet --ignore-submodules --; then
      [[ "$image" == "$ROOT_DIR"/* ]] && image_relative="${image#"$ROOT_DIR"/}"
      [[ "$REPORT" == "$ROOT_DIR"/* ]] && report_relative="${REPORT#"$ROOT_DIR"/}"
      source_state="clean"
      while IFS= read -r source_line; do
        [[ -n "$source_line" ]] || continue
        source_path="${source_line:3}"
        if [[ -n "$image_relative" && "$source_path" == "$image_relative" ]]; then
          continue
        fi
        if [[ -n "$report_relative" && "$source_path" == "$report_relative" ]]; then
          continue
        fi
        source_state="dirty"
        break
      done < <(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)
    fi
    {
      printf 'validation_policy_version=1\n'
      printf 'artifact=%s\n' "$image"
      printf 'artifact_sha256=%s\n' "$(sha256sum "$image" | awk '{print $1}')"
      printf 'artifact_size=%s\n' "$(stat -c '%s' "$image")"
      printf 'source_commit=%s\n' "$source_commit"
      printf 'source_branch=%s\n' "$source_branch"
      printf 'source_state=%s\n' "$source_state"
      if [[ -s "$candidate_dir/UPFILE_VERSION" ]]; then
        printf 'upfile_version=%s\n' "$(tr -d '\r\n' < "$candidate_dir/UPFILE_VERSION")"
      fi
      if [[ -s "$candidate_dir/UPFILE_BUILD_DATE" ]]; then
        printf 'upfile_build_date=%s\n' "$(tr -d '\r\n' < "$candidate_dir/UPFILE_BUILD_DATE")"
      fi
      [[ -n "$PROFILE" ]] && printf 'expected_profile=%s\n' "$PROFILE"
      [[ -n "$BASE_FIRMWARE" ]] && printf 'base_firmware=%s\n' "$BASE_FIRMWARE"
      [[ -n "$BASE_FIRMWARE" ]] && printf 'base_sha256=%s\n' \
        "$(sha256sum "$BASE_FIRMWARE" | awk '{print $1}')"
      if [[ -n "$BASE_FIRMWARE" ]]; then
        printf 'protected_partition_check=compared_to_base\n'
      else
        printf 'protected_partition_check=explicit_debug_bypass\n'
      fi
      for file_path in "$candidate_dir/update.img" \
          "$candidate_dir/rk-unpacked/"*.img; do
        [[ -f "$file_path" ]] || continue
        printf 'payload.%s_sha256=%s\n' "${file_path##*/}" \
          "$(sha256sum "$file_path" | awk '{print $1}')"
        printf 'payload.%s_size=%s\n' "${file_path##*/}" \
          "$(stat -c '%s' "$file_path")"
      done
    } >> "$REPORT"
  fi
}

if [[ "$MODE" == "rootfs" ]]; then
  [[ -d "$TARGET" ]] && validate_rootfs "$TARGET" || fail "rootfs directory does not exist: $TARGET"
else
  if [[ ! -f "$TARGET" ]]; then
    fail "firmware file does not exist: $TARGET"
  elif [[ -n "$BASE_FIRMWARE" && ! -f "$BASE_FIRMWARE" ]]; then
    fail "base firmware file does not exist: $BASE_FIRMWARE"
  else
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/u1-firmware-validate.XXXXXX")"
    cleanup() { rm -rf "$TMP_DIR"; }
    trap cleanup EXIT
    validate_package "$(realpath "$TARGET")"
  fi
fi

if [[ "$FAILURES" -ne 0 ]]; then
  say "VALIDATION FAILED: $FAILURES failure(s)"
  exit 1
fi

say "VALIDATION PASSED"
