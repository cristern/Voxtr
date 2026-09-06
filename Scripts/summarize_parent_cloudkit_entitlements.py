#!/usr/bin/env python3
"""ParentApp CloudKit sharing runtime crash (build 502/507/511/516) —
signed-entitlements diagnostic follow-up.

Reads the canonical SOURCE entitlements this repository requests
(App/ParentApp/ParentApp.entitlements — One Truth for what is requested),
the FINAL SIGNED ParentApp entitlements (extracted from the exported .ipa
via `codesign -d --entitlements :-` — authority for what actually shipped),
and, when available, the embedded provisioning profile's own Entitlements
dictionary (supporting evidence for what signing allowed), and writes a
small human-readable comparison of the final signed app against the actual
source-requested values for the two CloudKit/iCloud entitlements this
app's runtime CKContainer construction requires.

Deliberately never hardcodes "CloudKit"/a container identifier as the
comparison authority — both are read from the source .entitlements file
each run, so this stays correct if that file ever changes. Deliberately
does not fail the build or normalize values away — MISMATCH is reported
plainly so a human decides the next step (see codemagic.yaml's own comment
for the surrounding context).
"""

import argparse
import plistlib
import sys
from pathlib import Path

ICLOUD_SERVICES_KEY = "com.apple.developer.icloud-services"
ICLOUD_CONTAINERS_KEY = "com.apple.developer.icloud-container-identifiers"
ICLOUD_ENVIRONMENT_KEY = "com.apple.developer.icloud-container-environment"
CRITICAL_KEYS = (ICLOUD_SERVICES_KEY, ICLOUD_CONTAINERS_KEY)


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


def requested_values_present(requested, actual) -> bool:
    """True iff every value the source requests also appears in `actual`."""
    requested = as_list(requested)
    if not requested:
        # Nothing requested for this key is not a meaningful comparison —
        # treated as satisfied so it never manufactures a false MISMATCH
        # for a key this app does not actually request.
        return True
    actual = as_list(actual)
    return all(value in actual for value in requested)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-entitlements", required=True)
    parser.add_argument("--signed-entitlements", required=True)
    parser.add_argument("--profile-entitlements", default="")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    source = load_plist(args.source_entitlements)
    if source is None:
        print(
            f"FAILING: could not read source entitlements at "
            f"{args.source_entitlements} — this is the One Truth for what "
            f"ParentApp requests; refusing to fabricate a comparison "
            f"without it.",
            file=sys.stderr,
        )
        return 1

    signed = load_plist(args.signed_entitlements)
    profile = load_plist(args.profile_entitlements)

    source_services = source.get(ICLOUD_SERVICES_KEY)
    source_containers = source.get(ICLOUD_CONTAINERS_KEY)

    lines = []
    lines.append("ParentApp CloudKit/iCloud signed-entitlements comparison")
    lines.append("=" * 58)
    lines.append("")
    lines.append(f"Source requested (from {args.source_entitlements}):")
    lines.append(f"  {ICLOUD_SERVICES_KEY} = {format_values(source_services)}")
    lines.append(f"  {ICLOUD_CONTAINERS_KEY} = {format_values(source_containers)}")
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

    profile_services = None
    profile_containers = None
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

    services_match = requested_values_present(source_services, signed_services)
    containers_match = requested_values_present(source_containers, signed_containers)

    lines.append("COMPARISON RESULT (final signed app vs. source-requested values):")
    lines.append(
        f"  {ICLOUD_SERVICES_KEY}: signed app carries every source-requested value: "
        f"{'MATCH' if services_match else 'MISMATCH'}"
    )
    lines.append(
        f"  {ICLOUD_CONTAINERS_KEY}: signed app carries every source-requested value: "
        f"{'MATCH' if containers_match else 'MISMATCH'}"
    )

    if profile is not None:
        profile_services_match = requested_values_present(source_services, profile_services)
        profile_containers_match = requested_values_present(source_containers, profile_containers)
        lines.append("")
        lines.append("  Provisioning profile permits the same source-requested values (informational):")
        lines.append(
            f"    {ICLOUD_SERVICES_KEY}: "
            f"{'MATCH' if profile_services_match else 'MISMATCH'}"
        )
        lines.append(
            f"    {ICLOUD_CONTAINERS_KEY}: "
            f"{'MATCH' if profile_containers_match else 'MISMATCH'}"
        )

    lines.append("")
    if services_match and containers_match:
        lines.append("OVERALL: MATCH — the required source-requested CloudKit entitlements")
        lines.append("survived into the final signed app. This does not by itself prove the")
        lines.append("Apple Developer Portal container assignment is correct, nor that")
        lines.append("CloudKit will succeed at runtime — it only confirms the signing/export")
        lines.append("boundary did not drop or alter what this repository requested.")
    else:
        lines.append("OVERALL: MISMATCH — the final signed app does not carry every CloudKit")
        lines.append("entitlement value this repository's source .entitlements file requests.")
        lines.append("The discrepancy is somewhere in the signing/provisioning/export")
        lines.append("boundary — possible causes include the provisioning profile's own")
        lines.append("capability/container assignment, profile selection, export/re-signing,")
        lines.append("or Apple Developer Portal configuration. Further evidence (e.g. the")
        lines.append("provisioning-profile comparison above, if available) decides which.")

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n")

    print(f"Wrote {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
