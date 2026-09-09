#!/usr/bin/env bash
# ParentApp CloudKit sharing runtime crash (build 502/507/511/516) —
# signed-entitlements diagnostic follow-up.
#
# AthleteApp Release signing closeout: generalized to run for EITHER app —
# every previously-hardcoded "ParentApp" reference now derives from the
# required $APP_NAME/$BUNDLE_ID env vars, so this ONE script covers both
# apps rather than three Athlete-specific copies. `APP_NAME=ParentApp
# BUNDLE_ID=$PARENT_BUNDLE_ID` (the two existing call sites, updated to
# pass these explicitly) reproduces byte-identical output filenames/
# content/validation semantics to before this change; a new
# `APP_NAME=AthleteApp BUNDLE_ID=$ATHLETE_BUNDLE_ID` call is the only
# genuinely new behavior. Optional `FAIL_ON_MISMATCH=true` (unset for the
# existing Parent call sites, set for the new Athlete ones per that task's
# own explicit requirement) makes this script exit non-zero when the
# comparison below reports MISMATCH — Parent's own historical "report,
# never fail the build" semantics are preserved exactly by leaving it
# unset there.
#
# Captures what is ACTUALLY present in the FINAL SIGNED, exported .ipa and
# compares it against the canonical source App/$APP_NAME/$APP_NAME.entitlements
# (One Truth for what this repository requests) — never against hardcoded
# expected values, and never against the .xcarchive, because Xcode/
# Codemagic export/re-signing can still alter entitlements after
# archiving. Runs AFTER the "Archive and export $APP_NAME (Release)" step
# in each TestFlight workflow, on the IPA that step already produced; this
# script does not rebuild or re-sign anything.
#
# `testflight-release` builds AthleteApp and ParentApp into the SAME
# build/ios/ipa directory, so the correct file is picked by its
# CFBundleIdentifier (matched against $BUNDLE_ID), never by filename —
# `testflight-parent`/`testflight-athlete` only ever produce one .ipa
# there each, so the same lookup is still correct for those too.
#
# Build 119 follow-up: PR #73's entitlement diagnostic proved the embedded
# profile itself (not just the final codesign output) lacked CloudKit —
# but a directly-downloaded, freshly regenerated Apple profile for the
# same bundle id was separately confirmed correct, meaning Codemagic must
# have embedded a DIFFERENT profile than the one now on record at Apple.
# This script also writes a small, sanitized profile IDENTITY summary
# (Name/UUID/CreationDate/ExpirationDate/TeamIdentifier/application-
# identifier — never certificates or device UDIDs) so a human can compare
# it against the directly-downloaded Apple profile's own identity to
# confirm whether the correct profile was actually used.
#
# Build 123 follow-up: with profile selection now confirmed correct, the
# final signed IPA STILL lacked CloudKit — so this script also captures
# the ARCHIVE's own signed entitlements (build/ios/xcarchive/*.xcarchive
# /Products/Applications/$APP_NAME.app), which `xcode-project build-ipa`
# already produces and never deletes, and never modifies again during its
# own export step (`-exportArchive` reads an archive as input and writes
# the .ipa as a separate output — it does not rewrite the archive's own
# Products/Applications/*.app in place). Comparing archive vs. final IPA
# vs. source localizes whether entitlement loss happens during the
# archive build itself or only during export/re-sign.
set -euo pipefail

: "${APP_NAME:?APP_NAME is required (e.g. ParentApp or AthleteApp)}"
: "${BUNDLE_ID:?BUNDLE_ID is required}"
FAIL_ON_MISMATCH="${FAIL_ON_MISMATCH:-false}"

IPA_DIR="build/ios/ipa"
ARCHIVE_DIR="build/ios/xcarchive"
DIAG_DIR="build/diagnostics"
SOURCE_ENTITLEMENTS="App/${APP_NAME}/${APP_NAME}.entitlements"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$DIAG_DIR"

if ! compgen -G "$IPA_DIR"/*.ipa > /dev/null; then
  echo "FAILING: no .ipa files found in $IPA_DIR — the archive/export step must run before this diagnostic."
  exit 1
fi

echo "== Locating the final exported $APP_NAME .ipa (bundle id $BUNDLE_ID) in $IPA_DIR =="
APP_IPA=""
for ipa in "$IPA_DIR"/*.ipa; do
  probe_dir="$WORK_DIR/probe-$(basename "$ipa" .ipa)"
  mkdir -p "$probe_dir"
  unzip -q "$ipa" "Payload/*/Info.plist" -d "$probe_dir" 2>/dev/null || true
  app_plist="$(find "$probe_dir/Payload" -mindepth 2 -maxdepth 2 -name "Info.plist" 2>/dev/null | head -n1)"
  if [ -n "$app_plist" ]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_plist" 2>/dev/null || true)"
    if [ "$bundle_id" = "$BUNDLE_ID" ]; then
      APP_IPA="$ipa"
      break
    fi
  fi
done

if [ -z "$APP_IPA" ]; then
  echo "FAILING: could not find a .ipa in $IPA_DIR whose CFBundleIdentifier matches '$BUNDLE_ID'."
  echo "Contents of $IPA_DIR:"
  ls -la "$IPA_DIR" || true
  exit 1
fi
echo "Found $APP_NAME IPA: $APP_IPA"

echo "== Extracting Payload/$APP_NAME.app from the final signed IPA =="
EXTRACT_DIR="$WORK_DIR/app-ipa-extract"
mkdir -p "$EXTRACT_DIR"
unzip -q "$APP_IPA" -d "$EXTRACT_DIR"

APP_BUNDLE_PATH="$(find "$EXTRACT_DIR/Payload" -mindepth 1 -maxdepth 1 -iname "*.app" | head -n1)"
if [ -z "$APP_BUNDLE_PATH" ] || [ ! -d "$APP_BUNDLE_PATH" ]; then
  echo "FAILING: Payload/*.app not found inside $APP_IPA"
  find "$EXTRACT_DIR" -maxdepth 2 || true
  exit 1
fi
echo "Found signed app bundle: $APP_BUNDLE_PATH"

echo "== Extracting FINAL SIGNED entitlements via codesign =="
SIGNED_ENTITLEMENTS_PLIST="$DIAG_DIR/${APP_NAME}-signed-entitlements.plist"
if ! codesign -d --entitlements ":-" "$APP_BUNDLE_PATH" > "$SIGNED_ENTITLEMENTS_PLIST" 2>"$WORK_DIR/codesign.err"; then
  echo "FAILING: codesign could not extract entitlements from $APP_BUNDLE_PATH"
  cat "$WORK_DIR/codesign.err" || true
  exit 1
fi
echo "Wrote $SIGNED_ENTITLEMENTS_PLIST"

echo "== Extracting provisioning-profile entitlements (if a profile is embedded) =="
PROFILE_ENTITLEMENTS_PLIST="$DIAG_DIR/${APP_NAME}-profile-entitlements.plist"
PROFILE_SUMMARY_TXT="$DIAG_DIR/${APP_NAME}-profile-summary.txt"
EMBEDDED_PROFILE="$APP_BUNDLE_PATH/embedded.mobileprovision"
PROFILE_ARG=""
rm -f "$PROFILE_SUMMARY_TXT"
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

    echo "== Writing embedded provisioning-profile identity summary (Name/UUID/dates only) =="
    if python3 Scripts/summarize_parent_profile_identity.py \
      --app-name "$APP_NAME" \
      --profile-plist "$PROFILE_PLIST_FULL" \
      --output "$PROFILE_SUMMARY_TXT"; then
      cat "$PROFILE_SUMMARY_TXT"
    else
      echo "NOTE: could not summarize profile identity from the decoded plist — not fabricating a file."
      rm -f "$PROFILE_SUMMARY_TXT"
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

echo "== Locating the $APP_NAME archive (bundle id $BUNDLE_ID) in $ARCHIVE_DIR =="
ARCHIVE_ENTITLEMENTS_PLIST="$DIAG_DIR/${APP_NAME}-archive-signed-entitlements.plist"
ARCHIVE_ARG=""
rm -f "$ARCHIVE_ENTITLEMENTS_PLIST"
if compgen -G "$ARCHIVE_DIR"/*.xcarchive > /dev/null; then
  APP_ARCHIVE_BUNDLE=""
  for archive in "$ARCHIVE_DIR"/*.xcarchive; do
    for app in "$archive"/Products/Applications/*.app; do
      [ -d "$app" ] || continue
      archive_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist" 2>/dev/null || true)"
      if [ "$archive_bundle_id" = "$BUNDLE_ID" ]; then
        APP_ARCHIVE_BUNDLE="$app"
        break 2
      fi
    done
  done

  if [ -z "$APP_ARCHIVE_BUNDLE" ]; then
    echo "NOTE: no archived .app in $ARCHIVE_DIR matches CFBundleIdentifier '$BUNDLE_ID' — not fabricating a file."
  else
    echo "Found archived $APP_NAME bundle: $APP_ARCHIVE_BUNDLE"
    if codesign -d --entitlements ":-" "$APP_ARCHIVE_BUNDLE" > "$ARCHIVE_ENTITLEMENTS_PLIST" 2>"$WORK_DIR/archive-codesign.err"; then
      echo "Wrote $ARCHIVE_ENTITLEMENTS_PLIST"
      ARCHIVE_ARG="$ARCHIVE_ENTITLEMENTS_PLIST"
    else
      echo "NOTE: codesign could not extract entitlements from the archived app (it may be unsigned at this stage — that is itself useful diagnostic evidence) — not fabricating a file."
      cat "$WORK_DIR/archive-codesign.err" || true
      rm -f "$ARCHIVE_ENTITLEMENTS_PLIST"
    fi
  fi
else
  echo "NOTE: no .xcarchive found in $ARCHIVE_DIR — not fabricating a file."
fi

if [ ! -f "$SOURCE_ENTITLEMENTS" ]; then
  echo "FAILING: source entitlements file not found at $SOURCE_ENTITLEMENTS — this is the One Truth for what $APP_NAME requests; refusing to fabricate a comparison without it."
  exit 1
fi

echo "== Writing human-readable CloudKit entitlement comparison =="
CLOUDKIT_REPORT="$DIAG_DIR/${APP_NAME}-cloudkit-entitlements.txt"
python3 Scripts/summarize_parent_cloudkit_entitlements.py \
  --app-name "$APP_NAME" \
  --source-entitlements "$SOURCE_ENTITLEMENTS" \
  --archive-entitlements "$ARCHIVE_ARG" \
  --signed-entitlements "$SIGNED_ENTITLEMENTS_PLIST" \
  --profile-entitlements "$PROFILE_ARG" \
  --output "$CLOUDKIT_REPORT"

echo "== Diagnostic complete =="
cat "$CLOUDKIT_REPORT"

if grep -q "^OVERALL: MISMATCH" "$CLOUDKIT_REPORT"; then
  if [ "$FAIL_ON_MISMATCH" = "true" ]; then
    echo "FAILING: $APP_NAME's final signed app does not carry every source-requested CloudKit entitlement — refusing to let this release publish an app that would crash on CKContainer(identifier:) at runtime. See the comparison above for stage localization."
    exit 1
  fi
  echo "NOTE: MISMATCH reported above, but FAIL_ON_MISMATCH is not 'true' for this call — reporting only, matching this diagnostic's original (Parent) behavior."
fi
