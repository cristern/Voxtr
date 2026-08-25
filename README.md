# Vǫxtr

Native iOS platform for planning, tracking, and reflecting on training load for youth multi-sport athletes and their parents — two apps (AthleteApp, ParentApp) sharing one Swift package of domain logic.

## Project layout

```
Voxtr/
├── Package.swift, Sources/, Tests/     — all domain logic (SwiftData models, business rules)
├── App/
│   ├── Voxtr.xcodeproj/                — thin Xcode shell, two app targets
│   │   └── xcshareddata/xcschemes/     — shared schemes: AthleteApp, ParentApp
│   ├── AthleteApp/                     — minimal @main App entry point
│   └── ParentApp/                      — minimal @main App entry point
└── codemagic.yaml                      — CI: package-tests, athlete-simulator-build,
                                           parent-simulator-build, testflight-release,
                                           testflight-parent, testflight-athlete
```

## Local development

Open `App/Voxtr.xcodeproj` in Xcode. Both schemes (`AthleteApp`, `ParentApp`) are shared and checked into this repo, so they appear automatically for anyone who clones it.

---

## Automatic CI Triggers

These workflows are defined in `codemagic.yaml`. All of them can still be started manually at any time from the Codemagic dashboard (**Start new build** → pick the workflow), regardless of what triggered them automatically, or if nothing did.

### On push to `develop`

- **`package-tests`** — the only workflow that runs automatically on push. Skipped for commits that only change documentation (`.md` files).

`athlete-simulator-build` and `parent-simulator-build` do **not** run automatically on push anymore (CI-01) — see "Manually runnable workflows" below.

### On pull request

- **`pr-validation`** — the only automatic PR check, and only for PRs targeting `develop` — normal Vǫxtr development merges task branches into `develop`, so that is the branch this gate protects. Runs in strict order: package unit tests (hard-fails if zero tests execute) → **only if that passes** → build AthleteApp for the Simulator → **only if that passes** → build ParentApp for the Simulator. Any failed step stops everything after it — there is no `ignore_failure` anywhere in this workflow, so a failed test run means neither simulator build ever starts.

### On release tag

- **`testflight-release`** — runs only when a tag matching `release/*` is pushed (e.g. `release/1.0.0`). Builds and publishes **both** AthleteApp and ParentApp. Never runs on an ordinary push or pull request.

### Manually runnable workflows

`athlete-simulator-build` and `parent-simulator-build` have no automatic trigger at all (CI-01) — they exist to be run on demand (e.g. to sanity-check a simulator build outside the PR flow), not automatically on every push or PR.

- **`testflight-parent`** — manual only, no automatic trigger of any kind. Builds and publishes **only** ParentApp to TestFlight, independently of `testflight-release` — no Git tag required, just start it from the Codemagic dashboard.
- **`testflight-athlete`** — manual only, no automatic trigger of any kind. Builds and publishes **only** AthleteApp to TestFlight, the same way.

Both use the same App Store Connect integration and signing setup as `testflight-release` (see "Codemagic Setup Requirements" below) — nothing extra to configure if `testflight-release` already works.

### Starting a workflow manually in Codemagic

1. Open the app in the Codemagic dashboard.
2. Click **Start new build**.
3. Choose the branch (or tag, for `testflight-release`) and the workflow from the dropdowns.
4. Click **Start build**.

This works for every workflow above, regardless of whether it has an automatic trigger.

## Codemagic Setup Requirements


The three simulator/test workflows (`package-tests`, `athlete-simulator-build`, `parent-simulator-build`) need **no setup** — they run with `CODE_SIGNING_ALLOWED=NO` against the iOS Simulator and work immediately on any Codemagic account.

`testflight-release`, `testflight-parent`, and `testflight-athlete` all need the following configured **in the Codemagic UI**, never in this repository. Nothing below is a value — these are the names `codemagic.yaml` references; the actual secrets live only in Codemagic. All three workflows share the same integration and environment group — configure it once.

### 1. App Store Connect integration

- **Location:** Codemagic → Team settings → Integrations → App Store Connect
- **Integration reference name expected by `codemagic.yaml`:** `voxtr_app_store_connect`
- **What you provide there (not here):** your App Store Connect API **Issuer ID**, **Key ID**, and the `.p8` **private key file**.
- Once configured, Codemagic automatically exposes `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_IDENTIFIER`, and `APP_STORE_CONNECT_PRIVATE_KEY` to the workflow — each of `testflight-release`, `testflight-parent`, and `testflight-athlete`'s first step fails immediately with a clear message if any of these are missing.
- All three TestFlight workflows also apply Codemagic's own project-level build number (`PROJECT_BUILD_NUMBER`, never hardcoded) via `agvtool new-version -all` before archiving, so every TestFlight upload gets an increasing, App Store-valid build number automatically.

### 2. Environment variable group

- **Location:** Codemagic → your app → Environment variables → create a group named exactly:
- **Group name expected by `codemagic.yaml`:** `voxtr_ios_signing`
- This group is referenced by all three TestFlight workflows (`environment.groups: [voxtr_ios_signing]`) but none of them currently requires you to put anything specific in it beyond what the App Store Connect integration already supplies — it's there as the sanctioned place to add any future signing-related variable (e.g. an explicit Apple Developer **Team ID**, if your API key ever needs disambiguation across multiple teams) without touching `codemagic.yaml` itself. Mark any variable you do add as **Secure**.

### 3. Bundle identifiers

`codemagic.yaml` uses:
- `app.voxtr.athlete` (AthleteApp) — used by `testflight-release` and `testflight-athlete`
- `app.voxtr.parent` (ParentApp) — used by `testflight-release` and `testflight-parent`

These must exist as registered App IDs in your Apple Developer account and as apps in App Store Connect before any of the three TestFlight workflows can fetch signing files or publish a build. If you use different identifiers, update both `codemagic.yaml`'s `vars` block (in all three workflows) and the `PRODUCT_BUNDLE_IDENTIFIER` build setting in `App/Voxtr.xcodeproj`.

### 4. Triggering a build

- `testflight-release` triggers on a pushed git tag matching `release/*` (e.g. `release/1.0.0`) — not on every push to `main`, unlike the simulator workflows. Push a matching tag when you want to ship a TestFlight build of both apps.
- `testflight-parent` and `testflight-athlete` have no automatic trigger at all — start either one manually from the Codemagic dashboard whenever you want to ship just that one app to TestFlight without a tag.

### What is deliberately never in this repository

Apple Team ID, App Store Connect API private key, certificate passwords, provisioning profile UUIDs, Issuer ID, Key ID. All of these are either supplied automatically by the App Store Connect integration above, or belong in the `voxtr_ios_signing` environment variable group as **Secure** variables — never as literal values in `codemagic.yaml` or anywhere else in this repo.
