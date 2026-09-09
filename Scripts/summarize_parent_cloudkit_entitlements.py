#!/usr/bin/env python3
"""ParentApp CloudKit sharing runtime crash (build 502/507/511/516/119/123) —
signed-entitlements diagnostic follow-up.

Reads the canonical SOURCE entitlements this repository requests
(App/ParentApp/ParentApp.entitlements — One Truth for what is requested),
the ARCHIVE's own signed entitlements (from build/ios/xcarchive/*.xcarchive
— what the archive build itself produced, before export/re-sign can alter
anything), the FINAL SIGNED ParentApp entitlements (extracted from the
exported .ipa via `codesign -d --entitlements :-` — authority for what
actually shipped), and, when available, the embedded provisioning
profile's own Entitlements dictionary (supporting evidence for what
signing allowed), and writes a small human-readable comparison that
localizes whether entitlement loss (if any) happens before/during the
archive build or only during export/re-sign.

Deliberately never hardcodes "CloudKit"/a container identifier as the
comparison authority — both are read from the source .entitlements file
each run, so this stays correct if that file ever changes. Deliberately
does not fail the build or normalize values away — MISMATCH is reported
plainly so a human decides the next step (see codemagic.yaml's own comment
for the surrounding context). This script's own exit code is always 0;
Scripts/capture_parent_signed_entitlements.sh (the caller) is what
decides, via its own optional FAIL_ON_MISMATCH flag, whether an "OVERALL:
MISMATCH" line in this report should fail the build.

AthleteApp Release signing closeout: generalized via --app-name (defaults
to "ParentApp" so an omitted flag reproduces this script's original
output text unchanged) — every other argument was already a plain path,
not Parent-specific.

PR #83 follow-up (Blocker 1 — iCloud environment): --expected-icloud-environment
is optional and defaults to "" (unchecked), so an omitted flag reproduces
this script's prior OVERALL determination unchanged (services/containers
only) — Parent's own historical report-only call never passes it. When
given (Athlete's TestFlight calls pass "Production"), the FINAL SIGNED
app's own com.apple.developer.icloud-container-environment must equal it
EXACTLY for OVERALL to read MATCH — this is a single-value distribution-
environment check, never a services/containers-style subset/wildcard
check, and never inferred from the source .entitlements file (which
intentionally never declares an environment — signing/export adds it).
The archive's own environment is still only reported for stage
localization, exactly like archive services/containers already are —
OVERALL remains authoritative over the FINAL SIGNED app only.

Build 123 follow-up: a correctly-selected provisioning profile can
legitimately authorize a service with the wildcard value "*" (e.g.
`com.apple.developer.icloud-services = "*"`) meaning "any iCloud service",
which is not a literal mismatch against a source request of "CloudKit" —
that wildcard semantic is handled ONLY in the profile-permits comparison
below (informational), never in the archive/final-signed-app comparisons,
which must still fail literally if the actual signed entitlements are
missing the requested value.
"""

import argparse
import plistlib
import sys
from pathlib import Path

ICLOUD_SERVICES_KEY = "com.apple.developer.icloud-services"
ICLOUD_CONTAINERS_KEY = "com.apple.developer.icloud-container-identifiers"
ICLOUD_ENVIRONMENT_KEY = "com.apple.developer.icloud-container-environment"
WILDCARD = "*"


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
    """True iff every value the source requests also appears LITERALLY in
    `actual`. Used for the archive/final-signed-app checks, which must
    never be satisfied by a wildcard — a signed app's own entitlements
    plist embeds the specific values it was signed with, not a wildcard
    authorization; a "*" appearing there would not be a normal outcome."""
    requested = as_list(requested)
    if not requested:
        # Nothing requested for this key is not a meaningful comparison —
        # treated as satisfied so it never manufactures a false MISMATCH
        # for a key this app does not actually request.
        return True
    actual = as_list(actual)
    return all(value in actual for value in requested)


def environment_matches(expected: str, actual) -> bool:
    """True iff `actual` (a signed app's own
    com.apple.developer.icloud-container-environment value) is EXACTLY
    `expected` — a single distribution-environment string, never a
    services/containers-style "every requested value present" subset
    check and never satisfied by a wildcard. `actual` is normally a
    plain string; a length-1 list is also accepted defensively (plist
    tooling can round-trip a scalar as a single-element array), but
    anything else (missing, multi-valued) is a MISMATCH."""
    if isinstance(actual, (list, tuple)):
        actual = actual[0] if len(actual) == 1 else None
    return actual == expected


def profile_permits(requested, profile_actual) -> bool:
    """True iff the provisioning profile AUTHORIZES every value the source
    requests. A profile's own `*` entry is Apple's documented wildcard
    meaning "any value for this key is authorized" (seen in practice on
    `com.apple.developer.icloud-services`) — satisfies any requested
    value for that key. This is provisioning-profile-specific semantics;
    never applied to the archive or final signed app's own entitlements."""
    requested = as_list(requested)
    if not requested:
        return True
    actual = as_list(profile_actual)
    if WILDCARD in actual:
        return True
    return all(value in actual for value in requested)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-name", default="ParentApp")
    parser.add_argument("--source-entitlements", required=True)
    parser.add_argument("--archive-entitlements", default="")
    parser.add_argument("--signed-entitlements", required=True)
    parser.add_argument("--profile-entitlements", default="")
    parser.add_argument(
        "--expected-icloud-environment",
        default="",
        help=(
            "e.g. 'Production' for a TestFlight/App Store release. Empty "
            "(default) means the environment is not checked at all, "
            "reproducing this script's original OVERALL determination — "
            "never inferred from --source-entitlements, which does not "
            "declare a distribution environment."
        ),
    )
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    source = load_plist(args.source_entitlements)
    if source is None:
        print(
            f"FAILING: could not read source entitlements at "
            f"{args.source_entitlements} — this is the One Truth for what "
            f"{args.app_name} requests; refusing to fabricate a comparison "
            f"without it.",
            file=sys.stderr,
        )
        return 1

    archive = load_plist(args.archive_entitlements)
    signed = load_plist(args.signed_entitlements)
    profile = load_plist(args.profile_entitlements)

    source_services = source.get(ICLOUD_SERVICES_KEY)
    source_containers = source.get(ICLOUD_CONTAINERS_KEY)

    lines = []
    lines.append(f"{args.app_name} CloudKit/iCloud signed-entitlements comparison")
    lines.append("=" * 58)
    lines.append("")
    lines.append(f"Source requested (from {args.source_entitlements}):")
    lines.append(f"  {ICLOUD_SERVICES_KEY} = {format_values(source_services)}")
    lines.append(f"  {ICLOUD_CONTAINERS_KEY} = {format_values(source_containers)}")
    lines.append("")

    if args.archive_entitlements and archive is None:
        lines.append("ARCHIVE SIGNED APP (build/ios/xcarchive/*.xcarchive):")
        lines.append("  Not available for this build — either no matching archived .app was")
        lines.append("  found, or codesign could not extract entitlements from it (which is")
        lines.append("  itself useful evidence: an unsigned archive would fail here). Not fabricated.")
        archive_services = []
        archive_containers = []
        archive_environment = None
    elif archive is not None:
        archive_services = archive.get(ICLOUD_SERVICES_KEY)
        archive_containers = archive.get(ICLOUD_CONTAINERS_KEY)
        archive_environment = archive.get(ICLOUD_ENVIRONMENT_KEY)
        lines.append("ARCHIVE SIGNED APP (from build/ios/xcarchive/*.xcarchive, via codesign):")
        lines.append(f"  {ICLOUD_SERVICES_KEY} = {format_values(archive_services)}")
        lines.append(f"  {ICLOUD_CONTAINERS_KEY} = {format_values(archive_containers)}")
        lines.append(f"  {ICLOUD_ENVIRONMENT_KEY} = {format_values(archive_environment)}")
    else:
        lines.append("ARCHIVE SIGNED APP:")
        lines.append("  Not inspected (no --archive-entitlements provided for this run).")
        archive_services = None
        archive_containers = None
        archive_environment = None
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

    # PR #83 follow-up (Blocker 1): only checked when the caller supplied
    # an expected environment at all — empty means "unchecked", exactly
    # this script's original behavior (Parent's own historical call).
    environment_required = bool(args.expected_icloud_environment)
    environment_match = (
        environment_matches(args.expected_icloud_environment, signed_environment)
        if environment_required
        else True
    )
    archive_environment_match = (
        environment_matches(args.expected_icloud_environment, archive_environment)
        if environment_required
        else True
    )

    lines.append("STAGE LOCALIZATION (where does entitlement loss occur, if anywhere?):")
    if archive is not None:
        archive_services_match = requested_values_present(source_services, archive_services)
        archive_containers_match = requested_values_present(source_containers, archive_containers)
        archive_line = (
            f"  Archive vs. source — {ICLOUD_SERVICES_KEY}: "
            f"{'MATCH' if archive_services_match else 'MISMATCH'}, "
            f"{ICLOUD_CONTAINERS_KEY}: "
            f"{'MATCH' if archive_containers_match else 'MISMATCH'}"
        )
        if environment_required:
            archive_line += f", {ICLOUD_ENVIRONMENT_KEY}: {'MATCH' if archive_environment_match else 'MISMATCH'}"
        lines.append(archive_line)
    else:
        archive_services_match = True
        archive_containers_match = True
        lines.append("  Archive vs. source: not available for this run (see ARCHIVE SIGNED APP above).")
    final_line = (
        f"  Final IPA vs. source — {ICLOUD_SERVICES_KEY}: "
        f"{'MATCH' if services_match else 'MISMATCH'}, "
        f"{ICLOUD_CONTAINERS_KEY}: "
        f"{'MATCH' if containers_match else 'MISMATCH'}"
    )
    if environment_required:
        final_line += (
            f", {ICLOUD_ENVIRONMENT_KEY}: {'MATCH' if environment_match else 'MISMATCH'} "
            f"(expected {args.expected_icloud_environment})"
        )
    lines.append(final_line)
    if archive is not None:
        if (archive_services_match and archive_containers_match) and not (services_match and containers_match):
            lines.append("  => Entitlements were present in the ARCHIVE but LOST during export/re-sign.")
        elif not (archive_services_match and archive_containers_match) and (services_match and containers_match):
            lines.append("  => Entitlements were MISSING in the archive but present in the final IPA (unexpected).")
        elif not (archive_services_match and archive_containers_match) and not (services_match and containers_match):
            lines.append("  => Entitlements were already missing at ARCHIVE time — loss occurs before/during archive, not export.")
        else:
            lines.append("  => Entitlements present at both archive and final IPA stages.")
    lines.append("")

    lines.append("COMPARISON RESULT (final signed app vs. source-requested values):")
    lines.append(
        f"  {ICLOUD_SERVICES_KEY}: signed app carries every source-requested value: "
        f"{'MATCH' if services_match else 'MISMATCH'}"
    )
    lines.append(
        f"  {ICLOUD_CONTAINERS_KEY}: signed app carries every source-requested value: "
        f"{'MATCH' if containers_match else 'MISMATCH'}"
    )
    if environment_required:
        lines.append(
            f"  {ICLOUD_ENVIRONMENT_KEY}: signed app matches the expected release "
            f"environment ({args.expected_icloud_environment}): "
            f"{'MATCH' if environment_match else 'MISMATCH'}"
        )

    if profile is not None:
        profile_services_match = profile_permits(source_services, profile_services)
        profile_containers_match = profile_permits(source_containers, profile_containers)
        lines.append("")
        lines.append("  Provisioning profile authorizes the same source-requested values (informational;")
        lines.append(f"  a profile value of \"{WILDCARD}\" authorizes any requested value for that key):")
        lines.append(
            f"    {ICLOUD_SERVICES_KEY}: "
            f"{'MATCH' if profile_services_match else 'MISMATCH'}"
        )
        lines.append(
            f"    {ICLOUD_CONTAINERS_KEY}: "
            f"{'MATCH' if profile_containers_match else 'MISMATCH'}"
        )

    lines.append("")
    overall_match = services_match and containers_match and environment_match
    if overall_match:
        lines.append("OVERALL: MATCH — the required source-requested CloudKit entitlements")
        lines.append("survived into the final signed app" + (
            f", and it is signed for the expected {args.expected_icloud_environment} "
            f"iCloud environment" if environment_required else ""
        ) + ". This does not by itself prove the")
        lines.append("Apple Developer Portal container assignment is correct, nor that")
        lines.append("CloudKit will succeed at runtime — it only confirms the signing/export")
        lines.append("boundary did not drop or alter what this repository requested.")
    else:
        lines.append("OVERALL: MISMATCH — the final signed app does not carry every CloudKit")
        lines.append("entitlement value this repository's source .entitlements file requests" + (
            ", or is not signed for the expected iCloud environment" if environment_required else ""
        ) + ".")
        lines.append("See STAGE LOCALIZATION above for whether this already happened at")
        lines.append("archive time or only during export/re-sign.")

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n")

    print(f"Wrote {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
