#!/usr/bin/env python3
"""T1 (issue #122) — hosted backend configuration wiring regression check.

Scans App/Voxtr.xcodeproj/project.pbxproj, both apps' Info.plist files and
Sources/VoxtrAppShell/CompositionRootLoaderView.swift directly (plain
text, no `plutil`/PyObjC dependency — runs identically on Codemagic's
macOS runners and any Linux CI/sandbox), the same approach as
`check_release_signing_enabled.py`. This is a static SOURCE/WIRING check,
run at PR time before any real secret exists; the actual PROCESSED/
SIGNED Info.plist of a real Release archive is validated separately by
`Scripts/validate_hosted_backend_config.sh`, which this script does not
duplicate.

Fails if either app's Debug build settings drift from the committed
local-development defaults, either app's Release build settings are
anything other than the committed empty-string placeholders (a non-empty
Release value here would mean project-specific key material was
accidentally committed to the repository), either Info.plist stops
declaring the two `$(VOXTR_HOSTED_*)` keys, or
`CompositionRootLoaderView.swift` stops calling
`HostedBackendConfigurationResolver.resolveFromMainBundle()` from its
Release-only branch — i.e. the same placeholder/default issue audited
for `CompositionRoot.build`'s own callers at the time this task shipped,
re-checked on every PR going forward.

Deliberately NOT a general Xcode-project linter and NOT a new test
framework — a single, dependency-free script matching this repo's own
established `Scripts/*.py` CI-check pattern, wired into `pr-validation`'s
existing "Validate project" step.
"""

import re
import sys
from pathlib import Path

PBXPROJ_PATH = "App/Voxtr.xcodeproj/project.pbxproj"
LOADER_PATH = "Sources/VoxtrAppShell/CompositionRootLoaderView.swift"

# (human label, marker that identifies this app's OWN buildSettings block,
#  Info.plist path)
APPS = [
    ("AthleteApp", "PRODUCT_BUNDLE_IDENTIFIER = app.voxtr.athlete;", "App/AthleteApp/Info.plist"),
    ("ParentApp", "PRODUCT_BUNDLE_IDENTIFIER = app.voxtr.parent;", "App/ParentApp/Info.plist"),
]

EXPECTED_DEBUG_BASE_URL = 'VOXTR_HOSTED_BACKEND_BASE_URL = "http://localhost:54321/functions/v1";'
EXPECTED_DEBUG_ANON_KEY = "VOXTR_HOSTED_SUPABASE_ANON_KEY = REPLACE_WITH_SUPABASE_ANON_KEY;"
EXPECTED_RELEASE_BASE_URL = 'VOXTR_HOSTED_BACKEND_BASE_URL = "";'
EXPECTED_RELEASE_ANON_KEY = 'VOXTR_HOSTED_SUPABASE_ANON_KEY = "";'

INFOPLIST_BASE_URL_KEY = "<key>VoxtrHostedBackendBaseURL</key>"
INFOPLIST_BASE_URL_VALUE = "<string>$(VOXTR_HOSTED_BACKEND_BASE_URL)</string>"
INFOPLIST_ANON_KEY_KEY = "<key>VoxtrHostedSupabaseAnonKey</key>"
INFOPLIST_ANON_KEY_VALUE = "<string>$(VOXTR_HOSTED_SUPABASE_ANON_KEY)</string>"

LOADER_RESOLVER_CALL = "HostedBackendConfigurationResolver.resolveFromMainBundle()"

CONFIG_BLOCK_RE = re.compile(
    r"[0-9A-F]{24} /\* \w+ \*/ = \{\s*"
    r"isa = XCBuildConfiguration;\s*"
    r"buildSettings = \{(?P<settings>.*?)\};\s*"
    r"name = (?P<name>\w+);\s*"
    r"\};",
    re.DOTALL,
)


def find_block(text: str, marker: str, config_name: str) -> str | None:
    for match in CONFIG_BLOCK_RE.finditer(text):
        if match.group("name") != config_name:
            continue
        settings = match.group("settings")
        if marker in settings:
            return settings
    return None


def main() -> int:
    pbxproj_path = Path(PBXPROJ_PATH)
    loader_path = Path(LOADER_PATH)
    if not pbxproj_path.is_file():
        print(f"FAILING: {PBXPROJ_PATH} not found.", file=sys.stderr)
        return 1
    if not loader_path.is_file():
        print(f"FAILING: {LOADER_PATH} not found.", file=sys.stderr)
        return 1

    pbxproj_text = pbxproj_path.read_text()
    loader_text = loader_path.read_text()

    failures: list[str] = []

    for app_name, marker, infoplist_path_str in APPS:
        debug_settings = find_block(pbxproj_text, marker, "Debug")
        release_settings = find_block(pbxproj_text, marker, "Release")

        if debug_settings is None:
            failures.append(f"{app_name}: could not find its Debug XCBuildConfiguration (marker '{marker}').")
        else:
            if EXPECTED_DEBUG_BASE_URL not in debug_settings:
                failures.append(f"{app_name} Debug no longer sets the committed local-development VOXTR_HOSTED_BACKEND_BASE_URL default.")
            if EXPECTED_DEBUG_ANON_KEY not in debug_settings:
                failures.append(f"{app_name} Debug no longer sets the committed placeholder VOXTR_HOSTED_SUPABASE_ANON_KEY default.")

        if release_settings is None:
            failures.append(f"{app_name}: could not find its Release XCBuildConfiguration (marker '{marker}').")
        else:
            if EXPECTED_RELEASE_BASE_URL not in release_settings:
                failures.append(
                    f"{app_name} Release VOXTR_HOSTED_BACKEND_BASE_URL is not the committed empty placeholder — "
                    f"this must never contain project-specific key material in the repository."
                )
            if EXPECTED_RELEASE_ANON_KEY not in release_settings:
                failures.append(
                    f"{app_name} Release VOXTR_HOSTED_SUPABASE_ANON_KEY is not the committed empty placeholder — "
                    f"this must never contain project-specific key material in the repository."
                )

        infoplist_path = Path(infoplist_path_str)
        if not infoplist_path.is_file():
            failures.append(f"{app_name}: {infoplist_path_str} not found.")
        else:
            infoplist_text = infoplist_path.read_text()
            for label, needle in (
                ("VoxtrHostedBackendBaseURL key", INFOPLIST_BASE_URL_KEY),
                ("VoxtrHostedBackendBaseURL $(VAR) value", INFOPLIST_BASE_URL_VALUE),
                ("VoxtrHostedSupabaseAnonKey key", INFOPLIST_ANON_KEY_KEY),
                ("VoxtrHostedSupabaseAnonKey $(VAR) value", INFOPLIST_ANON_KEY_VALUE),
            ):
                if needle not in infoplist_text:
                    failures.append(f"{app_name}: {infoplist_path_str} is missing the {label}.")

    if LOADER_RESOLVER_CALL not in loader_text:
        failures.append(
            f"{LOADER_PATH} no longer calls {LOADER_RESOLVER_CALL} — "
            f"a Release build could silently fall back to the Debug "
            f"local-development defaults instead of failing closed."
        )
    if "#if DEBUG" not in loader_text or "#else" not in loader_text:
        failures.append(f"{LOADER_PATH} no longer has a #if DEBUG / #else split around CompositionRoot.build() — see this task's own rationale.")

    if failures:
        print("FAILING: hosted backend configuration wiring check found problems:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print("OK: hosted backend configuration wiring (Debug defaults, Release placeholders, Info.plist keys, loader resolver call) is intact for both apps.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
