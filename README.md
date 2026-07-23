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
                                           parent-simulator-build, testflight-release
```

## Local development

Open `App/Voxtr.xcodeproj` in Xcode. Both schemes (`AthleteApp`, `ParentApp`) are shared and checked into this repo, so they appear automatically for anyone who clones it.

---

## Codemagic Setup Requirements

The three simulator/test workflows (`package-tests`, `athlete-simulator-build`, `parent-simulator-build`) need **no setup** — they run with `CODE_SIGNING_ALLOWED=NO` against the iOS Simulator and work immediately on any Codemagic account.

The `testflight-release` workflow needs the following configured **in the Codemagic UI**, never in this repository. Nothing below is a value — these are the names `codemagic.yaml` references; the actual secrets live only in Codemagic.

### 1. App Store Connect integration

- **Location:** Codemagic → Team settings → Integrations → App Store Connect
- **Integration reference name expected by `codemagic.yaml`:** `voxtr_app_store_connect`
- **What you provide there (not here):** your App Store Connect API **Issuer ID**, **Key ID**, and the `.p8` **private key file**.
- Once configured, Codemagic automatically exposes `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_IDENTIFIER`, and `APP_STORE_CONNECT_PRIVATE_KEY` to the workflow — the `testflight-release` workflow's first step fails immediately with a clear message if any of these are missing.

### 2. Environment variable group

- **Location:** Codemagic → your app → Environment variables → create a group named exactly:
- **Group name expected by `codemagic.yaml`:** `voxtr_ios_signing`
- This group is referenced (`environment.groups: [voxtr_ios_signing]`) but the workflow doesn't currently require you to put anything specific in it beyond what the App Store Connect integration already supplies — it's there as the sanctioned place to add any future signing-related variable (e.g. an explicit Apple Developer **Team ID**, if your API key ever needs disambiguation across multiple teams) without touching `codemagic.yaml` itself. Mark any variable you do add as **Secure**.

### 3. Bundle identifiers

`codemagic.yaml` uses:
- `app.voxtr.athlete` (AthleteApp)
- `app.voxtr.parent` (ParentApp)

These must exist as registered App IDs in your Apple Developer account and as apps in App Store Connect before `testflight-release` can fetch signing files or publish a build. If you use different identifiers, update both `codemagic.yaml`'s `vars` block and the `PRODUCT_BUNDLE_IDENTIFIER` build setting in `App/Voxtr.xcodeproj`.

### 4. Triggering a release build

`testflight-release` triggers on a pushed git tag matching `release/*` (e.g. `release/1.0.0`) — not on every push to `main`, unlike the simulator workflows. Push a matching tag when you want to ship a TestFlight build.

### What is deliberately never in this repository

Apple Team ID, App Store Connect API private key, certificate passwords, provisioning profile UUIDs, Issuer ID, Key ID. All of these are either supplied automatically by the App Store Connect integration above, or belong in the `voxtr_ios_signing` environment variable group as **Secure** variables — never as literal values in `codemagic.yaml` or anywhere else in this repo.
