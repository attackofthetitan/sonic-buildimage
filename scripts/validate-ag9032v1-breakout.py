#!/usr/bin/env python3
"""Validate the AG9032v1 metadata and BCM flex-port configuration."""

import argparse
import json
import re
import sys
from pathlib import Path


PLATFORM_DIR = Path("device/delta/x86_64-delta_ag9032v1-r0")
PLATFORM_JSON = PLATFORM_DIR / "platform.json"
HWSKU_JSON = PLATFORM_DIR / "Delta-ag9032v1/hwsku.json"
BCM_CONFIG = PLATFORM_DIR / "Delta-ag9032v1/th-ag9032v1-32x100G.config.bcm"

BREAKOUT_MODES = {
    "1x100G[40G]": (0,),
    "2x50G": (0, 2),
    "4x25G[10G]": (0, 1, 2, 3),
}
DEFAULT_BREAKOUT_MODE = "1x100G[40G]"
PORT_GROUP_BASES = tuple(
    base
    for tile_start in (1, 34, 68, 102)
    for base in range(tile_start, tile_start + 32, 4)
)
EXPECTED_BCM_PORTS = frozenset(
    base + offset for base in PORT_GROUP_BASES for offset in range(4)
)


def describe_set(values):
    """Return a compact, deterministic rendering of a set."""
    ordered = sorted(values, key=lambda value: (str(type(value)), str(value)))
    if len(ordered) <= 12:
        return repr(ordered)
    return repr(ordered[:6] + ["..."] + ordered[-6:])


def check_exact_set(actual, expected, label, errors):
    missing = set(expected) - set(actual)
    extra = set(actual) - set(expected)
    if missing:
        errors.append("{} is missing {}".format(label, describe_set(missing)))
    if extra:
        errors.append("{} has unexpected {}".format(label, describe_set(extra)))


def load_json(path, errors):
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, ValueError) as error:
        errors.append("cannot read {}: {}".format(path, error))
        return {}


def parse_bcm(path, errors):
    properties = {}
    try:
        with path.open(encoding="utf-8") as stream:
            for line_number, raw_line in enumerate(stream, 1):
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = (part.strip() for part in line.split("=", 1))
                properties.setdefault(key, []).append((value, line_number))
    except OSError as error:
        errors.append("cannot read {}: {}".format(path, error))
    return properties


def single_value(properties, key, errors):
    entries = properties.get(key, ())
    if len(entries) != 1:
        errors.append(
            "{} must occur exactly once (found {})".format(key, len(entries))
        )
        return None
    return entries[0][0]


def parse_integer(value, label, errors):
    if value is None:
        return None
    try:
        return int(value, 0)
    except ValueError:
        errors.append("{} is not an integer: {!r}".format(label, value))
        return None


def validate_metadata(platform, hwsku, errors):
    expected_names = {"Ethernet{}".format(base) for base in range(0, 128, 4)}
    platform_interfaces = platform.get("interfaces", {})
    hwsku_interfaces = hwsku.get("interfaces", {})

    if not isinstance(platform_interfaces, dict):
        errors.append("platform.json interfaces must be an object")
        platform_interfaces = {}
    if not isinstance(hwsku_interfaces, dict):
        errors.append("hwsku.json interfaces must be an object")
        hwsku_interfaces = {}

    check_exact_set(
        platform_interfaces, expected_names, "platform.json interfaces", errors
    )
    check_exact_set(hwsku_interfaces, expected_names, "hwsku.json interfaces", errors)

    all_lanes = []
    all_indices = []
    for ordinal, base in enumerate(range(0, 128, 4), 1):
        name = "Ethernet{}".format(base)
        interface = platform_interfaces.get(name)
        if not isinstance(interface, dict):
            if name in platform_interfaces:
                errors.append("platform interface {} must be an object".format(name))
            continue

        try:
            lanes = [int(lane) for lane in interface.get("lanes", "").split(",")]
        except ValueError:
            lanes = []
        if len(lanes) != 4:
            errors.append("{} must have four integer lanes".format(name))
        else:
            all_lanes.extend(lanes)

        try:
            indices = [int(index) for index in interface.get("index", "").split(",")]
        except ValueError:
            indices = []
        if indices != [ordinal] * 4:
            errors.append(
                "{} index must be {!r}, found {!r}".format(
                    name, [ordinal] * 4, indices
                )
            )
        else:
            all_indices.append(ordinal)

        modes = interface.get("breakout_modes", {})
        if not isinstance(modes, dict):
            errors.append("{} breakout_modes must be an object".format(name))
            modes = {}
        check_exact_set(modes, BREAKOUT_MODES, "{} breakout modes".format(name), errors)
        for mode, offsets in BREAKOUT_MODES.items():
            expected_children = ["Ethernet{}".format(base + offset) for offset in offsets]
            if modes.get(mode) != expected_children:
                errors.append(
                    "{} {} children must be {!r}, found {!r}".format(
                        name, mode, expected_children, modes.get(mode)
                    )
                )

        hwsku_interface = hwsku_interfaces.get(name)
        if not isinstance(hwsku_interface, dict):
            if name in hwsku_interfaces:
                errors.append("HWSKU interface {} must be an object".format(name))
            continue
        default_mode = hwsku_interface.get("default_brkout_mode")
        if default_mode != DEFAULT_BREAKOUT_MODE:
            errors.append(
                "{} default breakout mode must be {!r}, found {!r}".format(
                    name, DEFAULT_BREAKOUT_MODE, default_mode
                )
            )
        elif default_mode not in modes:
            errors.append(
                "{} HWSKU default mode is absent from platform.json".format(name)
            )

    if len(all_lanes) == 128:
        check_exact_set(all_lanes, range(1, 129), "platform lanes", errors)
    if len(all_indices) == 32:
        check_exact_set(all_indices, range(1, 33), "platform indices", errors)


def validate_portmaps(properties, errors):
    portmap_pattern = re.compile(r"portmap_(\d+)\.0")
    portmaps = {}
    for key, entries in properties.items():
        if not key.startswith("portmap_"):
            continue
        match = portmap_pattern.fullmatch(key)
        if not match:
            errors.append("malformed active portmap property: {}".format(key))
            continue
        port = int(match.group(1))
        if len(entries) != 1:
            errors.append("{} must occur exactly once".format(key))
        else:
            portmaps[port] = entries[0][0]

    check_exact_set(portmaps, EXPECTED_BCM_PORTS, "BCM portmaps", errors)
    for group_number, base in enumerate(PORT_GROUP_BASES):
        for offset, suffix in enumerate(("100", "25:i", "25:50:i", "25:i")):
            port = base + offset
            expected_value = "{}:{}".format(group_number * 4 + offset + 1, suffix)
            if portmaps.get(port) != expected_value:
                errors.append(
                    "portmap_{}.0 must be {!r}, found {!r}".format(
                        port, expected_value, portmaps.get(port)
                    )
                )


def validate_bitmaps(properties, errors):
    for key in (
        "port_flex_enable",
        "oversubscribe_mode",
        "oversubscribe_mixed_sister_25_50_enable",
    ):
        enabled = parse_integer(single_value(properties, key, errors), key, errors)
        if enabled is not None and enabled != 1:
            errors.append("{} must be 1".format(key))

    expected_bitmap = sum(1 << port for port in EXPECTED_BCM_PORTS)
    for key in ("pbmp_xport_xe", "pbmp_oversubscribe"):
        value = parse_integer(single_value(properties, key, errors), key, errors)
        if value is not None and value != expected_bitmap:
            errors.append(
                "{} must cover exactly the 128 portmaps (expected {:#x}, found {:#x})".format(
                    key, expected_bitmap, value
                )
            )


def validate_lane_maps(properties, errors):
    """Check that each physical four-lane group retains one board lane map."""
    expected_bases = set(PORT_GROUP_BASES)
    for direction in ("tx", "rx"):
        prefix = "xgxs_{}_lane_map_".format(direction)
        pattern = re.compile(re.escape(prefix) + r"(\d+)")
        bases = set()
        for key, entries in properties.items():
            if not key.startswith(prefix):
                continue
            match = pattern.fullmatch(key)
            if not match:
                errors.append("malformed active lane-map property: {}".format(key))
                continue
            if len(entries) != 1:
                errors.append("{} must occur exactly once".format(key))
                continue
            bases.add(int(match.group(1)))
        check_exact_set(
            bases, expected_bases, "{} physical lane-map bases".format(direction), errors
        )


def validate_polarity(properties, direction, errors):
    prefix = "phy_xaui_{}_polarity_flip_".format(direction)
    pattern = re.compile(re.escape(prefix) + r"(\d+)")
    values = {}
    for key, entries in properties.items():
        if not key.startswith(prefix):
            continue
        match = pattern.fullmatch(key)
        if not match:
            errors.append("malformed active polarity property: {}".format(key))
            continue
        port = int(match.group(1))
        if len(entries) != 1:
            errors.append("{} must occur exactly once".format(key))
            continue
        value = parse_integer(entries[0][0], key, errors)
        if value is not None:
            values[port] = value

    check_exact_set(values, EXPECTED_BCM_PORTS, "{} polarity ports".format(direction), errors)
    for base in PORT_GROUP_BASES:
        parent_mask = values.get(base)
        if parent_mask is None:
            continue
        if parent_mask < 0 or parent_mask > 0xF:
            errors.append(
                "{}{} must be a four-lane mask, found {:#x}".format(
                    prefix, base, parent_mask
                )
            )
        for offset in range(1, 4):
            port = base + offset
            expected_value = parent_mask >> offset
            if values.get(port) != expected_value:
                errors.append(
                    "{}{} must be {}{} >> {} ({:#x}), found {!r}".format(
                        prefix,
                        port,
                        prefix,
                        base,
                        offset,
                        expected_value,
                        values.get(port),
                    )
                )


def validate_dport_map(properties, errors):
    enabled = parse_integer(
        single_value(properties, "dport_map_enable", errors),
        "dport_map_enable",
        errors,
    )
    pattern = re.compile(r"dport_map_port_(\d+)")
    mappings = {}
    for key, entries in properties.items():
        if not key.startswith("dport_map_port_"):
            continue
        match = pattern.fullmatch(key)
        if not match:
            errors.append("malformed active dport property: {}".format(key))
            continue
        port = int(match.group(1))
        if len(entries) != 1:
            errors.append("{} must occur exactly once".format(key))
            continue
        value = parse_integer(entries[0][0], key, errors)
        if value is not None:
            mappings[port] = value

    if enabled == 0:
        if mappings:
            errors.append("disabled dport mapping must not retain active port mappings")
        return
    if enabled is None:
        return

    check_exact_set(mappings, EXPECTED_BCM_PORTS, "enabled dport map", errors)
    if len(mappings) == 128 and len(set(mappings.values())) != 128:
        errors.append("enabled dport map values must be unique")


def validate_serdes_defaults(properties, errors):
    """Dynamic modes must use the SDK's speed-specific SerDes defaults."""
    overrides = sorted(
        key for key in properties if key.startswith("serdes_preemphasis")
    )
    if overrides:
        errors.append(
            "static SerDes pre-emphasis is unsafe across dynamic speeds; found {}".format(
                describe_set(overrides)
            )
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="sonic-buildimage checkout (defaults to this script's checkout)",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    errors = []

    platform = load_json(root / PLATFORM_JSON, errors)
    hwsku = load_json(root / HWSKU_JSON, errors)
    properties = parse_bcm(root / BCM_CONFIG, errors)

    validate_metadata(platform, hwsku, errors)
    validate_portmaps(properties, errors)
    validate_bitmaps(properties, errors)
    validate_lane_maps(properties, errors)
    validate_polarity(properties, "tx", errors)
    validate_polarity(properties, "rx", errors)
    validate_dport_map(properties, errors)
    validate_serdes_defaults(properties, errors)

    if errors:
        print("AG9032v1 breakout validation FAILED:", file=sys.stderr)
        for error in errors:
            print("  - {}".format(error), file=sys.stderr)
        return 1

    print("AG9032v1 breakout validation passed")
    print("  32 parent ports; 3 coherent breakout modes per port")
    print("  128 BCM portmaps covered by both port bitmaps")
    print("  128 shifted TX and RX polarity properties; dport disabled or complete")
    print("  static pre-emphasis omitted so SDK defaults can follow the active speed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
