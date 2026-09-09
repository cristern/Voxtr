#!/usr/bin/env python3
"""AthleteApp Release signing closeout — smallest regression check.

Scans App/Voxtr.xcodeproj/project.pbxproj directly (plain text, no
`plutil`/PyObjC dependency, so this runs identically on Codemagic's macOS
runners and any Linux CI/sandbox) and fails if the Release
XCBuildConfiguration for either app target sets
`CODE_SIGNING_ALLOWED = NO` or `CODE_SIGNING_REQUIRED = NO` — the exact
project-level setting that silently strips real code signing (and with
it, the CloudKit entitlements a signed archive/export needs) from a
Release build, the class of defect this closeout fixed for AthleteApp
after ParentApp had already hit it in production.

Deliberately NOT a general Xcode-project linter and NOT a new test
framework — a single, dependency-free script matching this repo's own
established `Scripts/*.py` CI-check pattern (see `pick_simulator.py`,
`xcresult_to_junit.py`), wired into `pr-validation`'s existing "Validate
project" step. Debug configurations are untouched by design (see
App/Voxtr.xcodeproj/project.pbxproj's own Debug blocks) and are
deliberately NOT checked here — only Release, which is what an archived/
exported/TestFlight build actually uses.
"""

import re
import sys
from pathlib import Path

PBXPROJ_PATH = "App/Voxtr.xcodeproj/project.pbxproj"

# (human label, marker that identifies this app's OWN buildSettings block)
APPS = [
    ("AthleteApp", "PRODUCT_BUNDLE_IDENTIFIER = app.voxtr.athlete;"),
    ("ParentApp", "PRODUCT_BUNDLE_IDENTIFIER = app.voxtr.parent;"),
]

DISABLING_SETTINGS = ("CODE_SIGNING_ALLOWED = NO;", "CODE_SIGNING_REQUIRED = NO;")

CONFIG_BLOCK_RE = re.compile(
    r"[0-9A-F]{24} /\* \w+ \*/ = \{\s*"
    r"isa = XCBuildConfiguration;\s*"
    r"buildSettings = \{(?P<settings>.*?)\};\s*"
    r"name = (?P<name>\w+);\s*"
    r"\};",
    re.DOTALL,
)


def main() -> int:
    pbxproj_path = Path(PBXPROJ_PATH)
    if not pbxproj_path.is_file():
        print(f"FAILING: {PBXPROJ_PATH} not found.", file=sys.stderr)
        return 1

    text = pbxproj_path.read_text()

    failures = []
    for app_name, marker in APPS:
        release_settings = None
        for match in CONFIG_BLOCK_RE.finditer(text):
            if match.group("name") != "Release":
                continue
            settings = match.group("settings")
            if marker in settings:
                release_settings = settings
                break

        if release_settings is None:
            failures.append(
                f"{app_name}: could not find its Release XCBuildConfiguration "
                f"(looked for the marker '{marker}') — this check may need "
                f"updating if the project structure genuinely changed."
            )
            continue

        for disabling_setting in DISABLING_SETTINGS:
            if disabling_setting in release_settings:
                failures.append(
                    f"{app_name} Release still sets '{disabling_setting}' — "
                    f"this silently strips real code signing (and with it, "
                    f"CloudKit entitlements) from the archived/exported "
                    f"Release build. See the AthleteApp Release signing "
                    f"closeout for why this must never be reintroduced."
                )

    if failures:
        print("FAILING: Release signing regression check found problems:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print("OK: neither AthleteApp nor ParentApp Release disables code signing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
