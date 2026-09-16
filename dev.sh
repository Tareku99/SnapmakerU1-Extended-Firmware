#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 @paxx12, @liberodark

set -e

IMAGE_NAME="snapmaker-u1-dev"
BUILD_CONTEXT=".github/dev"

check_checkout_line_endings() {
    if ! git ls-files --eol | awk '$2 == "w/crlf" || $2 == "w/mixed" {print}' | grep -q .; then
        return 0
    fi

    echo "[!] Refusing to build from a checkout with CRLF/mixed runtime bytes."
    echo "    The firmware build copies Linux-executed files byte-for-byte."
    echo "    Use a fresh checkout with the repository .gitattributes policy,"
    echo "    or normalize the checkout before building."
    echo
    git ls-files --eol | awk '$2 == "w/crlf" || $2 == "w/mixed" {print}'
    exit 1
}

check_checkout_line_endings

if ! docker build --cache-from "$IMAGE_NAME" -t "$IMAGE_NAME" "$BUILD_CONTEXT"; then
    echo "[!] Docker build failed."
    exit 1
fi

TTY_FLAG=""
[[ -t 0 ]] && TTY_FLAG="-it"

ENV_FLAGS="-e GIT_VERSION -e CI -e PASSWORD"

exec docker run --rm $DOCKER_OPTS $TTY_FLAG $ENV_FLAGS -w "$PWD" -v "$PWD:$PWD" "$IMAGE_NAME" "$@"
