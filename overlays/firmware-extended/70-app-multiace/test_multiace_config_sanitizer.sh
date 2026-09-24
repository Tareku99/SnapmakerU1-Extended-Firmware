#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

set -eu

OVERLAY_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/multiace-config-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

CONFIG_FILE="$TEST_DIR/ace.cfg"
cat > "$CONFIG_FILE" <<'EOF'
[ace]
ace_device_count: 2

[gcode_macro ACEH__Update_Check]
description: Check GitHub for a newer multiACE release (no install)
gcode:
  ACE_UPDATE_CHECK

[gcode_macro ACEH__Update_Apply]
description: Download + install the latest multiACE release
gcode:
  ACE_UPDATE_APPLY

[gcode_macro ACEG__Status]
description: Show active ACE, detected devices, and head mapping
gcode:
  ACE_HEAD_STATUS

[gcode_macro INNER_RESUME]
description: Resume the actual running print
gcode:
  RESUME
EOF

# common.sh only defines helpers when sourced. Override the firmware path with
# the temporary fixture before invoking the PAXX sanitizer.
. "$OVERLAY_DIR/root/usr/local/share/multiace/common.sh"
MULTIACE_CONFIG_FILE="$CONFIG_FILE"
multiace_sanitize_provider_config

if grep -q 'ACEH__Update_' "$CONFIG_FILE"; then
    echo "update wrapper macros were not removed" >&2
    exit 1
fi
grep -q '^ace_device_count: 2$' "$CONFIG_FILE"
grep -q '^\[gcode_macro ACEG__Status\]$' "$CONFIG_FILE"
grep -q '^\[gcode_macro INNER_RESUME\]$' "$CONFIG_FILE"

cp "$CONFIG_FILE" "$TEST_DIR/first.cfg"
multiace_sanitize_provider_config
cmp -s "$CONFIG_FILE" "$TEST_DIR/first.cfg"

echo "multiACE managed config sanitizer test passed"
