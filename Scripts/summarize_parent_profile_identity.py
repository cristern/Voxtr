#!/usr/bin/env python3
"""ParentApp CloudKit sharing runtime crash — provisioning-profile identity
diagnostic follow-up (build 119 investigation).

PR #73's own diagnostic proved the final signed app AND its embedded
provisioning profile both lack the CloudKit/iCloud entitlements this
repository requests. A later, directly-downloaded, freshly regenerated
Apple profile was confirmed correct — meaning Codemagic embedded a
DIFFERENT (older/stale) profile than the one now on record at Apple. This
script exposes only the non-secret IDENTITY of whichever profile Codemagic
actually embedded (Name, UUID, CreationDate, ExpirationDate,
TeamIdentifier, application-identifier, and CloudKit entitlement
presence), so a human can compare it against the directly-downloaded
Apple profile's own identity (inspected externally, never inside this
build) and confirm whether Codemagic picked the correct one on the next
run.

Deliberately never reads or emits `DeveloperCertificates` (certificate
blobs), `ProvisionedDevices` (device UDIDs), or any other profile field
beyond the identity fields listed above.

AthleteApp Release signing closeout: generalized via --app-name (defaults
to "ParentApp" so an omitted flag reproduces this script's original
output text unchanged) — every other argument was already app-agnostic.
"""

import argparse
import plistlib
import sys
from pathlib import Path

SAFE_TOP_LEVEL_FIELDS = ("Name", "UUID", "CreationDate", "ExpirationDate", "TeamIdentifier")
ICLOUD_SERVICES_KEY = "com.apple.developer.icloud-services"
ICLOUD_CONTAINERS_KEY = "com.apple.developer.icloud-container-identifiers"


def format_value(value) -> str:
    if value is None:
        return "(absent)"
    if isinstance(value, (list, tuple)):
        return ", ".join(str(v) for v in value) if value else "(empty)"
    return str(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-name", default="ParentApp")
    parser.add_argument("--profile-plist", required=True, help="Full decoded embedded.mobileprovision plist")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    profile_path = Path(args.profile_plist)
    if not profile_path.is_file() or profile_path.stat().st_size == 0:
        print(f"FAILING: profile plist not found or empty at {args.profile_plist}", file=sys.stderr)
        return 1

    with profile_path.open("rb") as f:
        profile = plistlib.load(f)

    entitlements = profile.get("Entitlements", {})

    lines = []
    lines.append(f"{args.app_name} embedded provisioning-profile identity")
    lines.append("=" * 50)
    lines.append("")
    lines.append("Compare these fields against the Name/UUID/CreationDate shown when")
    lines.append("inspecting the directly-downloaded Apple profile locally (e.g. Apple")
    lines.append("Developer Portal > Profiles, or `security cms -D -i <file>.mobileprovision`")
    lines.append("run on your own machine) to confirm Codemagic embedded the SAME profile.")
    lines.append("")
    for field in SAFE_TOP_LEVEL_FIELDS:
        lines.append(f"  {field} = {format_value(profile.get(field))}")
    lines.append(f"  Entitlements:application-identifier = {format_value(entitlements.get('application-identifier'))}")
    lines.append("")
    lines.append("CloudKit entitlement presence in this profile's own Entitlements dictionary:")
    lines.append(f"  {ICLOUD_SERVICES_KEY} = {format_value(entitlements.get(ICLOUD_SERVICES_KEY))}")
    lines.append(f"  {ICLOUD_CONTAINERS_KEY} = {format_value(entitlements.get(ICLOUD_CONTAINERS_KEY))}")
    lines.append("")
    lines.append("NOT included by design (never extracted from this profile): DeveloperCertificates")
    lines.append("(certificate blobs), ProvisionedDevices (device UDIDs), or any other field.")

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n")

    print(f"Wrote {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
