#!/usr/bin/env bash
# ITMS-90683 follow-up (PR #91): a real Mach-O binary inspection, not just
# a source-level module-boundary claim. PR #91's own fix (moving
# QRCodeScannerView's AVFoundation code into the AthleteApp-only
# VoxtrAthleteScanner target, excluded from VoxtrAppShell's dependencies)
# is only actually proven by inspecting the FINAL SIGNED, exported app
# binary this diagnostic runs against — mirrors
# Scripts/capture_parent_signed_entitlements.sh's own established
# "final exported artifact is the only authoritative evidence" approach,
# including its exact .ipa-lookup-by-CFBundleIdentifier convention, so a
# human reading both scripts recognizes the same pattern.
#
# Deliberately generic on $APP_NAME/$BUNDLE_ID (same convention as that
# script) even though every current call site passes ParentApp — this
# never runs against AthleteApp, which legitimately DOES link these
# symbols for its own "Scan connection code" screen; running this check
# there would be a false failure, not a stricter one.
set -euo pipefail

: "${APP_NAME:?APP_NAME is required (e.g. ParentApp)}"
: "${BUNDLE_ID:?BUNDLE_ID is required}"

IPA_DIR="build/ios/ipa"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# The exact set of concrete AVFoundation camera symbols ITMS-90683 (and
# this follow-up's own reported blocker) named — a plain Objective-C
# class reference always shows up as `_OBJC_CLASS_$_<Name>` in `nm`'s
# output when the class is genuinely linked into the binary; that is a
# precise, low-false-positive signal, unlike scanning for the bare name
# as a substring anywhere in the binary (which a struct/protocol NAMED
# similarly, or unrelated debug strings, could trigger).
FORBIDDEN_CLASSES=(
  AVCaptureSession
  AVCaptureDevice
  AVCaptureDeviceInput
  AVCaptureMetadataOutput
  AVCaptureVideoPreviewLayer
)
FORBIDDEN_PROTOCOL="AVCaptureMetadataOutputObjectsDelegate"

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

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_BUNDLE_PATH/Info.plist" 2>/dev/null || true)"
if [ -z "$EXECUTABLE_NAME" ] || [ ! -f "$APP_BUNDLE_PATH/$EXECUTABLE_NAME" ]; then
  echo "FAILING: could not resolve CFBundleExecutable inside $APP_BUNDLE_PATH/Info.plist, or the resolved file does not exist."
  exit 1
fi
EXECUTABLE_PATH="$APP_BUNDLE_PATH/$EXECUTABLE_NAME"
echo "Inspecting final signed executable: $EXECUTABLE_PATH"

echo "== Scanning for concrete AVFoundation camera symbols =="
# `nm`'s default output (not `-m`, to avoid depending on macho-specific
# formatting) lists one symbol per line — a genuinely linked Objective-C
# class/protocol always appears as the exact substring
# `_OBJC_CLASS_$_<Name>` / `_OBJC_PROTOCOL_$_<Name>` somewhere on its own
# line, so a fixed-string (`grep -F`) substring search is both sufficient
# and avoids relying on `\b`/word-boundary regex support, which is not
# consistent across grep implementations.
FOUND=()
SYMBOL_DUMP="$WORK_DIR/nm-output.txt"
nm "$EXECUTABLE_PATH" > "$SYMBOL_DUMP" 2>"$WORK_DIR/nm.err" || true

for class_name in "${FORBIDDEN_CLASSES[@]}"; do
  if grep -F -q "_OBJC_CLASS_\$_${class_name}" "$SYMBOL_DUMP"; then
    FOUND+=("_OBJC_CLASS_\$_${class_name}")
  fi
done
if grep -F -q "_OBJC_PROTOCOL_\$_${FORBIDDEN_PROTOCOL}" "$SYMBOL_DUMP"; then
  FOUND+=("_OBJC_PROTOCOL_\$_${FORBIDDEN_PROTOCOL}")
fi

if [ "${#FOUND[@]}" -gt 0 ]; then
  echo "FAILING: $APP_NAME's final signed executable still references concrete camera API symbols — this app must not link AVFoundation camera code at all:"
  printf '  %s\n' "${FOUND[@]}"
  echo "See PR #91's own doc comments (Package.swift's VoxtrAthleteScanner target, AthleteConnectionScanView.swift's AthleteConnectionScannerBuilder) for the intended module boundary — this means something is linking camera code into $APP_NAME again."
  exit 1
fi

echo "PASS: no concrete AVFoundation camera symbols found in $APP_NAME's final signed executable."
