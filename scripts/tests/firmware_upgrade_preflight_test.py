# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

import hashlib
import importlib.util
import os
import pathlib
import re
import subprocess
import tempfile
import unittest


ROOT_DIR = pathlib.Path(__file__).resolve().parents[2]
OVERLAY_BIN = (
    ROOT_DIR
    / "overlays/firmware-extended/02-firmware-config/root/usr/local/bin"
)
PREFLIGHT_SCRIPT = OVERLAY_BIN / "firmware-upgrade-preflight.sh"
PARSER_PATH = OVERLAY_BIN / "firmware-upgrade-preflight.py"

SPEC = importlib.util.spec_from_file_location("firmware_upfile_preflight", PARSER_PATH)
PARSER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARSER)


def encode_data(data):
    inverse = bytearray(256)
    for encoded, decoded in enumerate(PARSER.DATA_MAP):
        inverse[decoded] = encoded
    return bytes(inverse[value] for value in data)


def make_upfile(
    path,
    update_payload=b"RKFW fixture",
    file_count=4,
    minimum_size=0,
    overlap=False,
    container_version=1,
    version=b"1.6.0.267abcdef0",
    build_date=b"20260916120000",
):
    payloads = [
        update_payload,
        b"MCU1 fixture",
        b"MCU2 fixture",
        b"MCU description",
    ][:file_count]
    header = bytearray(PARSER.HEADER_SIZE)
    header[0:4] = b"SNMK"
    header[4:6] = container_version.to_bytes(2, "big")
    header[8:32] = version[:24].ljust(24, b"\x00")
    header[32:46] = build_date[:14].ljust(14, b"\x00")
    header[46:48] = file_count.to_bytes(2, "big")
    header[6:8] = (sum(header) & 0xFFFF).to_bytes(2, "big")

    cursor = PARSER.HEADER_SIZE + file_count * PARSER.ENTRY_SIZE
    entries = []
    first_offset = cursor
    for index, payload in enumerate(payloads):
        entry = bytearray(PARSER.ENTRY_SIZE)
        entry_offset = first_offset if overlap and index == 1 else cursor
        entry[0:2] = index.to_bytes(2, "big")
        entry[4:12] = entry_offset.to_bytes(8, "big")
        entry[12:16] = len(payload).to_bytes(4, "big")
        entry[16:32] = hashlib.md5(payload).digest()
        entry[2:4] = (sum(entry) & 0xFFFF).to_bytes(2, "big")
        entries.append(encode_data(entry))
        cursor += len(payload)

    with open(path, "wb") as firmware:
        firmware.write(encode_data(header))
        firmware.write(b"".join(entries))
        firmware.write(b"".join(payloads))
        if minimum_size > firmware.tell():
            firmware.truncate(minimum_size)


def corrupt_byte(path, offset):
    with open(path, "r+b") as firmware:
        firmware.seek(offset)
        value = firmware.read(1)
        firmware.seek(offset)
        firmware.write(bytes([value[0] ^ 0x01]))


class FirmwareUpgradePreflightTests(unittest.TestCase):
    def test_decoder_table_matches_the_project_upfile_implementation(self):
        source = (ROOT_DIR / "tools/upfile/helpers.h").read_text(encoding="utf-8")
        match = re.search(r"data_map\[256\]\s*=\s*\{([^}]*)\}", source)
        self.assertIsNotNone(match)
        values = bytes(
            int(value, 16)
            for value in re.findall(r"0x([0-9a-fA-F]{2})", match.group(1))
        )
        self.assertEqual(len(values), 256)
        self.assertEqual(values, PARSER.DATA_MAP)
        self.assertEqual(len(set(values)), 256)

    def test_valid_container_extracts_payloads_and_version(self):
        with tempfile.TemporaryDirectory(prefix="u1-upfile-parser-") as temp:
            root = pathlib.Path(temp)
            image = root / "valid.bin"
            output = root / "output"
            output.mkdir()
            make_upfile(image)

            PARSER.unpack_upfile(image, output)

            self.assertEqual((output / "update.img").read_bytes(), b"RKFW fixture")
            self.assertEqual((output / "at32f403a.bin").read_bytes(), b"MCU1 fixture")
            self.assertEqual((output / "at32f415.bin").read_bytes(), b"MCU2 fixture")
            self.assertEqual((output / "MCU_DESC").read_bytes(), b"MCU description")
            self.assertEqual(
                (output / "UPFILE_VERSION").read_bytes(), b"1.6.0.267abcdef0"
            )
            self.assertEqual(
                (output / "UPFILE_BUILD_DATE").read_bytes(), b"20260916120000"
            )

    def test_supports_container_format_version_2(self):
        with tempfile.TemporaryDirectory(prefix="u1-upfile-v2-") as temp:
            root = pathlib.Path(temp)
            image = root / "version-2.bin"
            output = root / "output"
            output.mkdir()
            make_upfile(image, container_version=2)

            PARSER.unpack_upfile(image, output)

            self.assertEqual((output / "update.img").read_bytes(), b"RKFW fixture")

    def test_rejects_bad_header_checksum(self):
        with tempfile.TemporaryDirectory(prefix="u1-upfile-header-") as temp:
            root = pathlib.Path(temp)
            image = root / "bad-header.bin"
            output = root / "output"
            output.mkdir()
            make_upfile(image)
            corrupt_byte(image, 60)

            with self.assertRaisesRegex(ValueError, "header checksum mismatch"):
                PARSER.unpack_upfile(image, output)

    def test_rejects_incomplete_payload_table(self):
        with tempfile.TemporaryDirectory(prefix="u1-upfile-table-") as temp:
            root = pathlib.Path(temp)
            image = root / "short-table.bin"
            output = root / "output"
            output.mkdir()
            make_upfile(image, file_count=3)

            with self.assertRaisesRegex(ValueError, "expected 4 firmware payloads"):
                PARSER.unpack_upfile(image, output)

    def test_rejects_control_characters_in_version_metadata(self):
        with tempfile.TemporaryDirectory(prefix="u1-upfile-version-") as temp:
            root = pathlib.Path(temp)
            image = root / "invalid-version.bin"
            output = root / "output"
            output.mkdir()
            make_upfile(image, version=b"1.6.0.267\nstate=verified")

            with self.assertRaisesRegex(ValueError, "version contains invalid characters"):
                PARSER.unpack_upfile(image, output)

    def test_rejects_non_numeric_build_date(self):
        with tempfile.TemporaryDirectory(prefix="u1-upfile-date-") as temp:
            root = pathlib.Path(temp)
            image = root / "invalid-date.bin"
            output = root / "output"
            output.mkdir()
            make_upfile(image, build_date=b"20260916oops00")

            with self.assertRaisesRegex(ValueError, "build date must contain 14 digits"):
                PARSER.unpack_upfile(image, output)

    def test_rejects_overlapping_payloads(self):
        with tempfile.TemporaryDirectory(prefix="u1-upfile-overlap-") as temp:
            root = pathlib.Path(temp)
            image = root / "overlap.bin"
            output = root / "output"
            output.mkdir()
            make_upfile(image, overlap=True)

            with self.assertRaisesRegex(ValueError, "overlapping firmware payloads"):
                PARSER.unpack_upfile(image, output)

    def test_rejects_tampered_payload(self):
        with tempfile.TemporaryDirectory(prefix="u1-upfile-payload-") as temp:
            root = pathlib.Path(temp)
            image = root / "bad-payload.bin"
            output = root / "output"
            output.mkdir()
            make_upfile(image)
            corrupt_byte(image, PARSER.HEADER_SIZE + 4 * PARSER.ENTRY_SIZE)

            with self.assertRaisesRegex(ValueError, "payload checksum mismatch"):
                PARSER.unpack_upfile(image, output)

    def run_preflight(self, image, temp_root, state_root):
        env = os.environ.copy()
        env["FIRMWARE_UPGRADE_TMP_DIR"] = str(temp_root)
        env["FIRMWARE_UPGRADE_STATE_DIR"] = str(state_root)
        return subprocess.run(
            ["/bin/sh", str(PREFLIGHT_SCRIPT), str(image)],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    @unittest.skipUnless(
        os.name == "posix" and pathlib.Path("/bin/sh").exists(),
        "printer-side shell integration test requires a POSIX environment",
    )
    def test_preflight_accepts_valid_container_and_preserves_metadata_on_reject(self):
        with tempfile.TemporaryDirectory(prefix="u1-preflight-integration-") as temp:
            root = pathlib.Path(temp)
            image = root / "valid-size.bin"
            bad_magic = root / "bad-inner-magic.bin"
            extract_root = root / "extract"
            state_root = root / "state"
            extract_root.mkdir()
            make_upfile(image, minimum_size=50 * 1024 * 1024)

            result = self.run_preflight(image, extract_root, state_root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Firmware preflight passed (50 MB)", result.stdout)
            metadata = state_root / "preflight-metadata"
            original_metadata = metadata.read_bytes()
            self.assertIn(b"candidate_commit=abcdef0\n", original_metadata)
            self.assertFalse(any(extract_root.iterdir()))

            legacy_image = root / "rkaf-image.bin"
            make_upfile(
                legacy_image,
                update_payload=b"RKAF fixture",
                minimum_size=50 * 1024 * 1024,
            )
            legacy_result = self.run_preflight(legacy_image, extract_root, state_root)
            self.assertEqual(
                legacy_result.returncode,
                0,
                legacy_result.stdout + legacy_result.stderr,
            )

            make_upfile(
                bad_magic,
                update_payload=b"BAD! fixture",
                minimum_size=50 * 1024 * 1024,
            )
            rejected = self.run_preflight(bad_magic, extract_root, state_root)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("not a valid Rockchip update image", rejected.stderr)
            self.assertEqual(metadata.read_bytes(), original_metadata)
            self.assertFalse(any(extract_root.iterdir()))

    @unittest.skipUnless(
        os.name == "posix" and pathlib.Path("/bin/sh").exists(),
        "printer-side shell integration test requires a POSIX environment",
    )
    def test_preflight_rejects_short_file_before_unpacking(self):
        with tempfile.TemporaryDirectory(prefix="u1-preflight-short-") as temp:
            root = pathlib.Path(temp)
            image = root / "too-small.bin"
            extract_root = root / "extract"
            state_root = root / "state"
            extract_root.mkdir()
            image.write_bytes(b"short")

            result = self.run_preflight(image, extract_root, state_root)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected at least 50 MB", result.stderr)
            self.assertFalse(state_root.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
