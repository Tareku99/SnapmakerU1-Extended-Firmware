#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

"""Validate and unpack the U1's outer SNMK upgrade container."""

import base64
import hashlib
import os
import pathlib
import sys


DATA_MAP = base64.b64decode(
    "AKLpDt5k7hJGO+d5pYBVMzI8C37OzFk3AZtOwasYchGcW+WN6A1plynZxa9KYXpj"
    "Oca80JKuf91sBzq5kffHRTRAtShE5stNPZ6UK2DSLz5n1lLTqNT4GtrscHygHQZP"
    "bi24NvBDIr20gp3rpFZ25CUVmHHDUEl3CPtHI6qKIPz2jIUwHsliulMP8ldRexM"
    "flsA1c4fbt6PtkF+a3OPhChsX6kH+WCbNBcICiGqfk3TiKgmsgVwc84v6hKHXXb"
    "51OOCmLC5mhu9UaLap9Qz5s78Usv271QT0p0jxbWuZfUuwrSGV0c/EJMqOsYMW3x"
    "kQJ0xvMT9aZXjI2AOJXo9C/w=="
)
HEADER_SIZE = 64
ENTRY_SIZE = 32
EXPECTED_FILE_COUNT = 4
FILE_NAMES = ("update.img", "at32f403a.bin", "at32f415.bin", "MCU_DESC")
CHUNK_SIZE = 1024 * 1024


def decode_data(data):
    if len(DATA_MAP) != 256:
        raise ValueError("invalid firmware-container decoder table")
    return bytes(DATA_MAP[value] for value in data)


def check_checksum(data, checksum_offset, description):
    actual = int.from_bytes(data[checksum_offset : checksum_offset + 2], "big")
    checked = bytearray(data)
    checked[checksum_offset : checksum_offset + 2] = b"\x00\x00"
    expected = sum(checked) & 0xFFFF
    if actual != expected:
        raise ValueError("{} checksum mismatch".format(description))


def clean_header_field(data):
    return data.split(b"\x00", 1)[0].rstrip(b"\r\n \t")


def extract_entry(source, output_dir, filename, offset, size, expected_md5):
    target = output_dir / filename
    temporary = output_dir / (filename + ".partial")
    digest = hashlib.md5()
    remaining = size

    try:
        with source.open("rb") as source_file, temporary.open("wb") as output_file:
            source_file.seek(offset)
            while remaining:
                chunk = source_file.read(min(CHUNK_SIZE, remaining))
                if not chunk:
                    raise ValueError("{} is truncated".format(filename))
                output_file.write(chunk)
                digest.update(chunk)
                remaining -= len(chunk)

        if digest.digest() != expected_md5:
            raise ValueError("{} payload checksum mismatch".format(filename))
        os.replace(str(temporary), str(target))
    except Exception:
        if temporary.exists():
            temporary.unlink()
        raise


def unpack_upfile(image_path, output_path):
    image = pathlib.Path(image_path)
    output_dir = pathlib.Path(output_path)
    if not image.is_file():
        raise ValueError("firmware file does not exist")
    if not output_dir.is_dir():
        raise ValueError("extraction directory does not exist")
    if any(output_dir.iterdir()):
        raise ValueError("extraction directory is not empty")

    image_size = image.stat().st_size
    with image.open("rb") as source:
        encoded_header = source.read(HEADER_SIZE)
        if len(encoded_header) != HEADER_SIZE:
            raise ValueError("firmware header is truncated")
        header = decode_data(encoded_header)
        if header[0:4] != b"SNMK":
            raise ValueError("invalid firmware container magic")
        container_version = int.from_bytes(header[4:6], "big")
        if container_version not in (1, 2):
            raise ValueError("unsupported firmware container version")
        check_checksum(header, 6, "firmware header")

        version = clean_header_field(header[8:32])
        build_date = clean_header_field(header[32:46])
        file_count = int.from_bytes(header[46:48], "big")
        if not version or not build_date:
            raise ValueError("firmware version or build date is empty")
        if not all(
            0x30 <= value <= 0x39
            or 0x41 <= value <= 0x5A
            or 0x61 <= value <= 0x7A
            or value in (0x2B, 0x2D, 0x2E, 0x5F)
            for value in version
        ):
            raise ValueError("firmware version contains invalid characters")
        if len(build_date) != 14 or not all(
            0x30 <= value <= 0x39 for value in build_date
        ):
            raise ValueError("firmware build date must contain 14 digits")
        if file_count != EXPECTED_FILE_COUNT:
            raise ValueError(
                "expected {} firmware payloads, found {}".format(
                    EXPECTED_FILE_COUNT, file_count
                )
            )

        table_end = HEADER_SIZE + file_count * ENTRY_SIZE
        encoded_table = source.read(file_count * ENTRY_SIZE)
        if len(encoded_table) != file_count * ENTRY_SIZE:
            raise ValueError("firmware payload table is truncated")

        entries = []
        ranges = []
        for index, filename in enumerate(FILE_NAMES):
            start = index * ENTRY_SIZE
            entry = decode_data(encoded_table[start : start + ENTRY_SIZE])
            if len(entry) != ENTRY_SIZE:
                raise ValueError("firmware payload entry is truncated")
            check_checksum(entry, 2, "payload entry {}".format(index))
            entry_type = int.from_bytes(entry[0:2], "big")
            offset = int.from_bytes(entry[4:12], "big")
            size = int.from_bytes(entry[12:16], "big")
            expected_md5 = entry[16:32]

            if entry_type != index:
                raise ValueError("unexpected payload type at entry {}".format(index))
            if size <= 0 or offset < table_end or offset + size > image_size:
                raise ValueError("invalid bounds for {}".format(filename))
            entries.append((filename, offset, size, expected_md5))
            ranges.append((offset, offset + size, filename))

        ranges.sort()
        for previous, current in zip(ranges, ranges[1:]):
            if current[0] < previous[1]:
                raise ValueError(
                    "overlapping firmware payloads: {} and {}".format(
                        previous[2], current[2]
                    )
                )

    for filename, offset, size, expected_md5 in entries:
        extract_entry(image, output_dir, filename, offset, size, expected_md5)

    (output_dir / "UPFILE_VERSION").write_bytes(version)
    (output_dir / "UPFILE_BUILD_DATE").write_bytes(build_date)


def main(arguments):
    if len(arguments) != 2:
        print("Usage: {} <upgrade.bin> <output-directory>".format(sys.argv[0]), file=sys.stderr)
        return 2
    try:
        unpack_upfile(arguments[0], arguments[1])
    except (OSError, ValueError) as error:
        print("ERROR: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
