#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

"""Offline behavior tests for the production Moonraker SpoolLink component.

The fixtures below are entirely local.  They exercise the production resolver
and formatter with a fake Spoolman HTTP client, a fake Moonraker server, and a
captured Klipper endpoint.  No network, printer, ACE device, or live Spoolman
instance is contacted.
"""

from __future__ import annotations

import asyncio
import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import MethodType, ModuleType
from typing import Any, Dict, List, Optional


ROOT = Path(__file__).resolve().parents[2]
MOONRAKER_SPOOLLINK = (
    ROOT
    / "overlays/firmware-extended/38-feature-spoollink/root/home/lava/"
    "moonraker/moonraker/components/spoollink.py"
)


def load_moonraker_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "spoollink_component_behavior_under_test", MOONRAKER_SPOOLLINK
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {MOONRAKER_SPOOLLINK}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


MODULE = load_moonraker_module()


class FakeResponse:
    def __init__(self, status_code: int, payload: Any, text: str = "") -> None:
        self.status_code = status_code
        self._payload = payload
        self._text = text

    def json(self) -> Any:
        return copy.deepcopy(self._payload)

    def text(self) -> str:
        return self._text or json.dumps(self._payload)


class FakeHttpClient:
    def __init__(self, spools: List[dict]) -> None:
        self.spools = {spool["id"]: copy.deepcopy(spool) for spool in spools}
        self.fail_card_lookup = False
        self.patch_calls: List[dict] = []

    async def get(self, url: str, **_kwargs: Any) -> FakeResponse:
        if "/spool?limit=1000" in url:
            if self.fail_card_lookup:
                raise ConnectionError("mock Spoolman unavailable")
            return FakeResponse(200, list(self.spools.values()))

        marker = "/api/v1/spool/"
        if marker in url:
            spool_id = int(url.rsplit("/", 1)[-1])
            spool = self.spools.get(spool_id)
            return FakeResponse(200, spool) if spool else FakeResponse(404, {})

        raise AssertionError(f"unexpected GET: {url}")

    async def request(self, method: str, url: str, **kwargs: Any) -> FakeResponse:
        if method != "PATCH" or "/api/v1/spool/" not in url:
            raise AssertionError(f"unexpected request: {method} {url}")
        spool_id = int(url.rsplit("/", 1)[-1])
        spool = self.spools[spool_id]
        body = kwargs["body"]
        encoded_uids = body["extra"]["card_uids"]
        spool.setdefault("extra", {})["card_uids"] = encoded_uids
        self.patch_calls.append({"id": spool_id, "card_uids": encoded_uids})
        return FakeResponse(200, spool)


class FakeSpoolman:
    def __init__(self) -> None:
        self.active_spool_calls: List[Optional[int]] = []

    def set_active_spool(self, spool_id: Optional[int]) -> None:
        self.active_spool_calls.append(spool_id)


class FakeServer:
    class error(Exception):
        pass

    def __init__(self, spoolman: Optional[FakeSpoolman] = None) -> None:
        self.spoolman = spoolman

    def lookup_component(self, name: str, default: Any = None) -> Any:
        if name == "spoolman":
            return self.spoolman if self.spoolman is not None else default
        return default


def make_spool(
    spool_id: int,
    *,
    card_uid: Optional[str] = None,
    vendor: str = "Anycubic",
    material: str = "PLA",
    variant: str = "",
    color_hex: str = "FF7F32",
    multi_color_hexes: str = "",
) -> dict:
    filament: Dict[str, Any] = {
        "material": material,
        "vendor": {"name": vendor},
        "color_hex": color_hex,
    }
    if variant:
        filament["extra"] = {"variant": json.dumps(variant)}
    if multi_color_hexes:
        filament["multi_color_hexes"] = multi_color_hexes

    spool: Dict[str, Any] = {"id": spool_id, "filament": filament}
    if card_uid is not None:
        spool["extra"] = {"card_uids": json.dumps(card_uid)}
    return spool


def bind_capture(component: Any) -> List[dict]:
    events: List[dict] = []

    async def capture(
        _self: Any,
        channel: int,
        message: str,
        info: Optional[dict] = None,
        status: str = "ok",
    ) -> dict:
        events.append({
            "channel": channel,
            "message": message,
            "info": info,
            "status": status,
        })
        return {}

    component._spoollink_set = MethodType(capture, component)
    return events


def make_component(
    http_client: FakeHttpClient,
    *,
    cache_dir: Optional[str] = None,
    force_generic_vendor: bool = False,
    spoolman: Optional[FakeSpoolman] = None,
) -> Any:
    component = object.__new__(MODULE.SpoolLink)
    component.server = FakeServer(spoolman)
    component.http_client = http_client
    component.klippy_apis = None
    component._spoolman_url = "http://spoolman.test"
    component._cache_dir = cache_dir
    component._force_generic_vendor = force_generic_vendor
    component._channel_event_times = {}
    component._toolhead_extruder = "extruder"
    component._ptc_spool_ids = []
    component._active_spool_id = None
    return component


class SpoolLinkBehaviorTests(unittest.TestCase):
    def test_explicit_spool_id_applies_only_to_requested_channel(self) -> None:
        http = FakeHttpClient([make_spool(6)])
        component = make_component(http)
        events = bind_capture(component)

        asyncio.run(component._resolve_spool(channel=2, spool_id=6))

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["channel"], 2)
        self.assertEqual(events[0]["info"]["SPOOL_ID"], 6)
        self.assertEqual(events[0]["info"]["CARD_UID"], [])
        self.assertIn("SpoolLink: E2 loaded", events[0]["message"])
        self.assertEqual(http.patch_calls, [])

    def test_rfid_lookup_applies_matching_spool_and_caches_it(self) -> None:
        http = FakeHttpClient([make_spool(6, card_uid="A1B2")])
        with tempfile.TemporaryDirectory() as cache_dir:
            component = make_component(http, cache_dir=cache_dir)
            events = bind_capture(component)

            asyncio.run(component._resolve_spool(channel=1, card_uid="a1b2"))

            self.assertEqual(events[0]["channel"], 1)
            self.assertEqual(events[0]["info"]["SPOOL_ID"], 6)
            self.assertEqual(events[0]["info"]["CARD_UID"], [0xA1, 0xB2])
            self.assertTrue((Path(cache_dir) / "A1B2.json").exists())

    def test_explicit_spool_with_card_rebinds_uid_and_removes_stale_owner(self) -> None:
        target = make_spool(7)
        stale = make_spool(6, card_uid="A1B2")
        http = FakeHttpClient([target, stale])
        component = make_component(http)
        events = bind_capture(component)

        asyncio.run(component._resolve_spool(channel=0, spool_id=7, card_uid="A1B2"))

        self.assertEqual(events[0]["info"]["SPOOL_ID"], 7)
        self.assertEqual(MODULE._parse_card_uids(http.spools[7]), ["A1B2"])
        self.assertEqual(MODULE._parse_card_uids(http.spools[6]), [])
        self.assertEqual([call["id"] for call in http.patch_calls], [7, 6])

    def test_duplicate_rfid_assignment_is_rejected_without_applying(self) -> None:
        http = FakeHttpClient([
            make_spool(6, card_uid="A1B2"),
            make_spool(7, card_uid="A1B2"),
        ])
        component = make_component(http)
        events = bind_capture(component)

        asyncio.run(component._resolve_spool(channel=3, card_uid="A1B2"))

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["channel"], 3)
        self.assertEqual(events[0]["status"], "error")
        self.assertIn("multiple spools", events[0]["message"])
        self.assertIsNone(events[0]["info"])
        self.assertEqual(http.patch_calls, [])

    def test_unknown_rfid_is_rejected_without_changing_a_channel(self) -> None:
        http = FakeHttpClient([make_spool(6, card_uid="A1B2")])
        component = make_component(http)
        events = bind_capture(component)

        asyncio.run(component._resolve_spool(channel=1, card_uid="FFFF"))

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["channel"], 1)
        self.assertEqual(events[0]["status"], "error")
        self.assertIn("no spool found", events[0]["message"])
        self.assertEqual(http.patch_calls, [])

    def test_cached_rfid_is_used_when_spoolman_is_unavailable(self) -> None:
        spool = make_spool(6, card_uid="A1B2")
        http = FakeHttpClient([])
        http.fail_card_lookup = True
        with tempfile.TemporaryDirectory() as cache_dir:
            cache_path = Path(cache_dir) / "A1B2.json"
            cache_path.write_text(json.dumps(spool), encoding="utf-8")
            component = make_component(http, cache_dir=cache_dir)

            async def no_wait_retry(
                _self: Any, fn: Any, *args: Any, **kwargs: Any
            ) -> Any:
                return await fn(*args, **kwargs)

            component._retry = MethodType(no_wait_retry, component)
            events = bind_capture(component)

            asyncio.run(component._resolve_spool(channel=2, card_uid="A1B2"))

            self.assertEqual(events[0]["channel"], 2)
            self.assertEqual(events[0]["info"]["SPOOL_ID"], 6)
            self.assertIn("[cached]", events[0]["message"])

    def test_force_generic_vendor_keeps_color_and_spool_id(self) -> None:
        http = FakeHttpClient([])
        component = make_component(http, force_generic_vendor=True)
        events = bind_capture(component)
        spool = make_spool(
            9,
            vendor="Anycubic",
            variant="Silk",
            color_hex="FF0000",
            multi_color_hexes="FF0000,00FF00",
        )

        asyncio.run(component._apply_spool(0, spool, "0102"))

        info = events[0]["info"]
        self.assertEqual(info["VENDOR"], "Generic")
        self.assertEqual(info["SUB_TYPE"], "")
        self.assertEqual(info["SPOOL_ID"], 9)
        self.assertEqual(info["CARD_UID"], [1, 2])
        self.assertEqual(info["COLOR_NUMS"], 2)
        self.assertEqual(info["RGB_1"], int("FF0000", 16))
        self.assertEqual(info["RGB_2"], int("00FF00", 16))
        self.assertIn("Generic PLA #FF0000", events[0]["message"])

    def test_active_spool_follows_selected_extruder_channel(self) -> None:
        spoolman = FakeSpoolman()
        component = make_component(FakeHttpClient([]), spoolman=spoolman)
        component._toolhead_extruder = "extruder2"
        component._ptc_spool_ids = [101, 102, 103, 104]

        asyncio.run(component._sync_active_spool())
        asyncio.run(component._sync_active_spool())
        component._toolhead_extruder = "extruder3"
        asyncio.run(component._sync_active_spool())

        self.assertEqual(spoolman.active_spool_calls, [103, 104])


if __name__ == "__main__":
    unittest.main(verbosity=2)
