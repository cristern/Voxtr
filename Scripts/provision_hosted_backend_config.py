#!/usr/bin/env python3
"""T1 (issue #122) — provision real hosted backend configuration into a
Codemagic Release build, in place, immediately before archiving.

This script patches the two committed, always-empty Release placeholder
lines in App/Voxtr.xcodeproj/project.pbxproj:

    VOXTR_HOSTED_BACKEND_BASE_URL = "";
    VOXTR_HOSTED_SUPABASE_ANON_KEY = "";

with the real values Codemagic provisions via the `voxtr_hosted_backend_t1`
environment variable group (see README: Codemagic Setup Requirements). It
runs only inside a TestFlight workflow's own ephemeral build checkout,
after `keychain initialize`/`use-profiles` and before the first
`xcode-project build-ipa` call — never on a PR build (`pr-validation` and
the two simulator-build workflows never set this environment group at
all, so this script is never invoked there), and its result is never
committed back to the repository.

Deliberately uses plain Python string `.replace()`, not `sed`: a Supabase
URL or anon key could in principle contain characters `sed` treats as
replacement-string metacharacters (`&`, backslashes, the delimiter itself)
and silently mis-substitute; Python's literal-string replace has no such
special-character interpretation. Deliberately requires an EXACT count of
two occurrences of each placeholder (one for AthleteApp's Release
configuration, one for ParentApp's) before patching, so any future drift
in the committed placeholder text, or an already-provisioned file, fails
loudly instead of silently patching the wrong thing or nothing at all.

Never prints either real value, in full or in part.
"""

import os
import sys
from pathlib import Path

PBXPROJ_PATH = Path("App/Voxtr.xcodeproj/project.pbxproj")

BASE_URL_PLACEHOLDER = 'VOXTR_HOSTED_BACKEND_BASE_URL = "";'
ANON_KEY_PLACEHOLDER = 'VOXTR_HOSTED_SUPABASE_ANON_KEY = "";'
EXPECTED_PLACEHOLDER_COUNT = 2  # AthleteApp Release + ParentApp Release


def require_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value.strip():
        print(f"FAILING: {name} is required and must be non-empty. Configure the 'voxtr_hosted_backend_t1' Codemagic environment variable group — see README: Codemagic Setup Requirements.", file=sys.stderr)
        sys.exit(1)
    return value


def reject_if_unsafe_for_pbxproj(name: str, value: str) -> None:
    # A value containing a double quote, semicolon, or newline could break
    # the surrounding `"..."`-quoted pbxproj build-setting line rather than
    # merely producing an invalid URL/key — fail closed before patching
    # instead of writing a corrupted project file.
    for forbidden, label in (('"', "a double quote"), (";", "a semicolon"), ("\n", "a newline"), ("\r", "a carriage return")):
        if forbidden in value:
            print(f"FAILING: {name} contains {label}, which is not valid inside a pbxproj quoted string. Refusing to patch.", file=sys.stderr)
            sys.exit(1)


def main() -> int:
    base_url = require_env("VOXTR_HOSTED_BACKEND_BASE_URL")
    anon_key = require_env("VOXTR_HOSTED_SUPABASE_ANON_KEY")
    reject_if_unsafe_for_pbxproj("VOXTR_HOSTED_BACKEND_BASE_URL", base_url)
    reject_if_unsafe_for_pbxproj("VOXTR_HOSTED_SUPABASE_ANON_KEY", anon_key)

    if not PBXPROJ_PATH.is_file():
        print(f"FAILING: {PBXPROJ_PATH} not found. This script must run from the repository root.", file=sys.stderr)
        return 1

    text = PBXPROJ_PATH.read_text()

    base_url_count = text.count(BASE_URL_PLACEHOLDER)
    anon_key_count = text.count(ANON_KEY_PLACEHOLDER)
    if base_url_count != EXPECTED_PLACEHOLDER_COUNT:
        print(
            f"FAILING: expected exactly {EXPECTED_PLACEHOLDER_COUNT} occurrences of the committed "
            f"VOXTR_HOSTED_BACKEND_BASE_URL empty placeholder in {PBXPROJ_PATH}, found {base_url_count}. "
            f"Refusing to patch an unexpected project state.",
            file=sys.stderr,
        )
        return 1
    if anon_key_count != EXPECTED_PLACEHOLDER_COUNT:
        print(
            f"FAILING: expected exactly {EXPECTED_PLACEHOLDER_COUNT} occurrences of the committed "
            f"VOXTR_HOSTED_SUPABASE_ANON_KEY empty placeholder in {PBXPROJ_PATH}, found {anon_key_count}. "
            f"Refusing to patch an unexpected project state.",
            file=sys.stderr,
        )
        return 1

    patched = text.replace(BASE_URL_PLACEHOLDER, f'VOXTR_HOSTED_BACKEND_BASE_URL = "{base_url}";')
    patched = patched.replace(ANON_KEY_PLACEHOLDER, f'VOXTR_HOSTED_SUPABASE_ANON_KEY = "{anon_key}";')
    PBXPROJ_PATH.write_text(patched)

    print(
        f"OK: provisioned hosted backend configuration into both apps' Release build settings "
        f"(base URL: {len(base_url)} characters, anon key: {len(anon_key)} characters; "
        f"values never printed)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
