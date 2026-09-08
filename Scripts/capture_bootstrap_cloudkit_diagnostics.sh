#!/usr/bin/env bash
# TEMPORARY CloudKit Development share bootstrap (see
# CloudKit/DevelopmentShareBootstrap.md) — signing diagnostic + hard gate
# for the `cloudkit-development-bootstrap` Codemagic workflow ONLY.
#
# Deliberately a SEPARATE, self-contained script from
# Scripts/capture_parent_signed_entitlements.sh (used by
# testflight-parent/testflight-release): this bootstrap workflow has a
# different pass/fail contract — a signed app whose
# com.apple.developer.icloud-container-environment is not "Development"
# is a FAILED bootstrap build, not merely a diagnostic mismatch to report
# — so this script hard-fails in that case. Keeping it separate means
# testflight-parent/testflight-release/pr-validation/package-tests are
# byte-for-byte unaffected by this file's existence.
#
# SAFE FIELDS ONLY: application-identifier, the CloudKit container
# identifiers, the CloudKit services list, the CloudKit container
# environment, and (from the embedded provisioning profile, when present)
# Name/UUID/TeamIdentifier/application-identifier plus whether the
# profile authorizes CloudKit/the Development environment, and whether
# any device is provisioned (a count only). Never emits
# DeveloperCertificates, ProvisionedDevices UDIDs, or any other secret or
# full profile content.
set -euo pipefail

: "${PARENT_BUNDLE_ID:?PARENT_BUNDLE_ID is required}"

IPA_DIR="build/ios/ipa"
DIAG_DIR="build/diagnostics"
OUTPUT_TXT="$DIAG_DIR/ParentApp-bootstrap-cloudkit-diagnostics.txt"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$DIAG_DIR"

if ! compgen -G "$IPA_DIR"/*.ipa > /dev/null; then
  echo "FAILING: no .ipa files found in $IPA_DIR — the archive/export step must run before this diagnostic."
  exit 1
fi

echo "== Locating the bootstrap ParentApp .ipa (bundle id $PARENT_BUNDLE_ID) in $IPA_DIR =="
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
  ls -la "$IPA_DIR" || true
  exit 1
fi
echo "Found bootstrap ParentApp IPA: $PARENT_IPA"

EXTRACT_DIR="$WORK_DIR/parent-ipa-extract"
mkdir -p "$EXTRACT_DIR"
unzip -q "$PARENT_IPA" -d "$EXTRACT_DIR"
PARENT_APP_PATH="$(find "$EXTRACT_DIR/Payload" -mindepth 1 -maxdepth 1 -iname "*.app" | head -n1)"
if [ -z "$PARENT_APP_PATH" ] || [ ! -d "$PARENT_APP_PATH" ]; then
  echo "FAILING: Payload/*.app not found inside $PARENT_IPA"
  exit 1
fi

echo "== Extracting FINAL SIGNED entitlements via codesign =="
SIGNED_PLIST="$WORK_DIR/signed-entitlements.plist"
if ! codesign -d --entitlements ":-" "$PARENT_APP_PATH" > "$SIGNED_PLIST" 2>"$WORK_DIR/codesign.err"; then
  echo "FAILING: codesign could not extract entitlements from $PARENT_APP_PATH"
  cat "$WORK_DIR/codesign.err" || true
  exit 1
fi

APP_ID="$(/usr/libexec/PlistBuddy -c "Print :application-identifier" "$SIGNED_PLIST" 2>/dev/null || echo "(absent)")"
ICLOUD_CONTAINERS="$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-identifiers" "$SIGNED_PLIST" 2>/dev/null || echo "(absent)")"
ICLOUD_SERVICES="$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-services" "$SIGNED_PLIST" 2>/dev/null || echo "(absent)")"
ICLOUD_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-environment" "$SIGNED_PLIST" 2>/dev/null || echo "(absent)")"

echo "== Inspecting embedded provisioning profile (identity + CloudKit/device-provisioning presence only) =="
PROFILE_NAME="(no embedded profile)"
PROFILE_UUID="(no embedded profile)"
PROFILE_TEAM="(no embedded profile)"
PROFILE_APP_ID="(no embedded profile)"
PROFILE_ICLOUD_CONTAINERS="(no embedded profile)"
PROFILE_ICLOUD_ENVIRONMENT="(no embedded profile)"
PROFILE_DEVICE_SUMMARY="(no embedded profile)"
EMBEDDED_PROFILE="$PARENT_APP_PATH/embedded.mobileprovision"
if [ -f "$EMBEDDED_PROFILE" ]; then
  PROFILE_PLIST_FULL="$WORK_DIR/profile-full.plist"
  if security cms -D -i "$EMBEDDED_PROFILE" > "$PROFILE_PLIST_FULL" 2>"$WORK_DIR/security.err"; then
    PROFILE_NAME="$(/usr/libexec/PlistBuddy -c "Print :Name" "$PROFILE_PLIST_FULL" 2>/dev/null || echo "(absent)")"
    PROFILE_UUID="$(/usr/libexec/PlistBuddy -c "Print :UUID" "$PROFILE_PLIST_FULL" 2>/dev/null || echo "(absent)")"
    PROFILE_TEAM="$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$PROFILE_PLIST_FULL" 2>/dev/null || echo "(absent)")"
    PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$PROFILE_PLIST_FULL" 2>/dev/null || echo "(absent)")"
    PROFILE_ICLOUD_CONTAINERS="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers" "$PROFILE_PLIST_FULL" 2>/dev/null || echo "(absent)")"
    PROFILE_ICLOUD_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.icloud-container-environment" "$PROFILE_PLIST_FULL" 2>/dev/null || echo "(absent)")"
    # Count only — never list UDIDs. Excludes PlistBuddy's own structural
    # "Array {"/"}" lines so the count reflects actual entries, not the
    # array's own delimiters.
    RAW_DEVICES="$(/usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$PROFILE_PLIST_FULL" 2>/dev/null || true)"
    DEVICE_COUNT=0
    if [ -n "$RAW_DEVICES" ]; then
      DEVICE_COUNT="$(printf '%s\n' "$RAW_DEVICES" | grep -Ev '^(Array \{|\})$' | grep -c '.' || true)"
    fi
    if [ "$DEVICE_COUNT" -gt 0 ] 2>/dev/null; then
      PROFILE_DEVICE_SUMMARY="present ($DEVICE_COUNT device(s) provisioned)"
    else
      PROFILE_DEVICE_SUMMARY="absent (no ProvisionedDevices list on this profile)"
    fi
  else
    echo "NOTE: embedded.mobileprovision present but could not be decoded with 'security cms'."
    cat "$WORK_DIR/security.err" || true
  fi
else
  echo "NOTE: no embedded.mobileprovision in this app bundle."
fi

{
  echo "Vǫxtr — CloudKit Development share bootstrap: signing diagnostics"
  echo "===================================================================="
  echo ""
  echo "TEMPORARY bootstrap workflow (cloudkit-development-bootstrap). See"
  echo "CloudKit/DevelopmentShareBootstrap.md. This is NOT a TestFlight build."
  echo ""
  echo "FINAL SIGNED APP (from the exported .ipa, via codesign -d --entitlements :-):"
  echo "  application-identifier = $APP_ID"
  echo "  com.apple.developer.icloud-container-identifiers = $ICLOUD_CONTAINERS"
  echo "  com.apple.developer.icloud-services = $ICLOUD_SERVICES"
  echo "  com.apple.developer.icloud-container-environment = $ICLOUD_ENVIRONMENT"
  echo ""
  echo "EMBEDDED PROVISIONING PROFILE (identity + CloudKit/device-provisioning presence only):"
  echo "  Name = $PROFILE_NAME"
  echo "  UUID = $PROFILE_UUID"
  echo "  TeamIdentifier = $PROFILE_TEAM"
  echo "  Entitlements:application-identifier = $PROFILE_APP_ID"
  echo "  Entitlements:com.apple.developer.icloud-container-identifiers = $PROFILE_ICLOUD_CONTAINERS"
  echo "  Entitlements:com.apple.developer.icloud-container-environment = $PROFILE_ICLOUD_ENVIRONMENT"
  echo "  Device provisioning: $PROFILE_DEVICE_SUMMARY"
  echo ""
  echo "NOT included by design: DeveloperCertificates, ProvisionedDevices UDIDs,"
  echo "full provisioning profile content, or any other secret."
} > "$OUTPUT_TXT"

cat "$OUTPUT_TXT"

echo ""
echo "== Critical assertion: com.apple.developer.icloud-container-environment must be Development =="
if [ "$ICLOUD_ENVIRONMENT" != "Development" ]; then
  echo "FAILING BUILD: final signed ParentApp resolves com.apple.developer.icloud-container-environment = '$ICLOUD_ENVIRONMENT', not 'Development'. Refusing to publish a bootstrap artifact that would not actually bootstrap the CloudKit Development environment — see CloudKit/DevelopmentShareBootstrap.md for what to check (ios_signing.distribution_type, the ad-hoc provisioning profile actually selected, and the --custom-export-options passed to xcode-project use-profiles)."
  exit 1
fi
echo "OK: final signed ParentApp uses the CloudKit Development environment."
