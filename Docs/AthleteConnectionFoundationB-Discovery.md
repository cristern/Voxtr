# Athlete Connection Foundation B — CloudKit Sharing Architecture Discovery

Status: **discovery record, not an implementation plan**. No production CloudKit
code, Athlete UI, or custom backend was implemented as part of this document.

Branch: `claude/athlete-connection-foundation-b-discovery`
Base: `develop` @ `9a7e61842b41b535efda7f2de629fa96ddac2919` (Athlete Connection
Foundation A, merged).

This document exists because the repository has no standalone ADR file
convention (`Docs/` currently holds only `ReleaseNotes/`; there is no
`Docs/ADR/` or equivalent, and source comments reference "ADR-0001"/"ADR-0002"
that do not exist as files — a pre-existing gap, not something this document
invents). Per this task's own instruction, the full decision record also
appears in the pull request description; this file is a durable, directly
readable copy of the same content for a future implementation task to start
from, placed in the one documentation directory this repository already has —
not a new ADR numbering hierarchy.

**PR #60 follow-up note:** the repository itself does not contain the
governing Domain & Data Model documents. Lead Review has now checked the
canonical project documentation and supplied the authoritative decisions in
Section 0 below. This revision corrects the original discovery's entity
placement, zone model, Reflection framing, and conflict-semantics sections
to be consistent with those decisions. Everywhere this revision changed a
conclusion from the original discovery, that is called out explicitly rather
than silently rewritten, per the instruction not to blur "already decided"
with "newly recommended here."

---

## 0. Authority — existing canonical Domain & Data Model decisions

The following are **existing, approved product/architecture decisions**,
supplied by Lead Review from canonical documentation this repository does not
itself contain. This discovery treats them as authoritative and locked, not
as something it is recommending or free to revisit.

- **DDM-006, LOCKED:** `FamilyWorkspace` is the CloudKit sharing root for the
  family MVP.
- **Parent/membership placement:**
  - `FamilyWorkspace` → Family Shared Zone root / `CKShare` root.
  - `WorkspaceParticipant` → Family Shared Zone.
  - `AthleteAccessGrant` → Family Shared Zone.
  - `ParentProfile` → a **shared profile projection** goes in the Family
    Shared Zone; **account binding** (the actual iCloud/CloudKit account
    identity underlying the Parent's participation) stays local/private
    where required. The whole `ParentProfile` concept is not Parent-local.
- **Reflection zone model:**
  - `VisibilityPolicy.sharedWithGuardians` → raw reflection content lives in
    the **Family Shared Zone**.
  - `VisibilityPolicy.summaryOnly` → raw reflection content lives in the
    **Athlete Private Zone**; only an approved **derived projection** of it
    may enter the Family Shared Zone.
  - `VisibilityPolicy.privateToAthlete` → raw reflection content lives in
    the **Athlete Private Zone** only. It never enters the Family Shared
    Zone.
- **Planning concurrency (WeekPlan/PlannedActivity), already decided:**
  - Edits to different `PlannedActivity` records may merge.
  - Edits to the **same** `PlannedActivity` record must **not** use
    last-write-wins; both versions are preserved and require explicit
    resolution.
  - A delete versus an edit of the same record requires explicit
    resolution.
  - `WeekPlan.commit` against unresolved conflicting content is rejected.
  - An offline edit made after a week has closed does not mutate the
    closed plan; it is preserved as rejected decision history.
  - **Missing live (cross-device) implementation of these rules is an
    implementation gap for a later slice, not an open Product Owner
    decision** — the semantics themselves are already decided.
- **Not covered by canonical documentation:** same-record `LoggedActivity`
  concurrency (two devices correcting/editing the exact same logged
  activity). This remains a genuinely open architecture/product question —
  see Section G and Section K.

Sections below are labeled **[Canonical]** where they restate the above, and
**[Foundation B recommendation]** where they are this discovery's own
architecture proposal, per the instruction not to silently elevate new
detail to canonical status.

---

## A. Current-state audit

### A.1 Persistence configuration (verified against current `develop`)

- `Sources/VoxtrCore/Persistence/SwiftDataPersistenceController.swift`:
  every `ModelConfiguration` this app constructs — both the `modelTypes:`
  initializer and the `versionedSchema:`/`migrationPlan:` initializer —
  passes `cloudKitDatabase: .none`. **One local `ModelConfiguration`, one
  local `ModelContainer`, no CloudKit involvement anywhere.**
- `Sources/VoxtrCore/Sync/SyncProviding.swift`: `SyncProviding` is an
  unused-in-production seam; the only conforming type is `NoopSyncProvider`
  (`isAvailable` always `false`, `requestSync()` a no-op). Its own doc
  comment names "a resolved zone-sharing model... flagged as a Critical item
  in the Architecture Review and still unresolved by any of the six
  governing documents" as a blocker. Section 0 above is Lead Review's answer
  to that citation for the zone-model half of it; this discovery's own zone
  architecture (Section D) is written to match it.
- `Sources/VoxtrAppShell/CompositionRoot.swift`: production default is
  `SwiftDataPersistenceController(versionedSchema: AppSchemaV11.self,
  migrationPlan: AppSchemaMigrationPlan.self)` — confirms the same
  local-only configuration is what actually ships.
- `AccountId` (`VoxtrCoreContracts`) is a `String`-backed
  `RawRepresentable` identifier. Every current construction site uses
  `AccountId.pending` — no real account system exists yet.
  `ParentProfile.accountId`, `FamilyWorkspace.technicalOwnerAccountId`, and
  `WorkspaceParticipant.accountId` are all persisted as plain `String`
  fields, so a future real value (see Section F) is a **value change, not
  a schema/type change**.
- Zero `@Relationship` usage anywhere in the entity graph (verified by
  repo-wide search). Every cross-entity reference — `athleteId`,
  `workspaceId`, `plannedActivityId`, `loggedActivityId`, etc. — is a
  plain `UUID`-backed typed ID field, resolved by explicit repository
  queries. This is a **deliberate, repeatedly-documented convention**
  (`TrainingRepository`, `PlanningRepository`, `ReflectionRepository`,
  `ActivityReminderRepository` all say so explicitly in their own doc
  comments), not an accident — and it removes an entire category of
  CloudKit/SwiftData relationship-optionality and delete-rule complexity
  before this discovery even starts.
- `@Attribute(.unique)` is applied to `id: UUID` (or the typed-ID-wrapped
  equivalent) on **every single `@Model` type in the codebase**, without
  exception (verified: 25/25 registered types, plus the unregistered
  scaffold types).
- `FamilyWorkspace`'s own doc comment already reads: *"CloudKit sharing
  root and family collaboration boundary."* This matches DDM-006 (Section
  0) exactly — the source comment and the canonical DDM agree, and this
  discovery did not need to reconcile a conflict between them.
- Optimistic concurrency (`revision: Int` + `expectedRevision:` guarded
  mutation, throwing a `staleRevision` conflict error) already exists on
  **`AthleteProfile`** (`applyMutation`) and **`WeekPlan`** (`commit`/
  `reopen`). It does **not** exist on `PlannedActivity`, `LoggedActivity`,
  or any Reflection-family entity — relevant to Section G (conflict
  semantics): the canonical Planning conflict rules (Section 0) are
  decided at the product/domain level, but `PlannedActivity` itself has no
  field-level mechanism yet to detect a same-record conflict the way
  `WeekPlan` already can.
- `VisibilityPolicy` (`VoxtrCoreContracts/SharedEnums.swift`) has exactly
  three cases: `sharedWithGuardians`, `summaryOnly`, `privateToAthlete` —
  a **per-record, user-chosen** field on `ActivityReflection`,
  `DailyStatus`, `WeeklyReflection`, `MonthlyReflection`. `PlannedActivity`
  and `LoggedActivity` carry **no** visibility field at all — Planning and
  Training data has no concept of "private," only Reflection-family data
  does. Section 0's Reflection zone model maps directly onto these three
  cases; see Section D.2 and Section B.

### A.2 App targets, entitlements, signing (verified against current `develop`)

- No `.entitlements` file exists anywhere in the repository (`find . -iname
  "*.entitlements"` returns nothing).
- `App/Voxtr.xcodeproj/project.pbxproj` contains **zero** references to
  `CloudKit`, `iCloud`, `com.apple.developer.icloud*`, or
  `SystemCapabilities` in any build configuration.
- Bundle identifiers: `app.voxtr.athlete` (AthleteApp), `app.voxtr.parent`
  (ParentApp), `app.voxtr.tests`. All build configurations set
  `CODE_SIGN_STYLE = Automatic`, `CODE_SIGNING_ALLOWED = NO`,
  `DEVELOPMENT_TEAM = ""` — signing is deliberately disabled for local/CI
  simulator builds; only `codemagic.yaml`'s `testflight-release` workflow
  performs real signing, and it does so via a Codemagic App Store Connect
  integration referenced **by name only** (`voxtr_ios_signing`,
  `"Vøxtr App Store Connect"`) — no Team ID, certificate, or provisioning
  profile lives in this repository.
- `App/ParentApp/Info.plist` carries `NSCalendarsFullAccessUsageDescription`;
  `App/AthleteApp/Info.plist` does **not** — confirms in project
  configuration, independent of any code, that Calendar access is
  Parent-only today.
- **Conclusion: iCloud/CloudKit capability is not enabled at all, for
  either app target, anywhere in the current project configuration.**
  Enabling it (an iCloud capability with a CloudKit container, plus an
  entitlements file for each target) is real, additive project
  configuration work required before any implementation slice in Section
  L can run — see Section I.

---

## B. Entity placement matrix

**[Foundation B recommendation, corrected to match Section 0's canonical
placements].** All 25 types currently registered in `AppSchema.modelTypes`
(`Sources/VoxtrAppShell/AppSchema.swift`). Unregistered scaffold types that
exist in source but are never persisted today (`TrainingAttachment`,
`PlanningDecision`, `MonthlyReflection`, `AthleteSportParticipation`,
`ActivityCategory`, and the three `VoxtrSettings` types) are listed at the
end for completeness but are **out of scope for classification** — nothing
persists them yet, so there is nothing to place.

Three placements are now in play (Section D spells out the zone
architecture in full): **Family Shared Zone**, **Athlete Private Zone**, and
**Local/private** (never leaves the device, or is a per-device projection of
something else).

| Entity | Canonical owner | Parent device needs | Athlete device needs | Placement | Reason |
|---|---|---|---|---|---|
| `FamilyWorkspace` | Parent (workspace owner) | read/write | read | **Family Shared Zone (root)** | DDM-006, LOCKED (Section 0) — the `CKShare` root record itself. |
| `ParentProfile` | Parent | read/write | read (projection only) | **Family Shared Zone, projection** + **local account binding** | Per Section 0: the whole entity is not Parent-local. A small, explicitly-approved **profile projection** (e.g. display name — never the raw local account-binding fields) is what the CKRecord mapping layer writes into the Family Shared Zone; the actual account-binding data (today: `accountId`, always `.pending`) stays local/private. See Section D.3 for how the CKRecord shape can legitimately differ from the SwiftData entity shape. |
| `WorkspaceParticipant` | FamilyWorkspace | read/write (creates/manages) | read (own row), read (others, for roster) | **Family Shared Zone** | Per Section 0. The Athlete device must see its own invited/active participant row after accepting the share (see Section F) — this is the entity Foundation A already built for exactly this purpose. |
| `AthleteProfile` | FamilyWorkspace | read/write | read/write (name/settings, subject to product permission rules — not designed here) | **Family Shared Zone** | The literal object Athlete Connection exists to give both actors access to ("connecting AthleteApp adds an actor to an existing AthleteProfile"). |
| `AthleteAccessGrant` | Parent (workspace owner) | read/write | not applicable in the first runtime slice | **Family Shared Zone** | Per Section 0 — corrected from the original discovery, which recommended Parent-local. Storage placement (Family Shared Zone) is now settled by canonical DDM and is **not** being redesigned here. Whether AthleteApp's first runtime slice actually *reads* it is a separate, narrower question — B2 does not need to consume it (Section L), which is a scoping choice about which capability ships first, not a reclassification of where the record lives. |
| `WeekPlan` | Planning | read/write | read (write once Athlete-authored planning is approved — out of scope now) | **Family Shared Zone** | Core "Planning proposes" development history; already has a `revision` field (Section A.1) usable for the canonical conflict rules (Section 0/G). |
| `PlannedActivity` | Planning | read/write | read/write (log against it) | **Family Shared Zone** | Core development history; no visibility field — safe to share unconditionally. Subject to the canonical Planning conflict rules (Section 0) once a `revision` field is added (Section G — implementation gap, not an open product question). |
| `PlanningDecision` | Planning | n/a (not yet persisted) | n/a | Not applicable | Unregistered scaffold type — nothing creates it. Note: this type's own shape (`baseRevision`/`resultingRevision`/`accepted`) already looks like it was designed to record exactly the kind of "rejected decision history" Section 0's offline-edit-after-closure rule describes — worth revisiting if/when this type is activated, not designed further here. |
| `LoggedActivity` | Training | read | read/write (this is the primary Athlete write path) | **Family Shared Zone** | Core "Training proves" development history; no visibility field. `loggedByActorId` (Foundation A) already carries cross-device-safe provenance — see Section F/G. Same-record conflict semantics remain genuinely open (Section 0/G/K) — no canonical rule exists for this entity the way one does for Planning. |
| `ActivityLoad` | Training (derived) | read | read | **Family Shared Zone** | Derived-but-stored from `LoggedActivity`; same sharing boundary as its source record. Nothing currently computes/writes it (confirmed: no repository call site) — classify now for completeness, revisit when a real producer exists. |
| `TrainingAttachment` | Training | n/a (schema-only, no upload logic per its own doc comment) | n/a | Not applicable | Unregistered scaffold type; explicitly "must not receive upload logic" (v1.3 Section 19). |
| `ActivityReflection` | Reflection (Athlete's own voice) | read (per Section 0's zone model) | read/write | **Visibility-routed — see Section D.2** | `sharedWithGuardians` rows → Family Shared Zone. `summaryOnly` rows → raw content in Athlete Private Zone, only an approved derived projection reaches the Family Shared Zone. `privateToAthlete` rows → Athlete Private Zone only, never shared. This is now canonical (Section 0), not an open question. |
| `DailyStatus` | Reflection/Sleep | read (per Section 0's zone model) | read/write | **Visibility-routed — see Section D.2** | Same routing as `ActivityReflection`. |
| `WeeklyReflection` | Reflection | read (per Section 0's zone model) | read/write | **Visibility-routed — see Section D.2** | Same routing. |
| `MonthlyReflection` | Reflection | n/a (not yet persisted) | n/a | Not applicable | Unregistered scaffold type. |
| `ParentObservation` | Reflection (Parent's own voice) | read/write | read (per Section 0's zone model; precondition already bars `.privateToAthlete` for this type, so only `sharedWithGuardians`/`summaryOnly` are reachable here) | **Visibility-routed — see Section D.2** | Symmetric case to `ActivityReflection` — Parent-authored, routed the same way. |
| `PlannedActivityDeletionTombstone` | Planning | read/write | read | **Family Shared Zone** | Must propagate so a deletion doesn't "resurrect" on the other device — see Section G. |
| `RecurringPlannedActivity` | Planning | read/write | read | **Family Shared Zone** | Definition-only; occurrences are derived at read time, not persisted separately. |
| `AthleteSettings` | AthleteProfile (per-athlete product behavior) | read/write | read (write for athlete-controlled settings — not designed here) | **Family Shared Zone** | Belongs with the `AthleteProfile` it configures; both actors already read/write different parts of the athlete's operational state today. |
| `Sport` | Core reference data | read | read | **Local, independently seeded** (not synced at all) | Deterministic, app-shipped reference catalog (`SportRepository` seeds it identically on every install) — nothing to sync; syncing it would only add risk for zero benefit. |
| `ActivityCategory` | Core reference data | n/a (not yet persisted) | n/a | Not applicable | Unregistered scaffold type. |
| `ActivityReminder` | Notifications (canonical intent) | read/write | read (write if Athlete-created activities gain reminders — not designed now) | **Family Shared Zone** | Pure intent (`athleteId`, `plannedActivityId`, `leadTimeMinutes`, `reminderText`) — no device/delivery state on this type at all (confirmed by inspection: no notification identifier, no delivery flag). The **realization** (an actual `UNNotificationRequest`) is not a persisted entity anywhere in this codebase; each device schedules its own local notification from the synced canonical intent — this is not a new pattern, it is the same "derive locally from canonical shared truth" shape `TodayActivityComposer` already uses. |
| `CalendarPlanningMapping` | Calendar (legacy, Parent-only) | read (dead code path — see its own doc comment, "no live path creates new rows") | none | **Local/private (Parent device)** | Superseded by `ExternalPlanningSource`/`CalendarImportDecision`; kept registered only so a pre-existing row stays readable for one-time migration. Not addressed by Section 0 — this discovery's own reasoning (Parent-only capability) stands. |
| `ExternalPlanningSource` | Calendar (Parent-only capability, explicit product rule) | read/write | none | **Local/private (Parent device)** | Calendar import remains a Parent-only capability by explicit product contract restated in this very task — do not expose it to AthleteApp merely because the workspace is shared. Not addressed by Section 0's zone model; unaffected by this correction pass. |
| `CalendarImportDecision` | Calendar (Parent-only) | read/write | none | **Local/private (Parent device)** | Same reasoning; `decidedBy` is documented as "never `.system`," always the real Parent `ActorId`. |
| `DecomposedActivityLink` | Calendar (Parent-only provenance) | read/write | none | **Local/private (Parent device)** | Provenance of a Parent-approved calendar split; the resulting `PlannedActivity` rows (already Family Shared Zone) are what the Athlete needs, not this bookkeeping. |
| `DecompositionEvidence` / `DecompositionEvidenceChild` | Calendar (Parent-only) | read/write | none | **Local/private (Parent device)** | Same reasoning; durable evidence for future Suggested Split proposals, meaningless outside the Parent's own calendar-review flow. |
| `AppDiagnosticsRecord` | App shell (Sprint 0 scaffold) | read/write | read/write | **Local-only, per install** | Explicitly "not a business entity" per its own doc comment; has no `id`, no owner concept, exists only to prove SwiftData round-trips. |

Unregistered scaffold types (not persisted by anything today — listed for
completeness only, not classified): `TrainingAttachment`, `PlanningDecision`,
`MonthlyReflection`, `AthleteSportParticipation`, `ActivityCategory`,
`AppPreference`, `FeatureFlagOverride`, `PrivacyPreference` (the three
`VoxtrSettings` types).

### B.1 Cross-cutting classification notes

- **External Calendar integration is entirely Parent-local.** Every
  Calendar-domain entity (`ExternalPlanningSource`, `CalendarImportDecision`,
  `DecomposedActivityLink`, `DecompositionEvidence*`, legacy
  `CalendarPlanningMapping`) stays off any CloudKit zone completely. Only
  the **output** of Calendar import — an ordinary `PlannedActivity` row,
  already in the Family Shared Zone — ever reaches the Athlete device. This
  matches the explicit product rule verbatim and required no invention, and
  is unaffected by the Section 0 corrections (Section 0 does not mention
  Calendar-domain entities).
- **Notifications: canonical intent is Family Shared Zone content, device
  realization never persists at all.** There is no persisted "scheduled
  notification" model to classify — the split the task asked to verify
  already exists structurally.
- **Reference data (`Sport`) does not need sync.** It is deterministic and
  identically seeded on every install; syncing it would add CloudKit
  record traffic and conflict surface for a catalog that is never
  supposed to differ between devices.

---

## C. SwiftData/CloudKit compatibility findings

Unchanged by this correction pass — none of Section 0's canonical decisions
touch SwiftData's own CloudKit-mirroring feature or `@Attribute(.unique)`.
Verified against current, documented Apple platform behavior (SwiftData
CloudKit mirroring shipped with iOS 17/Xcode 15 and is materially unchanged
through the current iOS 18-era SDKs; corroborated via web search against
current-dated sources, not solely training-data recall, precisely because
getting this wrong would misdirect the next implementation task).

| Feature | Compatibility with `ModelConfiguration(cloudKitDatabase: .automatic/.private)` | Classification |
|---|---|---|
| `@Attribute(.unique)` | **Not supported.** SwiftData's CloudKit-backed configuration refuses to load a container containing any unique constraint — CloudKit has no way to enforce cross-device atomic uniqueness for offline-capable clients. | **Blocker** for any entity placed under a CloudKit-mirrored `ModelConfiguration`. |
| Non-optional properties without defaults | Every property must be optional or carry a default value. | **Requires migration** if that configuration were ever used — not touched by the recommended architecture (Section E). |
| Relationships | Must be optional; `.deny` delete rule unsupported. | **Not applicable** — this codebase has zero `@Relationship` usage (Section A.1). |
| `VersionedSchema`/`SchemaMigrationPlan` | Unaffected by CloudKit mirroring itself; migration stages still run the same way. | **Safe as-is**, and irrelevant to the recommended architecture since it does not enable SwiftData's own CloudKit mirroring for any entity (Section D). |
| Multiple `ModelConfiguration`s / stores in one container | SwiftData supports multiple configurations (e.g. one CloudKit-mirrored, one local-only) sharing a schema. | **Safe as-is**, but not needed by the recommendation — see Section D. |
| **CKShare / multi-user sharing** | SwiftData's public API surface (`ModelConfiguration(cloudKitDatabase:)`) mirrors a schema to a user's own **private** CloudKit database across their own devices only. It exposes **no** documented, first-class API for creating or accepting a `CKShare` (the Core Data equivalent is `NSPersistentCloudKitContainer.share(_:to:)` plus a second `sharedStoreOptions.databaseScope = .shared` persistent store description). This gap is corroborated by current (2026-dated) developer-community sources as still present. | **Blocker for Options A and B as literally specified** — see Section D. |
| `ModelContainer`/`AppSchema` frozen historical model types | Unrelated to CloudKit; this project's schema-freeze convention (`AppSchemaV3.LoggedActivity`, `AppSchemaV5.ActivityReminder`, etc.) keeps working regardless of what the recommendation decides. | **Safe as-is.** |
| Custom `Codable` types stored directly on a `@Model` (e.g. `LocalDate`) | Already a documented, real crash this codebase hit and fixed (`AthleteProfile.birthDateRaw`, `WeekPlan.weekStartRaw`, etc. — all now plain `String`). Not a CloudKit-specific issue, but the same "custom-decoder" fragility class applies doubly under CloudKit's own record-to-property mapping. | **Already mitigated** by this project's own established pattern (store as `String`/primitive, expose a computed typed wrapper) — the recommended architecture's CKRecord mapping layer should follow the exact same convention, mapping the already-`String`/primitive-backed storage fields, never the computed `LocalDate`/`AthleteColor`/etc. wrapper types directly. |

**No SwiftData schema rewrite is proposed or required by this discovery.**
The blockers above apply specifically to SwiftData's *own* `cloudKitDatabase:`
mirroring feature — the recommended architecture (Section D/E) does not turn
that feature on for any entity, so none of these blockers are actually
triggered in practice.

---

## D. Architecture options considered

### Option A — one CloudKit-backed SwiftData store

**Purpose fit:** Does not support real Parent ↔ Athlete sharing. SwiftData's
`cloudKitDatabase:` mirroring is private-database (single user, multiple own
devices) sync — it has no participant/CKShare concept at all. Parent and
Athlete are different iCloud accounts; nothing in SwiftData's public API
grants one account read/write access to another account's private database.

**Requirements/consequences:** Would additionally require removing
`@Attribute(.unique)` from all 25 entity types (a real, disruptive schema
change to this project's core identity pattern) — moot, since the sharing
requirement is unmet regardless.

**Risks:** None worth enumerating further — this option cannot satisfy the
stated objective on current, verified Apple framework capability.

**Implementation shape:** N/A.

**Recommendation status: reject.** Not a matter of preference — a verified
platform capability gap. Unaffected by the Section 0 corrections.

---

### Option B — separate local/private/shared persistence topology (as literally specified: three SwiftData-flavored stores)

**Purpose fit:** The *locality* thinking (some data local-only, some
private-synced, some shared) is correct, and Section 0's canonical zone
model (Family Shared Zone / Athlete Private Zone / local) confirms this
shape is exactly right at the product level — but "a shared CloudKit store"
and "an Athlete-owned private CloudKit store" cannot be `ModelConfiguration`s
on the same `ModelContainer` the way local + private-mirrored can, because
SwiftData has no shared-database (or cross-account private-database)
configuration to hand it — see Section C.

**Requirements/consequences:** The private-mirroring tier SwiftData *does*
support (one user's own data synced across their own multiple devices) is
real and available, but is a different thing from the Athlete Private Zone
Section 0 describes (which must be reachable from the Family Shared Zone's
transport layer too, for the `summaryOnly` derived-projection case — Section
D.2) and would independently require dropping `@Attribute(.unique)` on
whatever subset of entities it covered.

**Risks:** Attempting to implement either CloudKit-backed tier as a
SwiftData `ModelConfiguration` would fail outright (no such CloudKit
database scope exists in the SwiftData API) — a team without this
discovery's research would likely lose real implementation time discovering
this the hard way.

**Implementation shape:** N/A for the CloudKit-backed tiers as literally
specified.

**Recommendation status: viable fallback for the *local-only* tier only** —
folded into the recommendation (Section E) as "Local/private" placement.
The Family Shared Zone and Athlete Private Zone tiers are implemented per
Option C instead (Section D, D.2).

---

### Option C — explicit CloudKit transport/repository layer (canonical domain model unchanged)

**Purpose fit:** This is the only option that can satisfy genuine
cross-account (Parent ↔ Athlete) sharing on the approved Apple-native
direction, because it uses CloudKit's actual multi-user primitive
(`CKShare` + a shared `CKRecordZone`) directly, rather than routing through
a SwiftData feature that does not expose it. It also naturally extends to
the Athlete Private Zone Section 0 requires (Section D.2), which a
SwiftData-only approach could not reach either.

**Requirements/consequences:**
- **Schema impact:** none. SwiftData's own schema/migration
  infrastructure is untouched; `cloudKitDatabase: .none` stays exactly as
  it is today, for the one local `ModelConfiguration`, unconditionally.
- **Migration impact:** additive only — see Section F.
- **Identity impact:** none, by construction — the transport layer maps
  each shared entity's existing `id: UUID` 1:1 to a `CKRecord.ID`
  (`recordName = id.uuidString`), inside the appropriate zone (Section
  D.2). No identity is ever generated on the receiving device.
- **CloudKit constraints:** `@Attribute(.unique)` is never touched, because
  the shared entities' local SwiftData storage is never itself
  CloudKit-mirrored — the CKRecord layer reads/writes the *same* local
  SwiftData store every other repository already reads/writes, through
  the *same* existing repository methods, the same way `EventKitCalendarEventProvider`/
  Calendar Import already ingests external provider data into canonical
  `PlannedActivity` rows today via an explicit mapping layer, never SwiftData
  magic mirroring. This is a real, working precedent already in this codebase for
  exactly this shape of integration.
- **Conflict handling:** CloudKit's own per-record `recordChangeTag`
  detects a stale write and returns `.serverRecordChanged` with the
  ancestor/client/server record triple; the app must decide how to
  reconcile. Section 0's canonical Planning conflict rules give this a
  concrete target for `PlannedActivity`/`WeekPlan`; this project already
  has a proven mechanism to extend (`AthleteProfile.applyMutation`/
  `WeekPlan.commit`'s `expectedRevision` + `staleRevision` conflict error)
  — see Section G for exactly what implementation work (not product
  decision) remains.
- **Testability:** every existing repository/service call, and every
  existing `InMemoryPersistenceController`-based test, is completely
  unaffected — the transport layer is additive, sitting *outside* the
  domain/repository boundary, calling the same public repository methods
  any other caller (e.g. Calendar import) already calls.
- **Maintenance cost:** real, and should not be understated — this is
  hand-written CKRecord serialization/deserialization and sync-state
  bookkeeping for the Family-Shared-Zone entity set (Section B), plus a
  second, smaller mapping for the Athlete Private Zone (Section D.2).
  `CKSyncEngine` (available since iOS 17) meaningfully reduces this cost
  versus hand-rolled `CKModifyRecordsOperation`/
  `CKFetchRecordZoneChangesOperation` — it owns push-notification wake-up,
  change-token bookkeeping, batching, and retry — but does not eliminate
  the record-mapping work itself. **`CKSyncEngine` supports exactly this
  two-zone shape**: an app may run multiple `CKSyncEngine` instances in one
  process, each targeting a different database (e.g. one against
  `CKContainer.default().privateCloudDatabase` for the Athlete's own
  private zone, one against `.sharedCloudDatabase` for the Family Shared
  Zone) — current Apple guidance is explicit that one `CKSyncEngine`
  instance must own exactly one database, and running two instances
  against the *same* database causes them to race each other, so the
  private/shared split maps cleanly onto "one engine each," never one
  engine for both. It also has a documented rough edge (does not
  automatically re-fetch when a `CKShare` record itself changes without an
  app relaunch) worth planning around explicitly in the implementation
  slice that adopts it.
- **Future scalability:** does not fork Planning/Training/Reflection
  services by role, does not duplicate PlannedActivity/LoggedActivity per
  actor, and keeps CloudKit strictly as transport — matching the "CloudKit
  is transport/persistence infrastructure, it must not become a second
  business-rule owner" requirement directly.

**Risks:**
- Genuine hand-built sync complexity (see maintenance cost above), now
  across two zones/databases rather than one.
- The `summaryOnly` derived-projection mechanism (Section D.2) is real,
  unsolved-by-the-platform (CloudKit has no "compute a projection on
  write" primitive), and must be designed deliberately by whichever slice
  builds Reflection sharing.
- `CKSyncEngine`'s `CKShare`-change-notification gap is a concrete,
  named risk for whichever implementation slice handles share-state
  transitions (new participant accepted, permission changed, etc.).

**Implementation shape (high-level only, not designed further here):** one
`FamilyWorkspace`-rooted `CKRecordZone` (Family Shared Zone) per family in
the shared database, one `CKShare` on that zone's root record; a separate,
per-athlete private zone (Athlete Private Zone) in the Athlete's own private
database for `summaryOnly`/`privateToAthlete` raw Reflection content; a
small explicit `CloudKitFamilyWorkspaceSyncService` (or similar) in
`VoxtrAppShell` — the module already allowed to see every domain — driving
two `CKSyncEngine` instances (Section D above), translating between CKRecord
and the existing repositories' insert/update calls, keyed by each entity's
own `id: UUID`.

**Recommendation status: recommended.**

### D.2 Zone architecture — [Foundation B recommendation, structured around Section 0's canonical zone model]

Three placements, not two:

**A. Family Shared Zone.** One `CKRecordZone`, rooted at the
`FamilyWorkspace` record, under one `CKShare` with the Parent (owner) and
every accepted Athlete participant. Holds every entity classified "Family
Shared Zone" in Section B — the Planning/Training development graph,
`WorkspaceParticipant`/`AthleteProfile`/`AthleteAccessGrant`/`AthleteSettings`,
the `ParentProfile` projection, `ActivityReminder` intent, and (per Section
0) `ActivityReflection`/`DailyStatus`/`WeeklyReflection`/`ParentObservation`
rows whose `visibility == .sharedWithGuardians`, plus the approved derived
projection of `summaryOnly` rows (see below).

**B. Athlete Private Zone.** A private `CKRecordZone` in the Athlete's own
CloudKit private database — never shared with the Parent's CKShare at all.
Holds the **raw** content of Reflection-family rows whose `visibility` is
`summaryOnly` or `privateToAthlete`, per Section 0. This is what gives the
Athlete's private reflections a genuine cross-device sync path (e.g. the
Athlete's own phone and tablet) without ever exposing that raw content to
the Parent — solving the gap the task explicitly warned against ("private
Athlete reflections have no cross-device private sync path").

For `summaryOnly` specifically: the **raw** row lives only in the Athlete
Private Zone; a separate, explicitly-approved **derived projection** (e.g.
a existence flag, a coarse numeric summary — the exact shape is a product
decision, not invented here) is written by the same transport layer into
the Family Shared Zone as its own, smaller record, linked to the raw
record's stable ID but never containing its free-text content. This
projection mechanism is new work — CloudKit has no built-in "compute a
projection on write" feature — flagged as a concrete implementation item
for whichever slice builds Reflection sharing (Section L, B4), not
designed further here.

**C. Local/private storage.** Unchanged from the original discovery:
everything classified "Local/private" in Section B (Calendar-domain
entities, `Sport`, `AppDiagnosticsRecord`) plus the Parent's own local
account-binding data (the non-projected part of `ParentProfile`, per
Section 0) never gets a CKRecord in any zone.

### D.3 CKRecord shape need not mirror the SwiftData entity shape

`ParentProfile`'s correction (Section B) depends on a point worth stating
explicitly: the explicit CKRecord mapping layer that Option C already
requires (it is hand-written, not SwiftData's automatic mirroring — Section
C) can freely map a **subset** of an entity's local fields into a Family
Shared Zone record, or map several local fields into a differently-shaped
projection record, exactly as it already must for the `summaryOnly`
Reflection case (Section D.2). Nothing about Option C requires a 1:1
field-for-field CKRecord per SwiftData `@Model`. This is what makes "shared
Parent profile projection, private account binding" implementable as one
entity with two destinations, rather than requiring the entity itself to be
split in SwiftData.

---

## E. Recommended architecture

**Option C**, refined as follows:

1. **SwiftData stays exactly as it is today** for every entity, in every
   zone: one `ModelContainer`, one local `ModelConfiguration`,
   `cloudKitDatabase: .none`, unchanged migration/versioning conventions,
   `@Attribute(.unique)` untouched everywhere. No schema rewrite.
2. A **new, explicit CloudKit sync layer** (owned by `VoxtrAppShell`, the
   one module already allowed to see every domain) uses `CKContainer` /
   `CKDatabase` / `CKShare` / two `CKSyncEngine` instances (Section D) to
   mirror:
   - the Family-Shared-Zone-classified entities (Section B) between each
     device's own local SwiftData store and the one `FamilyWorkspace`-rooted
     `CKRecordZone` in the shared database, and
   - the Athlete-Private-Zone content (Section D.2) between the Athlete's
     own devices, via that Athlete's own private database,
   using each entity's existing `id: UUID` as the `CKRecord.ID.recordName`
   throughout.
3. **Local/private**-classified entities (Section B) are never given a
   CKRecord in any zone at all — they remain exactly as invisible to
   CloudKit as they are today.
4. The domain/repository/service layer is completely unaware this sync
   layer exists — it calls the same `insert`/`fetch`/`update` methods any
   other caller (including today's Calendar import path) already calls.
   "CloudKit is transport, not a business-rule owner" is satisfied by
   construction, not by convention alone.

This satisfies the Decision Rule's eight criteria directly: One Truth and
stable IDs are structural (Section D "identity impact"); the same canonical
domain services are reused verbatim; there is no *invented* sync logic
beyond what `CKSyncEngine` already provides (the `summaryOnly` projection is
the one genuinely new piece of logic, and it is explicitly named as such,
not hidden); migration is additive-only (Section F); the architecture stays
offline-first (local SwiftData writes always succeed immediately; CloudKit
sync is a background concern layered on top, unchanged by this correction);
it matches DDM-006 and the rest of Section 0 exactly; and
it is the only option that reaches a credible cross-device Alpha proof at
all, since Options A/B cannot reach one.

**Option C remains recommended after this correction pass** — the review
requested by this follow-up did not surface a new blocker; it corrected
where several entities belong within Option C's own zone model.

---

## F. Existing-data migration strategy

No silent reset, no regenerated IDs, no duplicate rows — for any of the five
categories the task named. Unaffected in substance by this correction pass,
except that the one-time backfill now targets two destinations (Family
Shared Zone and, for `summaryOnly`/`privateToAthlete` Reflection content,
the Athlete Private Zone) instead of one:

- **Existing Parent-only family:** unaffected until the Parent explicitly
  connects an Athlete (Section L, slice B3). No `CKRecordZone` or `CKShare`
  is created for a workspace that has never invited an Athlete participant
  — a Parent-only install stays 100% local, exactly as it is today, with
  zero behavior change.
- **Existing AthleteProfiles:** the moment a workspace's first Athlete
  participant is invited, the implementation slice that creates the Family
  Shared Zone/`CKShare` performs a **one-time backfill**: every
  currently-local row classified "Family Shared Zone" (Section B) for that
  workspace is pushed up as a CKRecord keyed by its own existing `id`,
  never a new one — including, per Section B's correction, the
  `AthleteAccessGrant` rows and the `ParentProfile` projection. The local
  SwiftData store remains the on-device source of truth throughout — the
  shared zone is *populated from* it, not the other way around.
- **Current `WorkspaceParticipant`:** Foundation A's existing invite flow
  (`ParentWorkspaceRepository.createInvitedAthleteParticipant`) is
  unchanged; the CloudKit layer only adds *transport* for that already-real
  row once the share exists.
- **Historical `LoggedActivity` with `loggedByActorId == nil`:** migrates
  into the Family Shared Zone exactly like any other `LoggedActivity` row —
  the CKRecord simply carries the same `nil`/absent value. Nothing
  fabricates an actor at the CloudKit boundary; Foundation A's "nil means
  honestly unknown" contract is preserved end to end.
- **Existing Reflection-family rows:** at the point Reflection sharing is
  actually implemented (Section L, B4), existing rows backfill per Section
  0's routing — `sharedWithGuardians` rows into the Family Shared Zone,
  `summaryOnly`/`privateToAthlete` rows' raw content into the Athlete
  Private Zone (with a derived projection computed and pushed for
  `summaryOnly` rows at that time) — never the reverse, and never mixed.
- **Calendar source mappings, reminders, local diagnostics:** per Section
  B, Calendar-domain entities and diagnostics are never pushed to any
  CloudKit zone at all — "migration" for them is simply "no change."
  Reminders' canonical `ActivityReminder` intent rows follow the same
  one-time backfill as any other Family-Shared-Zone entity; no
  device-local notification state exists to migrate (Section B.1).

---

## G. Conflict/concurrency findings

**[Section 0's Planning rules are Canonical; the rest of this section is
Foundation B's own analysis of what remains open.]**

- **Different objects** (Parent plans one activity, Athlete logs another):
  converge naturally — two independently-created records with distinct
  stable IDs, no merge required.
- **Same `PlannedActivity` edited by Parent while Athlete logs it:** these
  are, in practice, two different records — logging creates a *new*
  `LoggedActivity` referencing the `PlannedActivity` by ID; `TrainingService`'s
  existing `plannedActivityAlreadyLinked` guard (an app-level invariant,
  unrelated to CloudKit) already prevents a double-link.
- **True same-`PlannedActivity`-record conflict, and `WeekPlan` conflicts:**
  **already decided at the product/domain level (Section 0):** different
  `PlannedActivity` records may merge; edits to the *same* `PlannedActivity`
  must not use last-write-wins and must preserve both versions for explicit
  resolution; a delete-versus-edit of the same record requires explicit
  resolution; `WeekPlan.commit` against unresolved conflicting content is
  rejected; an offline edit made after week closure is preserved as
  rejected decision history rather than mutating the closed plan. **What
  remains is an implementation gap, not a product decision:** `WeekPlan`
  already has the `revision`/`expectedRevision`/`staleRevision` mechanism
  these rules can be built on; `PlannedActivity` does not yet have an
  equivalent field, and no slice yet wires CloudKit's own
  `.serverRecordChanged` detection into either. Both are concrete follow-up
  implementation work for the slice that builds Planning sharing (Section
  L, B2), not something requiring further Product Owner input.
- **Same `LoggedActivity` edited/corrected by both Parent and Athlete:**
  **genuinely open** — no canonical rule exists for this entity the way one
  now does for Planning (Section 0 explicitly does not cover it). This
  discovery does not invent an answer; it is named as an open item (Section
  K) for whichever slice needs it.
- **Reflection duplicate guard `(loggedActivityId, athleteId)`:** inspection
  suggests this is very likely still correct, not a defect Foundation B
  needs to fix — `ActivityReflection` already appears to be modeled as
  specifically the **Athlete's own voice** (its `authorId` is set from
  Reflection's existing "Athlete authors their own reflection" call paths),
  with the Parent's equivalent commentary already living on a **separate**
  entity, `ParentObservation`, which has no such duplicate guard at all. If
  that reading is correct, the existing guard does not need to change for
  shared/multi-actor use, and this is unaffected by the Section 0 zone
  corrections (which govern *where* a reflection is stored, not the
  duplicate-guard's own key). Still flagged for explicit Product
  confirmation before a Reflection-sharing slice begins (Section K) — this
  discovery flags it, it does not decide it.
- **Deletes/tombstones:** `PlannedActivityDeletionTombstone` already exists
  and is classified Family Shared Zone (Section B) specifically so a
  deletion propagates as a tombstone record, not a silent local-only
  removal — a device that synced the original `PlannedActivity` before the
  delete will see the tombstone and know not to resurrect it. Reversible
  actions (Reopen Activity, Reopen Planning) are ordinary field mutations
  on already-shared entities and need no special sync handling beyond what
  this section's conflict handling already covers.

---

## H. Athlete participant/session-resolution architecture

Foundation A already solved "which `WorkspaceParticipant` is acting in this
session" (`CurrentSessionActor`) — never solved "which physical device/
iCloud account maps to which specific `WorkspaceParticipant` row."

**Verified, publicly documented Apple APIs relevant to this mapping**
(not speculative pseudo-APIs; corrected in this revision to use current,
non-deprecated participant-lookup APIs — see the note at the end of this
list):

- `CKShare.url` — a stable share URL tied to the share's root record;
  re-sharing the same root record after deleting a share reproduces the
  same URL.
- `CKShare.Metadata` — fetched from a share URL (or from the system
  invitation-acceptance entry point below); carries `.share`, `.rootRecord`/
  `.rootRecordID`, `.participantRole`, `.participantStatus`.
- `CKContainer.accept(_:) async throws` — accepts a fetched
  `CKShare.Metadata`.
- `UICloudSharingController` — the system share-sheet UI for creating and
  distributing a share (Messages/Mail/AirDrop/link).
- `CKShare.Participant` — has `.userIdentity: CKUserIdentity`, `.role`,
  `.permission`, `.acceptanceStatus`; `CKUserIdentity.userRecordID:
  CKRecord.ID?` is the resolvable per-container identity of a specific
  invited participant.
- `CKContainer.userRecordID` (or `fetchUserRecordID()`) — the **current
  device's own** `CKRecord.ID` within this app's CloudKit container. This
  is a documented, stable, app-scoped identifier — not a global Apple ID,
  not an email address, not an undocumented private identifier — and is
  the right building block for the mapping this section needs.
- `Info.plist` `CKSharingSupported = true` — required for the app to
  receive/handle incoming share-acceptance URLs at all.
- **Participant lookup, to resolve an out-of-band Athlete identifier to a
  `CKUserIdentity`/`userRecordID` before adding them to the share:**
  `CKContainer.fetchShareParticipant(withEmailAddress:)`,
  `fetchShareParticipant(withPhoneNumber:)`, and
  `fetchShareParticipant(withUserRecordID:)` are the current APIs for this.
  **The recommended flow explicitly does not use `discoverUserIdentity(...)`
  or `requestApplicationPermission(.userDiscoverability)`** — both are
  deprecated in favor of the `fetchShareParticipant` family, per current
  Apple documentation.

### H.1 Concrete flow (design-level; UI and full plumbing are a later slice)

**Parent:**
1. `FamilyWorkspace`, `AthleteProfile` already exist (or are created).
2. Parent invites the Athlete via Foundation A's existing
   `ParentWorkspaceRepository.createInvitedAthleteParticipant` — an
   `.invited`-state `WorkspaceParticipant` with `linkedAthleteId` now
   exists, exactly as today.
3. The implementation slice creates (or reuses) the workspace's Family
   Shared Zone `CKRecordZone` and a `CKShare` rooted at the
   `FamilyWorkspace` record, if this is the family's first Athlete
   connection.
4. Parent resolves the Athlete's `CKUserIdentity` via
   `CKContainer.fetchShareParticipant(withEmailAddress:)`/
   `fetchShareParticipant(withPhoneNumber:)` (driven by an out-of-band
   identifier the Athlete provides *only for lookup* — never stored as
   Vǫxtr identity) and adds them as a `CKShare.Participant` with a role.
5. The share is distributed via `UICloudSharingController` (Messages/
   Mail/AirDrop/link) — an Apple-system-supported mechanism, not a custom
   transport.

**Athlete:**
1. Accepts the share (system share-sheet flow → `CKContainer.accept(_:)`).
2. The Family Shared Zone's records — including the invited
   `WorkspaceParticipant` row itself — sync down via the shared-database
   `CKSyncEngine` instance (Section D) into the Athlete device's own local
   SwiftData store, through the same repository insert paths any other
   sync write uses.
3. AthleteApp resolves **which** locally-visible `WorkspaceParticipant` row
   is *this device's own* participant — see H.2 (the durable mapping) —
   and constructs `CurrentSessionActor.resolve(from:)` from it, exactly as
   Foundation A already defined.
4. From that point on, every existing domain service
   (`TrainingReflectionCoordinationService`, `PlanningService`, etc.)
   operates on the same canonical local SwiftData store any other caller
   uses — no forked services, no UI designed here.

### H.2 The durable mapping ("critical security/identity question")

**Do not assume `accepted CKShare participant == WorkspaceParticipant`
without an explicit, durable mapping — confirmed as a real requirement, not
a hypothetical caution.** Two viable mechanisms were evaluated:

1. **Custom field on the `CKShare`/root record** (simple, valid only for a
   one-athlete-per-share topology): at invite time, Parent writes the
   invited `WorkspaceParticipant.id` (already a stable UUID — the same
   value `CurrentSessionActor.actorId` is built from) as an ordinary custom
   field on the `CKShare` record (`share["voxtrParticipantId"] =
   participant.id.uuidString`) — completely standard, documented CKRecord
   usage, not a private API. The accepting device reads it straight off
   the `CKShare.Metadata.share` it was just granted. Breaks down the moment
   a single share has more than one Athlete participant.
2. **`CKUserIdentity.userRecordID`-keyed mapping** (general, multi-athlete-
   safe — **recommended**): when Parent resolves and adds a specific
   `CKUserIdentity` as a participant (H.1 step 4, via
   `fetchShareParticipant`), Vǫxtr records that resolved `userRecordID` as
   an ordinary synced field on the *same* `WorkspaceParticipant` row
   already in the Family Shared Zone (a small additive field, not a schema
   redesign). On the Athlete device, after accepting, `CKContainer.userRecordID`
   gives "who am I," and the app selects the one now-locally-visible
   `WorkspaceParticipant` row whose recorded mapping value matches it.

Both mechanisms use only documented, public CloudKit API surface. Neither
stores an email address, a global Apple ID, or an undocumented private
identifier as durable Vǫxtr identity — matching every explicit caution in
the task. **`AccountId` (currently always `.pending`, already `String`-typed
on every entity that carries it) is the natural home for this value once a
real mechanism is implemented** — a value change, not a type/schema change
(Section A.1).

The actual invite-time Athlete-lookup UX (how the Parent supplies an
out-of-band identifier to resolve a `CKUserIdentity` in the first place) is
implementation-level and is not designed further here — see Section H,
"UI and full plumbing are a later slice."

---

## I. ParentApp/AthleteApp entitlement/configuration findings

See Section A.2 in full. Summary: **no entitlements file, no iCloud
capability, no CloudKit container, no Team ID/signing material anywhere in
this repository today.** The first implementation slice (Section L, B1)
must add, for both `ParentApp` and `AthleteApp` targets: an iCloud
capability with CloudKit enabled, a shared CloudKit container identifier (a
project-configuration change, not a code change), a `.entitlements` file
per target, and `CKSharingSupported = true` in each target's `Info.plist`.
This discovery performed **read-only** inspection only, per its own
instruction to prefer that and avoid touching signing/provisioning/
entitlements even reversibly — no such changes were made, in the original
discovery or in this correction pass.

---

## J. Technical experiments performed

**None were run as compile-time/runtime spikes in this repository**, in
either the original discovery or this correction pass. Every architecture
question needed to answer this follow-up (current `fetchShareParticipant`
API names, `CKSyncEngine` multi-instance/multi-database support) was
settled the same way as the original discovery's questions — current
(2026-dated), cross-corroborated, publicly documented Apple platform
behavior — not something a local compile-only spike in this sandbox (no
Swift toolchain available in this environment) could verify more reliably
than the sourced documentation already does.

---

## K. Open risks / decisions requiring Product Owner or Architecture input

**[Revised: items resolved by Section 0's canonical DDM are removed or
reclassified below; only genuinely open items remain.]**

1. ~~The "six governing documents" citation~~ — **resolved for this
   discovery's purposes.** Lead Review supplied the relevant canonical
   decisions (Section 0); this discovery's zone architecture (Section D/D.2)
   is now built directly from them rather than guessing at them.
2. **Reflection visibility downgrade after a record has already synced**
   (e.g. `sharedWithGuardians` → `summaryOnly`/`privateToAthlete`, or
   `summaryOnly` → `privateToAthlete`) — genuinely still open. Section 0
   establishes *where* each visibility level's raw content lives, but not
   how a **transition** between them is migrated/removed once content has
   already reached a device that should no longer have it. Specifically
   unresolved: how the CKRecord(s) in the Family Shared Zone (the raw
   `sharedWithGuardians` record, or a `summaryOnly` projection record) are
   safely deleted/retracted; how to preserve the Athlete's own local
   canonical content through the transition without ever having leaked the
   previously-shared raw text further; and how the app confirms deletion
   has actually propagated (eventual consistency) before it can honestly
   claim the privacy transition is complete. This needs an explicit product
   decision on acceptable behavior, not a technical guess.
3. ~~Whether `AthleteAccessGrant` should ever become Athlete-visible~~ —
   **resolved for storage placement** (Section 0: Family Shared Zone).
   What remains open is only an implementation *scoping* question, not a
   product one: whether the first runtime slice (B2, Section L) needs to
   actually build AthleteApp consumption of it, or can defer that — this
   discovery recommends deferring it, since nothing in Foundation A/B
   requires AthleteApp to read it yet.
4. **The Reflection duplicate-guard question** (Section G) — this
   discovery's reading (the existing `(loggedActivityId, athleteId)` guard
   is likely still correct because `ParentObservation` already carries the
   Parent's side) should be explicitly confirmed, not assumed, before a
   Reflection-sharing implementation slice begins. Unaffected by the
   Section 0 corrections.
5. ~~`PlannedActivity`/`WeekPlan` conflict semantics~~ — **resolved as
   product/domain decisions** (Section 0). What remains is implementation
   work (a `revision` field on `PlannedActivity`, wiring
   `.serverRecordChanged` handling), tracked in Section G/L, not a Product
   Owner question.
6. **`LoggedActivity` same-record conflict semantics** — **genuinely
   open**, since Section 0 does not cover this entity. Does Training ever
   need something other than last-write-wins? What does a conflict look
   like to a user? Real product/UX consequences, not decided here.
7. **The Athlete-lookup UX at invite time** (Section H.2) — how a Parent
   supplies an out-of-band identifier to `fetchShareParticipant` — is a
   real product/UX design question, not solved here. Unaffected by the
   Section 0 corrections.
8. **The `summaryOnly` derived-projection shape** (Section D.2) — what,
   specifically, an approved "summary" of a private reflection contains —
   is a genuine product decision (a coarse numeric signal? an existence
   flag? something else?), not invented by this discovery.

---

## L. Recommended next implementation slices, in order

**[Foundation B recommendation — adjusted from the original discovery so
B2 correctly includes `AthleteAccessGrant`/the `ParentProfile` projection,
and so the Reflection slice (B4) is explicit about needing the Athlete
Private Zone, not just "Reflection sharing" in the abstract.]**

- **B1 — Persistence/entitlement foundation.** Add iCloud/CloudKit
  capability + entitlements + `CKSharingSupported` to both app targets
  (Section I); introduce the explicit CloudKit sync layer's skeleton
  (`CKContainer`/`CKDatabase` access, both `CKSyncEngine` instances —
  Section D — wired to their respective private/shared databases) with
  **no** entity mapping wired up yet — provable independently via a
  Parent-only device successfully creating an (empty) Family Shared Zone
  `CKRecordZone` for its `FamilyWorkspace`.
- **B2 — FamilyWorkspace sharing transport.** Implement the `CKShare`
  creation/distribution flow (Section H.1 Parent steps 3-5, using
  `fetchShareParticipant`) and the Athlete acceptance flow (H.1 Athlete
  step 1-2) for the Family-Shared-Zone entities that have **no**
  `visibility` field (Section B — no Section D.2 projection problem to
  solve yet): `FamilyWorkspace`, `WorkspaceParticipant`, `AthleteProfile`,
  `AthleteSettings`, `AthleteAccessGrant`, the `ParentProfile` projection
  (Section D.3), `WeekPlan`, `PlannedActivity`,
  `PlannedActivityDeletionTombstone`, `RecurringPlannedActivity`,
  `LoggedActivity`, `ActivityLoad`, `ActivityReminder`. Implement the H.2
  durable-mapping mechanism here. `AthleteAccessGrant` and the
  `ParentProfile` projection are included in the *storage* transport built
  in this slice even if AthleteApp does not yet build UI that reads them
  (Section K item 3) — that is a UI-scoping choice, not a reason to leave
  them out of the sync layer itself.
- **B3 — Minimal Parent connect + Athlete accept/session resolution.**
  Build the actual (currently out-of-scope-until-now) Athlete
  Connection UI: Parent-side "connect this athlete" action, Athlete-side
  share acceptance + `CurrentSessionActor` resolution (H.1 Athlete step 3).
  This is the first slice that produces a runnable cross-device proof.
- **B4 — Cross-device Planning → Training → Reflection proof.** Run the
  exact "Minimal Real Alpha Connection" success test the task defines
  (PlannedActivity created by Parent → seen by Athlete → logged by Athlete
  → seen by Parent as the same `LoggedActivity` linked to the same
  `PlannedActivity`) using only B2/B3's already-built Family Shared Zone
  transport — Planning/Training carry no `visibility` field, so this first
  proof needs no Athlete Private Zone work at all. Extend to Reflection
  **only after** the Athlete Private Zone (Section D.2) exists and the
  `summaryOnly` derived-projection shape (Section K item 8) is explicitly
  confirmed by Product — do not fold Reflection into B4's first pass while
  those are still open.

This subdivision matches the task's suggested B1-B4 shape; the correction
pass changed *what belongs in* B2 and *what B4 requires as a prerequisite*,
not the four-slice sequence itself.

---

## M. Acceptance criteria — answered

- Whether native SwiftData CloudKit mirroring can be used: **for private
  single-user sync, yes; for the Parent↔Athlete sharing this task needs,
  no — verified platform gap (Section C).**
- Whether CloudKit Sharing works with the recommended store topology:
  **yes — `CKShare`/`CKRecordZone` sharing (Family Shared Zone) plus a
  separate private-database zone (Athlete Private Zone), both used
  directly via an explicit transport layer outside SwiftData, is the
  standard Apple-native mechanism for exactly this (Section D/E).**
- What must happen to `@Attribute(.unique)`: **nothing — it is never
  exposed to a CloudKit-mirrored `ModelConfiguration` under the
  recommended architecture (Section E).**
- Where `FamilyWorkspace` and canonical development entities live: **one
  local SwiftData store per device (unchanged), mirrored to one
  `FamilyWorkspace`-rooted Family Shared Zone for the Family-Shared subset,
  per DDM-006 (Section 0/B/E).**
- Which entities remain local/private: **Section B's full matrix —
  Calendar-domain entities, `Sport` reference data, app diagnostics, and
  the Parent's own local account-binding data (not the whole
  `ParentProfile`, per Section 0's correction).**
- How existing local data migrates: **Section F — additive one-time
  backfill into the newly-created Family Shared Zone (and, later, the
  Athlete Private Zone for Reflection content), keyed by existing IDs, no
  reset.**
- How AthleteApp resolves its own `WorkspaceParticipant` after share
  acceptance: **Section H.2 — a `CKUserIdentity.userRecordID`-keyed mapping
  field on the already-shared `WorkspaceParticipant` row, compared against
  the accepting device's own `CKContainer.userRecordID`.**
- How stable IDs survive: **by construction — `CKRecord.recordName =
  id.uuidString` for every Family-Shared-Zone entity (Section D "identity
  impact").**
- What conflict semantics remain open: **Section G/K — `PlannedActivity`/
  `WeekPlan` conflict rules are now canonical (Section 0) with only
  implementation work remaining; `LoggedActivity` same-record conflict and
  the Reflection duplicate-guard confirmation remain genuinely open.**
- Exact entitlements/project changes future implementation requires:
  **Section I.**
- The smallest next production implementation slice: **Section L, B1.**

---

## N. Confirmation

No production CloudKit sharing, CKShare creation, Athlete UI, pairing UI,
custom backend, or signing/entitlements change was implemented as part of
this discovery or this correction pass. This document and its companion
pull request description are the complete deliverable.
