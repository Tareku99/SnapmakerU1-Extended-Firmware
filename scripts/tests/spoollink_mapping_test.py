#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

"""Offline regression tests for the SpoolLink lane/channel contract.

The printer-side SET_SPOOL_ID macro runs inside Klipper's Jinja environment,
which is not available in the small build-test image.  These tests therefore
read the production macro and AFC configuration, assert the mapping branches
are present, and execute the same branch order with representative AFC and
non-AFC objects.  The Moonraker test then exercises the production message
formatter directly.

This deliberately does not contact Spoolman, Klipper, ACE, or a printer.
"""

from __future__ import annotations

import asyncio
import importlib.util
import re
import sys
import unittest
from pathlib import Path
from types import ModuleType
from typing import Dict, Optional


ROOT = Path(__file__).resolve().parents[2]
AFC_CONFIG = (
    ROOT
    / "overlays/firmware-extended/31-feature-afc-lite/root/"
    "usr/local/share/firmware-config/tweaks/klipper/afc.cfg"
)
SPOOLLINK_MACRO = (
    ROOT
    / "overlays/firmware-extended/38-feature-spoollink/root/"
    "usr/local/share/spoollink/klipper.cfg"
)
MOONRAKER_SPOOLLINK = (
    ROOT
    / "overlays/firmware-extended/38-feature-spoollink/root/home/lava/"
    "moonraker/moonraker/components/spoollink.py"
)


def parse_afc_lane_map(text: str) -> Dict[str, int]:
    lanes: Dict[str, int] = {}
    section_re = re.compile(
        r"^\[AFC_lane ([^\]]+)\]\s*$([\s\S]*?)(?=^\[|\Z)",
        re.MULTILINE,
    )
    for match in section_re.finditer(text):
        lane_name, body = match.groups()
        lane_match = re.search(r"^lane:\s*(\d+)\s*$", body, re.MULTILINE)
        if lane_match:
            lanes[lane_name] = int(lane_match.group(1))
    return lanes


def resolve_macro_channel(
    lane: str,
    *,
    explicit_channel: Optional[int] = None,
    afc_lanes: Optional[Dict[str, int]] = None,
) -> int:
    """Model the branch order in SET_SPOOL_ID exactly."""

    if explicit_channel is not None:
        return int(explicit_channel)
    if afc_lanes is not None and lane in afc_lanes:
        return afc_lanes[lane]
    if lane.startswith("E") and len(lane) > 1 and lane[1:].isdigit():
        return int(lane[1:])
    raise ValueError(f"unknown lane: {lane}")


def load_moonraker_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "spoollink_component_under_test", MOONRAKER_SPOOLLINK
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {MOONRAKER_SPOOLLINK}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class SpoolLinkMappingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.afc_text = AFC_CONFIG.read_text(encoding="utf-8")
        cls.macro_text = SPOOLLINK_MACRO.read_text(encoding="utf-8")
        cls.afc_map = parse_afc_lane_map(cls.afc_text)

    def test_production_afc_config_defines_zero_based_e0_to_e3(self) -> None:
        self.assertEqual(self.afc_map, {"E0": 0, "E1": 1, "E2": 2, "E3": 3})

    def test_production_macro_contains_all_three_mapping_branches(self) -> None:
        required_fragments = (
            "{% if params.CHANNEL is defined %}",
            "{% set channel = params.CHANNEL|int %}",
            "'AFC_lane ' + lane in printer",
            "printer['AFC_lane ' + lane].lane",
            "lane.startswith('E')",
            "lane[1:]|int",
            "SET_PRINT_FILAMENT_CONFIG CONFIG_EXTRUDER={channel}",
        )
        for fragment in required_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.macro_text)

    def test_lane_mapping_with_afc_enabled(self) -> None:
        for lane, expected in self.afc_map.items():
            with self.subTest(lane=lane):
                self.assertEqual(
                    resolve_macro_channel(lane, afc_lanes=self.afc_map), expected
                )

    def test_lane_mapping_without_afc_uses_zero_based_suffix(self) -> None:
        for index in range(4):
            lane = f"E{index}"
            with self.subTest(lane=lane):
                self.assertEqual(resolve_macro_channel(lane, afc_lanes={}), index)

    def test_explicit_channel_wins_over_afc_lane_lookup(self) -> None:
        for index in range(4):
            with self.subTest(channel=index):
                self.assertEqual(
                    resolve_macro_channel(
                        "E3", explicit_channel=index, afc_lanes=self.afc_map
                    ),
                    index,
                )

    def test_e2_never_resolves_to_e3(self) -> None:
        self.assertEqual(resolve_macro_channel("E2", afc_lanes=self.afc_map), 2)
        self.assertEqual(resolve_macro_channel("E2", afc_lanes={}), 2)
        self.assertEqual(
            resolve_macro_channel("E2", explicit_channel=2, afc_lanes=self.afc_map),
            2,
        )
        self.assertNotEqual(resolve_macro_channel("E2", afc_lanes=self.afc_map), 3)

    def test_unknown_lane_is_rejected(self) -> None:
        for lane in ("", "E", "X2", "bad"):
            with self.subTest(lane=lane):
                with self.assertRaises(ValueError):
                    resolve_macro_channel(lane, afc_lanes={})

    def test_moonraker_reports_the_same_channel_it_applies(self) -> None:
        module = load_moonraker_module()

        async def exercise(channel: int) -> str:
            component = object.__new__(module.SpoolLink)
            component._force_generic_vendor = False
            messages = []

            async def capture(_self, applied_channel, message, **_kwargs):
                messages.append((applied_channel, message))
                return {}

            component._spoollink_set = capture.__get__(component)
            spool = {
                "id": 100 + channel,
                "filament": {
                    "material": "PLA",
                    "vendor": {"name": "Anycubic"},
                    "color_hex": "3366FF",
                },
            }
            await component._apply_spool(channel, spool, "")
            self.assertEqual(len(messages), 1)
            applied_channel, message = messages[0]
            self.assertEqual(applied_channel, channel)
            self.assertTrue(message.startswith(f"SpoolLink: E{channel} loaded "))
            return message

        for channel in range(4):
            with self.subTest(channel=channel):
                message = asyncio.run(exercise(channel))
                self.assertIn(f"E{channel} loaded", message)


if __name__ == "__main__":
    unittest.main(verbosity=2)
