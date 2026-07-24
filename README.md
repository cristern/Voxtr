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

## Automatic CI Triggers

These four workflows are defined in `codemagic.yaml`. All of them can still be started manually at any time from the Codemagic dashboard (**Start new build** → pick the workflow), regardless of what triggered them automatically, or if nothing did.

### On push to `develop`

- **`package-tests`**
- **`athlete-simulator-build`**
- **`parent-simulator-build`**

### On pull request

- **`package-tests`** — runs for any PR targeting **either** `develop` or `main`.
- **`athlete-simulator-build`** — runs for any PR targeting `main`, or any PR whose *source* branch is `develop`.
- **`parent-simulator-build`** — same as `athlete-simulator-build`.

### On release tag

- **`testflight-release`** — runs only when a tag matching `release/*` is pushed (e.g. `release/1.0.0`). Never runs on an ordinary push or pull request.

### Starting a workflow manually in Codemagic

1. Open the app in the Codemagic dashboard.
2. Click **Start new build**.
3. Choose the branch (or tag, for `testflight-release`) and the workflow from the dropdowns.
4. Click **Start build**.

This works regardless of the automatic triggers above — useful for re-running a workflow without pushing a new commit, or running `testflight-release` against a specific existing tag.

### A known limitation of this setup, worth knowing about

Codemagic's `branch_patterns` can't restrict a branch match to *only* push events or *only* pull-request events within the same workflow — a pattern that's needed for "PR targeting `main`" also applies to a plain push. Practical effect: a **direct push to `main`** will also trigger `package-tests`, `athlete-simulator-build`, and `parent-simulator-build`, even though only pushes to `develop` were requested. If `main` is protected against direct pushes on GitHub (recommended for this branching model regardless), this has no practical effect. Not fixable purely in YAML without splitting into additional workflows.



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
