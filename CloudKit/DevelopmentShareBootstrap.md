# TEMPORARY: CloudKit Development Share Bootstrap

**Status: temporary, one-time infrastructure.** Do not delete this file
or the `cloudkit-development-bootstrap` Codemagic workflow it documents
until CloudKit Production sharing is proven working and the Product
Owner approves removing them in a separate follow-up.

## Why this exists

TestFlight/App Store builds always sign for CloudKit **Production** —
there is no way to reach CloudKit **Development** through
`testflight-parent`/`testflight-release`. CloudKit's own internal
CKShare-support schema (commonly surfaced as the `cloudkit.share` record
type) is created automatically the first time a real `CKShare` save
succeeds in the **Development** environment, and must then be deployed
to Production via CloudKit Console's `Deploy Schema Changes...`. ParentApp
has so far only ever run against Production, so that system schema was
never created — this is the suspected cause of the `share-save ·
invalidArguments` failure (`returnedRecordTypes: "_pcs_data"`) that
persists even after Vǫxtr's own `FamilyWorkspace`/
`AthleteConnectionInvitation` schema was deployed (see
`VoxtrCloudKitSchemaManifest.md`).

This workflow produces ONE installable ParentApp build signed for
CloudKit Development, so it can be run once on a physical iPhone to
trigger a real share-save and let CloudKit generate that missing schema.

**Do NOT manually add `_pcs_data` or `cloudkit.share` to
`VoxtrCloudKitSchema.ckdb`.** These are CloudKit's own internal system
record types, not something Vǫxtr defines — CloudKit Console does not
allow creating them by hand, and this repository's schema artifact
governs only Vǫxtr's own two custom record types.

## Prerequisite you may need to complete first

An Ad Hoc build (the only kind that is both browser-installable and able
to target CloudKit Development — see the workflow's own header comment
in `codemagic.yaml` for why) requires the destination iPhone's UDID to
already be registered as a test device with the Apple Developer account
Codemagic signs with. This repository/session cannot confirm whether
your iPhone is already registered.

If the `cloudkit-development-bootstrap` workflow fails at the signing
step with a message about no eligible devices/profile, register your
iPhone first — Codemagic provides a browser-only way to do this with no
Mac required: in the Codemagic web UI, look for **Register device** (or
similar wording) for this app's iOS code signing settings. It shows a QR
code / link; opening it on your iPhone in Safari installs a small
configuration profile that reports your device's UDID back to Codemagic,
which then registers it with Apple. After registering, re-run this
bootstrap workflow — Codemagic can then generate an Ad Hoc profile that
includes your device.

## Steps

1. **Trigger the workflow.** In the Codemagic web UI, open this
   repository, select the **`cloudkit-development-bootstrap`** workflow,
   and start a build manually (branch:
   `claude/cloudkit-development-share-bootstrap`, or `develop` once
   merged). This workflow never runs automatically.
2. **Wait for the build to finish.** It builds ParentApp only and never
   uploads to TestFlight/App Store.
3. **Check the build log's signing diagnostics.** The final step prints
   (and saves as an artifact) `ParentApp-bootstrap-cloudkit-diagnostics.txt`,
   confirming `com.apple.developer.icloud-container-environment =
   Development`. The build FAILS outright if this is not `Development` —
   it will never hand you a misleading artifact.
4. **Download the `.ipa`.** On the finished build's page, download the
   `.ipa` artifact under `build/ios/ipa/*.ipa`.
5. **Install it on the registered iPhone.** Ad Hoc-signed `.ipa` files
   install over the air, in Safari, with no Mac and no cable — use
   whichever browser-based install mechanism Codemagic's own build page
   offers for this artifact (an "Install"/QR option, when shown), or any
   other Apple-supported over-the-air install link for this exact `.ipa`.
   A plain download of the raw `.ipa` file onto the iPhone does not
   install it by itself — it must go through an OTA/manifest install
   link, not a bare file download.
6. **Launch ParentApp** on the iPhone.
7. **Navigate:** Profile → Athlete settings → **Connect Athlete App**.
8. **Perform ONE share-creation attempt.** Let it finish (success or the
   existing on-device diagnostic error) — one attempt is enough.
9. **Check CloudKit Console:** container `iCloud.app.voxtr.shared` →
   **Development** → **Schema** → **Record Types**.
10. **Look specifically for CloudKit's own generated sharing schema** —
    most likely surfaced as `cloudkit.share`. If it is present, the
    bootstrap worked.
11. **If present, choose `Deploy Schema Changes...`** and deploy
    Development → Production.
12. **Return to the normal TestFlight ParentApp** build (the one already
    on your iPhone from `testflight-parent`/`testflight-release`).
13. **Retry Connect Athlete App** there. No new app build is required.

## If step 9's schema still fails to appear, or share-save still fails afterward

Use the existing on-device diagnostic (`Diagnostic: <stage> · <ckCode>`
under the error message — see PR #77) and CloudKit Console's own
Production logs to determine the next evidence-based step. Do not add
speculative retry/fallback code to work around this — report the new
diagnostic evidence instead.

## Cleanup

Once Production sharing is confirmed working, removing
`cloudkit-development-bootstrap` from `codemagic.yaml`, this file, and
`Scripts/capture_bootstrap_cloudkit_diagnostics.sh` should happen in a
separate, bounded follow-up PR after the Product Owner's approval — not
as part of this bootstrap PR.
