#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

"""Offline tests for atomic, checksum-verified build dependency caching."""

from __future__ import annotations

import functools
import hashlib
import http.server
import subprocess
import tempfile
import threading
import unittest
from contextlib import contextmanager
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CACHE_HELPER = ROOT / "scripts/helpers/cache_file.sh"


class CacheFileTests(unittest.TestCase):
    def test_corrupt_cache_is_replaced_only_after_checksum_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            served = root / "served"
            served.mkdir()
            source = served / "payload.bin"
            source.write_bytes(b"verified dependency payload\n")
            expected = hashlib.sha256(source.read_bytes()).hexdigest()
            target = root / "cache" / source.name
            target.parent.mkdir()
            target.write_bytes(b"corrupt cache")

            with self._server(served) as url:
                result = self._run(target, f"{url}/payload.bin", expected)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(list(target.parent.glob("payload.bin.tmp.*")), [])

    def test_failed_download_does_not_leave_a_partial_target(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            target = root / "cache" / "missing.bin"
            target.parent.mkdir()

            with self._server(root) as url:
                result = self._run(
                    target,
                    f"{url}/does-not-exist.bin",
                    "0" * 64,
                )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists())
            self.assertEqual(list(target.parent.glob("missing.bin.tmp.*")), [])

    def test_valid_cache_skips_download(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            target = root / "cache" / "payload.bin"
            target.parent.mkdir()
            target.write_bytes(b"already verified")
            expected = hashlib.sha256(target.read_bytes()).hexdigest()

            result = self._run(
                target,
                "http://127.0.0.1:1/this-must-not-be-requested",
                expected,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(target.read_bytes(), b"already verified")

    @staticmethod
    def _run(target: Path, url: str, expected: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(CACHE_HELPER), str(target), url, expected],
            text=True,
            capture_output=True,
            check=False,
        )

    @staticmethod
    @contextmanager
    def _server(directory: Path):
        handler = functools.partial(
            http.server.SimpleHTTPRequestHandler,
            directory=str(directory),
        )
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}"
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
