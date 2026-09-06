#!/usr/bin/env bash
# ParentApp CloudKit sharing runtime crash (build 502/507/511/516) —
# signed-entitlements diagnostic follow-up.
#
# Captures what is ACTUALLY present in the FINAL SIGNED, exported ParentApp
# .ipa and compares it against the canonical source
# App/ParentApp/ParentApp.entitlements (One Truth for what this repository
# requests) — never against hardcoded expected values, and never against
# the .xcarchive, because Xcode/Codemagic export/re-signing can still alter
# entitlements after archiving. Runs AFTER the "Archive and export
# ParentApp (Release)" step in each TestFlight workflow, on the IPA that
# step already produced; this script does not rebuild or re-sign anything.
#
# `testflight-release` builds AthleteApp and ParentApp into the SAME
# build/ios/ipa directory, so the correct file is picked by its
# CFBundleIdentifier (matched against $PARENT_BUNDLE_ID), never by
# filename — `testflight-parent` only ever produces one .ipa there, so the
# same lookup is still correct and this one script covers both workflows.
set -euo pipefail

: "${PARENT_BUNDLE_ID:?PARENT_BUNDLE_ID is required}"

IPA_DIR="build/ios/ipa"
DIAG_DIR="build/diagnostics"
SOURCE_ENTITLEMENTS="App/ParentApp/ParentApp.entitlements"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$DIAG_DIR"

if ! compgen -G "$IPA_DIR"/*.ipa > /dev/null; then
  echo "FAILING: no .ipa files found in $IPA_DIR — the archive/export step must run before this diagnostic."
  exit 1
fi

echo "== Locating the final exported ParentApp .ipa (bundle id $PARENT_BUNDLE_ID) in $IPA_DIR =="
PARENT_IPA=""
for ipa in "$IPA_DIR"/*.ipa; do
  probe_dir="$WORK_DIR/probe-$(basename "$ipa" .ipa)"
  mkdir -p "$probe_dir"
  unzip -q "$ipa" "Payload/*/Info.plist" -d "$probe_dir" 2>/dev/null || true
  app_plist="$(find "$probe_dir/Payload" -mindepth 2 -maxdepth 2 -name "Info.plist" 2>/dev/null | head -n1)"
  if [ -n "$app_plist" ]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_plist" 2>/dev/null || true)"
    if [ "$bundle_id" = "$PARENT_BUNDLE_ID" ]; then
      PARENT_IPA="$ipa"
      break
    fi
  fi
done

if [ -z "$PARENT_IPA" ]; then
  echo "FAILING: could not find a .ipa in $IPA_DIR whose CFBundleIdentifier matches '$PARENT_BUNDLE_ID'."
  echo "Contents of $IPA_DIR:"
  ls -la "$IPA_DIR" || true
  exit 1
fi
echo "Found ParentApp IPA: $PARENT_IPA"

echo "== Extracting Payload/ParentApp.app from the final signed IPA =="
EXTRACT_DIR="$WORK_DIR/parent-ipa-extract"
mkdir -p "$EXTRACT_DIR"
unzip -q "$PARENT_IPA" -d "$EXTRACT_DIR"

PARENT_APP_PATH="$(find "$EXTRACT_DIR/Payload" -mindepth 1 -maxdepth 1 -iname "*.app" | head -n1)"
if [ -z "$PARENT_APP_PATH" ] || [ ! -d "$PARENT_APP_PATH" ]; then
  echo "FAILING: Payload/*.app not found inside $PARENT_IPA"
  find "$EXTRACT_DIR" -maxdepth 2 || true
  exit 1
fi
echo "Found signed app bundle: $PARENT_APP_PATH"

echo "== Extracting FINAL SIGNED entitlements via codesign =="
SIGNED_ENTITLEMENTS_PLIST="$DIAG_DIR/ParentApp-signed-entitlements.plist"
if ! codesign -d --entitlements ":-" "$PARENT_APP_PATH" > "$SIGNED_ENTITLEMENTS_PLIST" 2>"$WORK_DIR/codesign.err"; then
  echo "FAILING: codesign could not extract entitlements from $PARENT_APP_PATH"
  cat "$WORK_DIR/codesign.err" || true
  exit 1
fi
echo "Wrote $SIGNED_ENTITLEMENTS_PLIST"

echo "== Extracting provisioning-profile entitlements (if a profile is embedded) =="
PROFILE_ENTITLEMENTS_PLIST="$DIAG_DIR/ParentApp-profile-entitlements.plist"
EMBEDDED_PROFILE="$PARENT_APP_PATH/embedded.mobileprovision"
PROFILE_ARG=""
if [ -f "$EMBEDDED_PROFILE" ]; then
  PROFILE_PLIST_FULL="$WORK_DIR/profile-full.plist"
  if security cms -D -i "$EMBEDDED_PROFILE" > "$PROFILE_PLIST_FULL" 2>"$WORK_DIR/security.err"; then
    if /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$PROFILE_PLIST_FULL" > "$PROFILE_ENTITLEMENTS_PLIST" 2>"$WORK_DIR/plistbuddy.err"; then
      echo "Wrote $PROFILE_ENTITLEMENTS_PLIST"
      PROFILE_ARG="$PROFILE_ENTITLEMENTS_PLIST"
    else
      echo "NOTE: embedded.mobileprovision decoded but had no :Entitlements dictionary — not fabricating a file."
      rm -f "$PROFILE_ENTITLEMENTS_PLIST"
    fi
  else
    echo "NOTE: embedded.mobileprovision present but could not be decoded with 'security cms' — not fabricating a file."
    cat "$WORK_DIR/security.err" || true
    rm -f "$PROFILE_ENTITLEMENTS_PLIST"
  fi
else
  echo "NOTE: no embedded.mobileprovision in this app bundle (expected/normal for some App Store Connect API-key signing flows) — not fabricating a file."
  rm -f "$PROFILE_ENTITLEMENTS_PLIST"
fi

if [ ! -f "$SOURCE_ENTITLEMENTS" ]; then
  echo "FAILING: source entitlements file not found at $SOURCE_ENTITLEMENTS — this is the One Truth for what ParentApp requests; refusing to fabricate a comparison without it."
  exit 1
fi

echo "== Writing human-readable CloudKit entitlement comparison =="
python3 Scripts/summarize_parent_cloudkit_entitlements.py \
  --source-entitlements "$SOURCE_ENTITLEMENTS" \
  --signed-entitlements "$SIGNED_ENTITLEMENTS_PLIST" \
  --profile-entitlements "$PROFILE_ARG" \
  --output "$DIAG_DIR/ParentApp-cloudkit-entitlements.txt"

echo "== Diagnostic complete =="
cat "$DIAG_DIR/ParentApp-cloudkit-entitlements.txt"
