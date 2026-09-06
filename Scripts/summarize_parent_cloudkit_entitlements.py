#!/usr/bin/env python3
"""ParentApp CloudKit sharing runtime crash (build 502/507/511/516) —
signed-entitlements diagnostic follow-up.

Reads the FINAL SIGNED ParentApp entitlements (extracted from the exported
.ipa via `codesign -d --entitlements :-`, never the source .entitlements
file or the .xcarchive) and, when available, the embedded provisioning
profile's own Entitlements dictionary, and writes a small human-readable
comparison against the two CloudKit/iCloud entitlements this app's runtime
CKContainer construction requires. Deliberately does not fail the build or
normalize values away — MISMATCH is reported plainly so a human decides the
next step (see codemagic.yaml's own comment for the surrounding context).
"""

import argparse
import plistlib
import sys
from pathlib import Path

ICLOUD_SERVICES_KEY = "com.apple.developer.icloud-services"
ICLOUD_CONTAINERS_KEY = "com.apple.developer.icloud-container-identifiers"
ICLOUD_ENVIRONMENT_KEY = "com.apple.developer.icloud-container-environment"
REQUIRED_SERVICE = "CloudKit"


def load_plist(path: str):
    if not path:
        return None
    p = Path(path)
    if not p.is_file() or p.stat().st_size == 0:
        return None
    with p.open("rb") as f:
        return plistlib.load(f)


def as_list(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return list(value)
    return [value]


def format_values(values) -> str:
    values = as_list(values)
    if not values:
        return "(absent)"
    return ", ".join(str(v) for v in values)


def contains(values, expected) -> bool:
    return expected in as_list(values)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--signed-entitlements", required=True)
    parser.add_argument("--profile-entitlements", default="")
    parser.add_argument("--expected-container", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    signed = load_plist(args.signed_entitlements)
    profile = load_plist(args.profile_entitlements)

    lines = []
    lines.append("ParentApp CloudKit/iCloud signed-entitlements comparison")
    lines.append("=" * 58)
    lines.append("")
    lines.append("Source expected (App/ParentApp/ParentApp.entitlements):")
    lines.append(f"  {ICLOUD_SERVICES_KEY} -> expected to contain: {REQUIRED_SERVICE}")
    lines.append(f"  {ICLOUD_CONTAINERS_KEY} -> expected to contain: {args.expected_container}")
    lines.append("")

    if signed is None:
        lines.append("FINAL SIGNED APP (from the exported .ipa):")
        lines.append("  Could not be read — this file should not be missing if the")
        lines.append("  codesign extraction step itself succeeded; treat as MISMATCH.")
        signed_services = []
        signed_containers = []
        signed_environment = None
    else:
        signed_services = signed.get(ICLOUD_SERVICES_KEY)
        signed_containers = signed.get(ICLOUD_CONTAINERS_KEY)
        signed_environment = signed.get(ICLOUD_ENVIRONMENT_KEY)
        lines.append("FINAL SIGNED APP (from the exported .ipa, via codesign -d --entitlements :-):")
        lines.append(f"  {ICLOUD_SERVICES_KEY} = {format_values(signed_services)}")
        lines.append(f"  {ICLOUD_CONTAINERS_KEY} = {format_values(signed_containers)}")
        lines.append(f"  {ICLOUD_ENVIRONMENT_KEY} = {format_values(signed_environment)}")
    lines.append("")

    if args.profile_entitlements and profile is None:
        lines.append("PROVISIONING PROFILE (embedded.mobileprovision):")
        lines.append("  Not available for this build — either no profile was embedded")
        lines.append("  (expected/normal for some App Store Connect API-key signing")
        lines.append("  flows) or it could not be decoded. Not fabricated.")
    elif profile is not None:
        profile_services = profile.get(ICLOUD_SERVICES_KEY)
        profile_containers = profile.get(ICLOUD_CONTAINERS_KEY)
        profile_environment = profile.get(ICLOUD_ENVIRONMENT_KEY)
        lines.append("PROVISIONING PROFILE (embedded.mobileprovision -> Entitlements):")
        lines.append(f"  {ICLOUD_SERVICES_KEY} = {format_values(profile_services)}")
        lines.append(f"  {ICLOUD_CONTAINERS_KEY} = {format_values(profile_containers)}")
        lines.append(f"  {ICLOUD_ENVIRONMENT_KEY} = {format_values(profile_environment)}")
    else:
        lines.append("PROVISIONING PROFILE:")
        lines.append("  Not inspected (no embedded.mobileprovision found in this app bundle).")
    lines.append("")

    services_match = contains(signed_services, REQUIRED_SERVICE)
    containers_match = contains(signed_containers, args.expected_container)

    lines.append("COMPARISON RESULT (final signed app is the authoritative check):")
    lines.append(
        f"  {ICLOUD_SERVICES_KEY} contains '{REQUIRED_SERVICE}': "
        f"{'MATCH' if services_match else 'MISMATCH'}"
    )
    lines.append(
        f"  {ICLOUD_CONTAINERS_KEY} contains '{args.expected_container}': "
        f"{'MATCH' if containers_match else 'MISMATCH'}"
    )
    lines.append("")
    if services_match and containers_match:
        lines.append("OVERALL: MATCH — the signed app carries both required CloudKit")
        lines.append("entitlements. The CKContainer-realization crash is not explained")
        lines.append("by a missing/incorrect entitlement in this build; look elsewhere")
        lines.append("(e.g. Apple Developer Portal container/environment state, or a")
        lines.append("CloudKit-service-side condition) rather than repo signing config.")
    else:
        lines.append("OVERALL: MISMATCH — the signed app is missing (or has an incorrect")
        lines.append("value for) at least one required CloudKit entitlement. This is")
        lines.append("consistent with the observed CKContainer-realization crash and")
        lines.append("points at the Apple Developer Portal App ID capability/container")
        lines.append("assignment for this bundle identifier, not at this repository's")
        lines.append("source .entitlements file (which already declares both correctly —")
        lines.append("see Task 1/2 of the prior audit).")

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n")

    print(f"Wrote {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
