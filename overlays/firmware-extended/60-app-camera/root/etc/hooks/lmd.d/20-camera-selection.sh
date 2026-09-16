# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

if [ "$1" = start ]; then
    EXTENDED_CFG="/home/lava/printer_data/config/extended/extended2.cfg"
    CAMERA_INTERNAL=$(/usr/local/bin/extended-config.py get "$EXTENDED_CFG" camera internal snapmaker) || {
        echo "ERROR: Failed to read the internal camera setting; using Snapmaker camera mode."
        CAMERA_INTERNAL=snapmaker
    }
    if [ -z "$CAMERA_INTERNAL" ]; then
        echo "ERROR: Internal camera setting is empty; using Snapmaker camera mode."
        CAMERA_INTERNAL=snapmaker
    fi

    case "$CAMERA_INTERNAL" in
    paxx12)
        echo "Starting lmd in v4l2-imposter mode!"
        export LD_PRELOAD="/usr/local/lib/libv4l2-imposter.so${LD_PRELOAD:+:$LD_PRELOAD}"
        export V4L2_IMPOSTER_SOCKET_PATH=/tmp/capture-mipi-raw.sock
        export V4L2_IMPOSTER_DEVICE=/dev/video11
        export V4L2_IMPOSTER_WIDTH=1920
        export V4L2_IMPOSTER_HEIGHT=1080
        export V4L2_IMPOSTER_FORMAT=nv12
        ;;
    snapmaker)
        ;;
    none)
        echo "Internal camera is disabled, not starting lmd."
        exit 0
        ;;
    *)
        echo "ERROR: Unknown internal camera setting '$CAMERA_INTERNAL'; using Snapmaker camera mode."
        ;;
    esac
fi
