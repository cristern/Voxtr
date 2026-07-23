#!/usr/bin/env python3
"""
Picks an available iPhone simulator's UDID from `xcrun simctl list devices
available -j` output. Used by codemagic.yaml instead of parsing
`xcodebuild -showdestinations`, which was observed to return an
incomplete destination list for the VoxtrTests scheme (a test-only
scheme with no host app) on at least one CI image — simctl queries the
actual installed runtimes directly and isn't scheme-filtered, so it's
the more reliable source here.

Prints the UDID to stdout on success (nothing else — this is meant to be
captured directly into a shell variable). Prints diagnostic info to
stderr. Exits non-zero with nothing on stdout if no candidate is found —
callers must treat empty stdout as a hard failure, not "try a default".
"""

import json
import subprocess
import sys


def main() -> int:
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"simctl failed (exit {result.returncode}): {result.stderr}", file=sys.stderr)
        return 1

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        print(f"Could not parse simctl output as JSON: {e}", file=sys.stderr)
        return 1

    candidates = []
    for runtime, devices in data.get("devices", {}).items():
        if "iOS" not in runtime:
            continue
        for d in devices:
            if d.get("isAvailable") and "iPhone" in d.get("name", ""):
                candidates.append((runtime, d["udid"], d["name"]))

    if not candidates:
        print("No available iPhone simulator found in any iOS runtime.", file=sys.stderr)
        print(f"Full device list was:\n{json.dumps(data, indent=2)}", file=sys.stderr)
        return 1

    # Runtime identifiers embed the iOS version (e.g. "com.apple.CoreSimulator.SimRuntime.iOS-26-4"),
    # which sorts correctly as a string for same-width version segments —
    # prefer the newest available runtime rather than an arbitrary one.
    candidates.sort(key=lambda c: c[0])
    runtime, udid, name = candidates[-1]
    print(f"Selected: {name} ({runtime}) — udid {udid}", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
