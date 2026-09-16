#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 @paxx12, @LixNix, @liberodark

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <user@ip> <profile>"
  exit 1
fi

SSH_HOST="$1"
PROFILE="$2"
shift 2

PASSWORD="${PASSWORD:-snapmaker}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

set -xe

OUTPUT_FILE="firmware/firmware_$PROFILE.bin"
make validate-build OUTPUT_FILE="$OUTPUT_FILE" PROFILE="$PROFILE" OVERWRITE=1
sshpass -p "$PASSWORD" scp $SSH_OPTS "$OUTPUT_FILE" "$SSH_HOST:/userdata/firmware_upgrade.bin"
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$SSH_HOST" \
  'set -e; /usr/local/bin/firmware-upgrade-preflight.sh /userdata/firmware_upgrade.bin; /bin/sh /usr/local/bin/firmware-upgrade-health.sh begin /userdata/firmware_upgrade.bin; /home/lava/bin/systemUpgrade.sh upgrade all /userdata/firmware_upgrade.bin'
