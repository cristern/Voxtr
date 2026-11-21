#!/usr/bin/env bash
# T1 (issue #122): validates the hosted backend base URL and gateway key
# actually embedded in the FINAL SIGNED, exported .ipa's processed
# Info.plist — never the source Info.plist or project.pbxproj's own
# committed Debug/placeholder defaults, since Xcode's own `$(VAR)`
# substitution during the "Process Info.plist File" build phase is the
# only thing that can prove a given archive genuinely received the
# Codemagic-provisioned real values (see
# Sources/VoxtrAppShell/HostedBackendConfigurationResolver.swift's own
# doc comment for the matching runtime-side validation this mirrors).
#
# Runs AFTER the "Archive and export $APP_NAME (Release)" step in each
# TestFlight workflow, on the IPA that step already produced — same
# placement and same IPA-location-by-CFBundleIdentifier approach as
# Scripts/capture_parent_signed_entitlements.sh, intentionally not
# shared with it (that script's own entitlements logic is unrelated and
# already working; this task does not refactor it).
#
# NEVER prints either actual value, in full or in part — only PASS/FAIL
# per check and, where useful, non-identifying shape facts (character
# count, segment count). This script fails the build (non-zero exit) on
# any violation; it never relaxes a check to let a misconfigured archive
# through.
#
# ChatGPT review (PR #123, R2): the original version only checked that
# the embedded Info.plist values LOOKED plausible (https + non-loopback
# + /functions/v1 suffix shape; 3-segment JWT shape) — it never compared
# them against what Codemagic actually provisioned, so a different
# project URL or a different well-shaped token could still pass. This
# version additionally: (1) requires the provisioned
# VOXTR_HOSTED_BACKEND_BASE_URL itself to be the one approved T1 project
# endpoint (the same canonical pinning
# Sources/VoxtrAppShell/HostedBackendConfigurationResolver.swift applies
# at runtime), and (2) requires the embedded Info.plist's own values to
# EXACTLY match (byte-for-byte) what was provisioned — never just "has
# the right shape." The original shape checks are kept as a first,
# more-diagnostic layer; the exact-match checks are the actual gate.
set -euo pipefail

: "${APP_NAME:?APP_NAME is required (e.g. ParentApp or AthleteApp)}"
: "${BUNDLE_ID:?BUNDLE_ID is required}"
: "${VOXTR_HOSTED_BACKEND_BASE_URL:?VOXTR_HOSTED_BACKEND_BASE_URL is required — configure the 'voxtr_hosted_backend_t1' Codemagic environment variable group.}"
: "${VOXTR_HOSTED_SUPABASE_ANON_KEY:?VOXTR_HOSTED_SUPABASE_ANON_KEY is required — configure the 'voxtr_hosted_backend_t1' Codemagic environment variable group.}"

# The ONE approved T1 hosted Supabase project — must match
# HostedBackendConfigurationResolver.swift's own
# `canonicalHostedProjectHost` exactly (cross-referenced there too).
EXPECTED_BASE_URL="https://pxbjctflgcxwjsaablkf.supabase.co/functions/v1"
PLACEHOLDER_ANON_KEY="REPLACE_WITH_SUPABASE_ANON_KEY"

IPA_DIR="build/ios/ipa"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! compgen -G "$IPA_DIR"/*.ipa > /dev/null; then
  echo "FAILING: no .ipa files found in $IPA_DIR — the archive/export step must run before this validation."
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
      APP_PLIST="$app_plist"
      break
    fi
  fi
done

if [ -z "${APP_IPA:-}" ]; then
  echo "FAILING: could not find a .ipa in $IPA_DIR whose CFBundleIdentifier matches '$BUNDLE_ID'."
  ls -la "$IPA_DIR" || true
  exit 1
fi
echo "Found $APP_NAME IPA: $APP_IPA"

echo "== Reading hosted backend configuration from the final signed Info.plist (values never printed) =="
BASE_URL="$(/usr/libexec/PlistBuddy -c "Print :VoxtrHostedBackendBaseURL" "$APP_PLIST" 2>/dev/null || true)"
ANON_KEY="$(/usr/libexec/PlistBuddy -c "Print :VoxtrHostedSupabaseAnonKey" "$APP_PLIST" 2>/dev/null || true)"

FAILED=0

if [ -z "$BASE_URL" ]; then
  echo "FAILING CHECK: VoxtrHostedBackendBaseURL is missing or empty in the final signed Info.plist."
  FAILED=1
elif [[ "$BASE_URL" != https://* ]]; then
  echo "FAILING CHECK: VoxtrHostedBackendBaseURL does not start with https://."
  FAILED=1
elif [[ "$BASE_URL" == *"://localhost"* || "$BASE_URL" == *"://127.0.0.1"* || "$BASE_URL" == *"://[::1]"* ]]; then
  echo "FAILING CHECK: VoxtrHostedBackendBaseURL resolves to a local-development host — never acceptable on a physical Release build."
  FAILED=1
elif [[ "$BASE_URL" == */ || "$BASE_URL" != */functions/v1 ]]; then
  echo "FAILING CHECK: VoxtrHostedBackendBaseURL does not end with the required /functions/v1 path (and must not have a trailing slash)."
  FAILED=1
else
  echo "PASS: VoxtrHostedBackendBaseURL is https, non-loopback, and ends with /functions/v1 (${#BASE_URL} characters)."
fi

if [ -z "$ANON_KEY" ]; then
  echo "FAILING CHECK: VoxtrHostedSupabaseAnonKey is missing or empty in the final signed Info.plist."
  FAILED=1
elif [ "$ANON_KEY" = "REPLACE_WITH_SUPABASE_ANON_KEY" ]; then
  echo "FAILING CHECK: VoxtrHostedSupabaseAnonKey is still the development placeholder."
  FAILED=1
else
  SEGMENT_COUNT="$(awk -F'.' '{print NF}' <<< "$ANON_KEY")"
  if [ "$SEGMENT_COUNT" -ne 3 ] || ! [[ "$ANON_KEY" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
    echo "FAILING CHECK: VoxtrHostedSupabaseAnonKey is not shaped like the required legacy anon-key (JWT) format — a modern sb_publishable_/sb_secret_ key is not a drop-in substitute here (issue #122 §3)."
    FAILED=1
  else
    echo "PASS: VoxtrHostedSupabaseAnonKey has the expected three-segment JWT shape (${#ANON_KEY} characters)."
  fi
fi

echo "== Verifying the PROVISIONED (Codemagic environment) values themselves, not just the embedded IPA values =="

if [ "$VOXTR_HOSTED_BACKEND_BASE_URL" != "$EXPECTED_BASE_URL" ]; then
  echo "FAILING CHECK: the provisioned VOXTR_HOSTED_BACKEND_BASE_URL does not exactly match the one approved T1 hosted project endpoint. A different, even otherwise-valid-looking, Supabase project URL is not acceptable here (ChatGPT review PR #123 R1/R2)."
  FAILED=1
else
  echo "PASS: the provisioned VOXTR_HOSTED_BACKEND_BASE_URL is exactly the approved T1 hosted project endpoint."
fi

if [ -z "$VOXTR_HOSTED_SUPABASE_ANON_KEY" ] || [ "$VOXTR_HOSTED_SUPABASE_ANON_KEY" = "$PLACEHOLDER_ANON_KEY" ]; then
  echo "FAILING CHECK: the provisioned VOXTR_HOSTED_SUPABASE_ANON_KEY is missing or still the development placeholder."
  FAILED=1
else
  PROVISIONED_SEGMENT_COUNT="$(awk -F'.' '{print NF}' <<< "$VOXTR_HOSTED_SUPABASE_ANON_KEY")"
  if [ "$PROVISIONED_SEGMENT_COUNT" -ne 3 ] || ! [[ "$VOXTR_HOSTED_SUPABASE_ANON_KEY" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
    echo "FAILING CHECK: the provisioned VOXTR_HOSTED_SUPABASE_ANON_KEY is not shaped like the required legacy anon-key (JWT) format."
    FAILED=1
  else
    echo "PASS: the provisioned VOXTR_HOSTED_SUPABASE_ANON_KEY has the expected three-segment JWT shape."
  fi
fi

echo "== Verifying the final signed Info.plist's embedded values EXACTLY match what was provisioned (not just a plausible shape) =="

if [ "$BASE_URL" != "$VOXTR_HOSTED_BACKEND_BASE_URL" ]; then
  echo "FAILING CHECK: the final signed Info.plist's VoxtrHostedBackendBaseURL does not exactly match the provisioned VOXTR_HOSTED_BACKEND_BASE_URL value — the archived build does not carry the value Codemagic actually provisioned."
  FAILED=1
else
  echo "PASS: the final signed Info.plist's VoxtrHostedBackendBaseURL exactly matches the provisioned value."
fi

if [ "$ANON_KEY" != "$VOXTR_HOSTED_SUPABASE_ANON_KEY" ]; then
  echo "FAILING CHECK: the final signed Info.plist's VoxtrHostedSupabaseAnonKey does not exactly match the provisioned VOXTR_HOSTED_SUPABASE_ANON_KEY value — the archived build does not carry the value Codemagic actually provisioned."
  FAILED=1
else
  echo "PASS: the final signed Info.plist's VoxtrHostedSupabaseAnonKey exactly matches the provisioned value."
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILING BUILD: $APP_NAME's final signed Info.plist does not carry valid, exactly-provisioned hosted backend configuration — refusing to let this release publish a build that would fail closed (or worse, silently misbehave, or silently talk to the wrong project) at launch. See the checks above; no raw value is ever printed."
  exit 1
fi

echo "== $APP_NAME hosted backend configuration validation PASSED (embedded values exactly match the approved, provisioned configuration) =="
