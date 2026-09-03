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
  comment already names the two decisions blocking a real implementation —
  approved domain entities to build record types for, and "a resolved
  zone-sharing model (single shared zone vs. split Performance/Sensitive
  zones — flagged as a Critical item in the Architecture Review and still
  unresolved by any of the six governing documents)." This document does
  not have access to those six governing documents (they are not in this
  repository) and cannot resolve that citation directly — see Section P
  ("open risks") for how this discovery's own zone recommendation relates
  to it.
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
  root and family collaboration boundary."* This confirms the task's
  leading hypothesis (`FamilyWorkspace` as the CKShare root) is already
  documented product/architecture intent in the source, not something
  this discovery invents.
- Optimistic concurrency (`revision: Int` + `expectedRevision:` guarded
  mutation, throwing a `staleRevision` conflict error) already exists on
  **`AthleteProfile`** (`applyMutation`) and **`WeekPlan`** (`commit`/
  `reopen`). It does **not** exist on `PlannedActivity`, `LoggedActivity`,
  or any Reflection-family entity — relevant to Section G (conflict
  semantics).
- `VisibilityPolicy` (`.privateToAthlete`, `.sharedWithGuardians`, and
  others) is a **per-record, user-chosen** field on `ActivityReflection`,
  `DailyStatus`, `WeeklyReflection`, `MonthlyReflection`. `PlannedActivity`
  and `LoggedActivity` carry **no** visibility field at all — Planning and
  Training data has no concept of "private," only Reflection-family data
  does. This matters directly for Section D/G.

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
  H can run — see Section N.

---

## B. Entity placement matrix

All 25 types currently registered in `AppSchema.modelTypes`
(`Sources/VoxtrAppShell/AppSchema.swift`). Unregistered scaffold types that
exist in source but are never persisted today (`TrainingAttachment`,
`PlanningDecision`, `MonthlyReflection`, `AthleteSportParticipation`,
`ActivityCategory`, and the three `VoxtrSettings` types) are listed at the
end for completeness but are **out of scope for classification** — nothing
persists them yet, so there is nothing to place.

| Entity | Canonical owner | Parent device needs | Athlete device needs | Placement | Reason |
|---|---|---|---|---|---|
| `FamilyWorkspace` | Parent (workspace owner) | read/write | read | **Shared (root)** | The CKShare root record itself — see Section D. |
| `ParentProfile` | Parent | read/write | — | **Local/private** (Parent device only) | Athlete never needs the Parent's own profile row to operate; not part of the operational development graph. |
| `WorkspaceParticipant` | FamilyWorkspace | read/write (creates/manages) | read (own row), read (others, for roster) | **Shared** | The Athlete device must see its own invited/active participant row after accepting the share (see Section F) — this is the entity Foundation A already built for exactly this purpose. |
| `AthleteProfile` | FamilyWorkspace | read/write | read/write (name/settings, subject to product permission rules — not designed here) | **Shared** | The literal object Athlete Connection exists to give both actors access to ("connecting AthleteApp adds an actor to an existing AthleteProfile"). |
| `AthleteAccessGrant` | Parent (workspace owner) | read/write | not applicable | **Shared** (small, low-risk) or **Parent-local** | Grant fields are Parent-authored permission state about the workspace owner's own access; Athlete devices have no current read path for it. Recommend **Parent-local for the first implementation slice** (Section H) — nothing in Foundation A/B requires it to be visible to AthleteApp, and CLAUDE.md/this task both bar redesigning `AthleteAccessGrant` semantics. Revisit only if a later slice needs it. |
| `WeekPlan` | Planning | read/write | read (write once Athlete-authored planning is approved — out of scope now) | **Shared** | Core "Planning proposes" development history. |
| `PlannedActivity` | Planning | read/write | read/write (log against it) | **Shared** | Core development history; no visibility field — safe to share unconditionally. |
| `PlanningDecision` | Planning | n/a (not yet persisted) | n/a | Not applicable | Unregistered scaffold type — nothing creates it. |
| `LoggedActivity` | Training | read | read/write (this is the primary Athlete write path) | **Shared** | Core "Training proves" development history; no visibility field. `loggedByActorId` (Foundation A) already carries cross-device-safe provenance — see Section F/G. |
| `ActivityLoad` | Training (derived) | read | read | **Shared** | Derived-but-stored from `LoggedActivity`; same sharing boundary as its source record. Nothing currently computes/writes it (confirmed: no repository call site) — classify now for completeness, revisit when a real producer exists. |
| `TrainingAttachment` | Training | n/a (schema-only, no upload logic per its own doc comment) | n/a | Not applicable | Unregistered scaffold type; explicitly "must not receive upload logic" (v1.3 Section 19). |
| `ActivityReflection` | Reflection (Athlete's own voice) | read (subject to `visibility`) | read/write | **Shared, visibility-gated** | See Section D.1 — CloudKit zone sharing is zone-granularity, not per-record; a `.privateToAthlete` row must never be pushed to the Parent-readable zone at all. |
| `DailyStatus` | Reflection/Sleep | read (subject to `visibility`) | read/write | **Shared, visibility-gated** | Same constraint as `ActivityReflection`. |
| `WeeklyReflection` | Reflection | read (subject to `visibility`) | read/write | **Shared, visibility-gated** | Same constraint. |
| `MonthlyReflection` | Reflection | n/a (not yet persisted) | n/a | Not applicable | Unregistered scaffold type. |
| `ParentObservation` | Reflection (Parent's own voice) | read/write | read (subject to `visibility`; precondition already bars `.privateToAthlete` for this type) | **Shared, visibility-gated** | Symmetric case to `ActivityReflection` — Parent-authored, Athlete-readable subject to the same zone-granularity constraint. |
| `PlannedActivityDeletionTombstone` | Planning | read/write | read | **Shared** | Must propagate so a deletion doesn't "resurrect" on the other device — see Section G.5. |
| `RecurringPlannedActivity` | Planning | read/write | read | **Shared** | Definition-only; occurrences are derived at read time, not persisted separately. |
| `DailyStatus`/`AthleteSettings` — see `AthleteSettings` row below | | | | | |
| `AthleteSettings` | AthleteProfile (per-athlete product behavior) | read/write | read (write for athlete-controlled settings — not designed here) | **Shared** | Belongs with the `AthleteProfile` it configures; both actors already read/write different parts of the athlete's operational state today. |
| `Sport` | Core reference data | read | read | **Local, independently seeded** (not synced at all) | Deterministic, app-shipped reference catalog (`SportRepository` seeds it identically on every install) — nothing to sync; syncing it would only add risk for zero benefit. |
| `ActivityCategory` | Core reference data | n/a (not yet persisted) | n/a | Not applicable | Unregistered scaffold type. |
| `ActivityReminder` | Notifications (canonical intent) | read/write | read (write if Athlete-created activities gain reminders — not designed now) | **Shared** | Pure intent (`athleteId`, `plannedActivityId`, `leadTimeMinutes`, `reminderText`) — no device/delivery state on this type at all (confirmed by inspection: no notification identifier, no delivery flag). The **realization** (an actual `UNNotificationRequest`) is not a persisted entity anywhere in this codebase; each device schedules its own local notification from the synced canonical intent — this is not a new pattern, it is the same "derive locally from canonical shared truth" shape `TodayActivityComposer` already uses. |
| `CalendarPlanningMapping` | Calendar (legacy, Parent-only) | read (dead code path — see its own doc comment, "no live path creates new rows") | none | **Parent-local** | Superseded by `ExternalPlanningSource`/`CalendarImportDecision`; kept registered only so a pre-existing row stays readable for one-time migration. |
| `ExternalPlanningSource` | Calendar (Parent-only capability, explicit product rule) | read/write | none | **Parent-local** | Calendar import remains a Parent-only capability by explicit product contract restated in this very task — do not expose it to AthleteApp merely because the workspace is shared. |
| `CalendarImportDecision` | Calendar (Parent-only) | read/write | none | **Parent-local** | Same reasoning; `decidedBy` is documented as "never `.system`," always the real Parent `ActorId`. |
| `DecomposedActivityLink` | Calendar (Parent-only provenance) | read/write | none | **Parent-local** | Provenance of a Parent-approved calendar split; the resulting `PlannedActivity` rows (already Shared) are what the Athlete needs, not this bookkeeping. |
| `DecompositionEvidence` / `DecompositionEvidenceChild` | Calendar (Parent-only) | read/write | none | **Parent-local** | Same reasoning; durable evidence for future Suggested Split proposals, meaningless outside the Parent's own calendar-review flow. |
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
  `CalendarPlanningMapping`) stays off the shared zone completely. Only
  the **output** of Calendar import — an ordinary `PlannedActivity` row,
  already Shared — ever reaches the Athlete device. This matches the
  explicit product rule verbatim and required no invention.
- **Notifications: canonical intent is Shared, device realization never
  persists at all.** There is no persisted "scheduled notification" model
  to classify — the split the task asked to verify already exists
  structurally.
- **Reference data (`Sport`) does not need sync.** It is deterministic and
  identically seeded on every install; syncing it would add CloudKit
  record traffic and conflict surface for a catalog that is never
  supposed to differ between devices.

---

## C. SwiftData/CloudKit compatibility findings

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
triggered in practice. They are documented here because Options A and B
explicitly asked for an honest feasibility evaluation, and the honest answer
is that they are blocked, for reasons independent of each other:
`@Attribute(.unique)` blocks a CloudKit-mirrored *local* store even for
private, single-user sync; the complete absence of a SwiftData CKShare API
independently blocks the actual multi-user sharing requirement regardless of
`.unique`.

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
platform capability gap.

---

### Option B — separate local/private/shared persistence topology (as literally specified: three SwiftData-flavored stores)

**Purpose fit:** The *locality* thinking (some data local-only, some
private-synced, some shared) is correct and is what the recommendation
adopts. But "a shared CloudKit store" cannot be a third `ModelConfiguration`
on the same `ModelContainer` the way local + private-mirrored can, because
SwiftData has no shared-database configuration to hand it — see Section C.

**Requirements/consequences:** The private-mirroring tier (Parent's own
data synced across their own multiple devices) is real and available, but
is explicitly out of scope for Alpha's cross-device proof (Section H) and
would independently require dropping `@Attribute(.unique)` on whatever
subset of entities it covered.

**Risks:** Attempting to implement the "shared" tier as a SwiftData
`ModelConfiguration` would fail outright (no such CloudKit database scope
exists in the SwiftData API) — a team without this discovery's research
would likely lose real implementation time discovering this the hard way.

**Implementation shape:** N/A for the shared tier as literally specified.

**Recommendation status: viable fallback for the *local-only* half only** —
folded into the recommendation (Section E) as "local/private" placement,
without the unavailable shared-CloudKit-store third tier.

---

### Option C — explicit CloudKit transport/repository layer (canonical domain model unchanged)

**Purpose fit:** This is the only option that can satisfy genuine
cross-account (Parent ↔ Athlete) sharing on the approved Apple-native
direction, because it uses CloudKit's actual multi-user primitive
(`CKShare` + a shared `CKRecordZone`) directly, rather than routing through
a SwiftData feature that does not expose it.

**Requirements/consequences:**
- **Schema impact:** none. SwiftData's own schema/migration
  infrastructure is untouched; `cloudKitDatabase: .none` stays exactly as
  it is today, for the one local `ModelConfiguration`, unconditionally.
- **Migration impact:** additive only — see Section E.
- **Identity impact:** none, by construction — the transport layer maps
  each shared entity's existing `id: UUID` 1:1 to a `CKRecord.ID`
  (`recordName = id.uuidString`), inside a deterministically-named shared
  `CKRecordZone` scoped to the `FamilyWorkspace`. No identity is ever
  generated on the receiving device.
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
  reconcile. This project already has a proven, analogous pattern
  (`AthleteProfile.applyMutation`/`WeekPlan.commit`'s `expectedRevision` +
  `staleRevision` conflict error) that a CKRecord-mapping layer can extend
  to cross-device conflicts, rather than inventing new conflict semantics
  — see Section G for exactly which entities would need a `revision`
  field added to make this real.
- **Testability:** every existing repository/service call, and every
  existing `InMemoryPersistenceController`-based test, is completely
  unaffected — the transport layer is additive, sitting *outside* the
  domain/repository boundary, calling the same public repository methods
  any other caller (e.g. Calendar import) already calls.
- **Maintenance cost:** real, and should not be understated — this is
  hand-written CKRecord serialization/deserialization and sync-state
  bookkeeping for ~14 Shared entity types (Section B). `CKSyncEngine`
  (available since iOS 17) meaningfully reduces this cost versus hand-rolled
  `CKModifyRecordsOperation`/`CKFetchRecordZoneChangesOperation` — it owns
  push-notification wake-up, change-token bookkeeping, batching, and retry —
  but does not eliminate the record-mapping work itself, and has a
  documented rough edge (does not automatically re-fetch when a `CKShare`
  record itself changes without an app relaunch) worth planning around
  explicitly in the implementation slice that adopts it.
- **Future scalability:** does not fork Planning/Training/Reflection
  services by role, does not duplicate PlannedActivity/LoggedActivity per
  actor, and keeps CloudKit strictly as transport — matching the "CloudKit
  is transport/persistence infrastructure, it must not become a second
  business-rule owner" requirement directly.

**Risks:**
- Genuine hand-built sync complexity (see maintenance cost above).
- The per-record `VisibilityPolicy` vs. zone-granularity-sharing mismatch
  (Section D.1) is real, unsolved-by-the-platform, and must be designed
  deliberately rather than mechanically pushing every "Shared" entity into
  one zone.
- `CKSyncEngine`'s `CKShare`-change-notification gap is a concrete,
  named risk for whichever implementation slice handles share-state
  transitions (new participant accepted, permission changed, etc.).

**Implementation shape (high-level only, not designed further here):** one
`FamilyWorkspace`-rooted `CKRecordZone` per family, one `CKShare` on that
zone's root record, a small explicit `CloudKitFamilyWorkspaceSyncService` (or
similar) in `VoxtrAppShell` — the module already allowed to see every
domain — driving `CKSyncEngine`, translating between CKRecord and the
existing repositories' insert/update calls, keyed by each entity's own
`id: UUID`.

**Recommendation status: recommended.**

#### D.1 The per-record visibility vs. zone-granularity conflict (Reflection-family entities)

CloudKit sharing grants access at **zone** granularity: every record in a
shared `CKRecordZone` is visible (per the participant's role — read-only or
read-write) to every accepted participant on that zone's `CKShare`. It has
no concept of "this one record in the zone is visible to Participant A but
not Participant B." Vǫxtr's `VisibilityPolicy.privateToAthlete` on
`ActivityReflection`/`DailyStatus`/`WeeklyReflection` is a **per-record**
choice, so it cannot be represented by "which zone is this record in" alone
if all Reflection-family records shared the one Planning/Training zone.

Recommended handling (design-level, for the implementation slice that
actually builds Reflection sharing — **not built by this discovery**): the
transport layer checks a record's own `visibility` before ever pushing it to
the shared zone. A `.privateToAthlete` record is **never** pushed — it stays
in the Athlete's local SwiftData store only, exactly as it does today. Only
`.sharedWithGuardians` (or equivalent Parent-visible) records are pushed. A
later visibility change from private → shared triggers a first push at that
point; shared → private is a genuine open risk (Section P) because CloudKit
sync is not designed to "un-show" content a participant's device may have
already cached — this needs an explicit product decision, not a technical
guess.

Because this is a real, separate design problem, the recommended
implementation sequence (Section H) defers Reflection sharing to its own
slice, after Planning/Training sharing (which has no visibility field at
all, and is therefore unconditionally safe to share) is proven working
end-to-end.

---

### Option D — another architecture

No repository or Apple-platform evidence surfaced during this discovery that
points to a fundamentally different architecture than Option C. `CKSyncEngine`
is presented above as a refinement *within* Option C (a lower-maintenance way
to implement the same explicit-transport-layer shape), not a fourth option.

---

## E. Recommended architecture

**Option C**, refined as follows:

1. **SwiftData stays exactly as it is today** for every entity, Shared or
   Local: one `ModelContainer`, one local `ModelConfiguration`,
   `cloudKitDatabase: .none`, unchanged migration/versioning conventions,
   `@Attribute(.unique)` untouched everywhere. No schema rewrite.
2. A **new, explicit CloudKit sync layer** (owned by `VoxtrAppShell`, the
   one module already allowed to see every domain) uses `CKContainer` /
   `CKDatabase` (private database, shared-zone scope) / `CKShare` /
   `CKSyncEngine` to mirror the **Shared**-classified entities (Section B)
   between each device's own local SwiftData store and one
   `FamilyWorkspace`-rooted `CKRecordZone`, using each entity's existing
   `id: UUID` as the `CKRecord.ID.recordName`.
3. **Local/Parent-local**-classified entities (Section B) are never given a
   CKRecord at all — they remain exactly as invisible to CloudKit as they
   are today.
4. The domain/repository/service layer is completely unaware this sync
   layer exists — it calls the same `insert`/`fetch`/`update` methods any
   other caller (including today's Calendar import path) already calls.
   "CloudKit is transport, not a business-rule owner" is satisfied by
   construction, not by convention alone.

This satisfies the Decision Rule's eight criteria directly: One Truth and
stable IDs are structural (Section D "identity impact"); the same canonical
domain services are reused verbatim; there is no *invented* sync logic
beyond what `CKSyncEngine` already provides; migration is additive-only
(Section F); the architecture is explicitly offline-first (Section O); it is
the option repository evidence (`FamilyWorkspace`'s own doc comment) already
anticipated; and it is the only option that reaches a credible cross-device
Alpha proof at all, since Options A/B cannot reach one.

---

## F. Existing-data migration strategy

No silent reset, no regenerated IDs, no duplicate rows — for any of the five
categories the task named:

- **Existing Parent-only family:** unaffected until the Parent explicitly
  connects an Athlete (Section H, slice B3). No CKRecordZone or CKShare is
  created for a workspace that has never invited an Athlete participant —
  a Parent-only install stays 100% local, exactly as it is today, with zero
  behavior change.
- **Existing AthleteProfiles:** the moment a workspace's first Athlete
  participant is invited, the implementation slice that creates the
  `CKRecordZone`/`CKShare` performs a **one-time backfill**: every
  currently-local row already classified "Shared" (Section B) for that
  workspace is pushed up as a CKRecord keyed by its own existing `id`,
  never a new one. The local SwiftData store remains the on-device source
  of truth throughout — the shared zone is *populated from* it, not the
  other way around.
- **Current `WorkspaceParticipant`:** Foundation A's existing invite flow
  (`ParentWorkspaceRepository.createInvitedAthleteParticipant`) is
  unchanged; the CloudKit layer only adds *transport* for that already-real
  row once the share exists.
- **Historical `LoggedActivity` with `loggedByActorId == nil`:** migrates
  into the shared zone exactly like any other `LoggedActivity` row — the
  CKRecord simply carries the same `nil`/absent value. Nothing fabricates
  an actor at the CloudKit boundary; Foundation A's "nil means honestly
  unknown" contract is preserved end to end.
- **Calendar source mappings, reminders, local diagnostics:** per Section
  B, Calendar-domain entities and diagnostics are never pushed to the
  shared zone at all — "migration" for them is simply "no change." Reminders'
  canonical `ActivityReminder` intent rows follow the same one-time backfill
  as any other Shared entity; no device-local notification state exists to
  migrate (Section B.1).

---

## G. Conflict/concurrency findings

- **Different objects** (Parent plans one activity, Athlete logs another):
  converge naturally — two independently-created records with distinct
  stable IDs, no merge required.
- **Same `PlannedActivity` edited by Parent while Athlete logs it:** these
  are, in practice, two different records — logging creates a *new*
  `LoggedActivity` referencing the `PlannedActivity` by ID; `TrainingService`'s
  existing `plannedActivityAlreadyLinked` guard (an app-level invariant,
  unrelated to CloudKit) already prevents a double-link. A genuine
  same-record conflict only arises if the *same* `PlannedActivity` field is
  edited on two devices before either has synced the other's change — see
  next point.
- **True same-record conflict (e.g. two `PlannedActivity`/`LoggedActivity`
  edits before sync, or two `WeekPlan.commit` calls):** CloudKit's default
  is server-side record-change-tag detection (`.serverRecordChanged`), not
  automatic field-level merging — the app must resolve it. This project
  already has a proven mechanism for exactly this shape of problem
  (`AthleteProfile`/`WeekPlan`'s `revision`/`expectedRevision`/
  `staleRevision` pattern) that a future slice should extend to
  `PlannedActivity` and `LoggedActivity`, **neither of which currently has
  a `revision` field** — this is a real, named, not-yet-solved gap, not
  something this discovery resolves.
- **Reflection duplicate guard `(loggedActivityId, athleteId)`:** inspection
  suggests this is very likely still correct, not a defect Foundation B
  needs to fix — `ActivityReflection` already appears to be modeled as
  specifically the **Athlete's own voice** (its `authorId` is set from
  Reflection's existing "Athlete authors their own reflection" call paths),
  with the Parent's equivalent commentary already living on a **separate**
  entity, `ParentObservation`, which has no such duplicate guard at all. If
  that reading is correct, the existing guard does not need to change for
  shared/multi-actor use. This should be **explicitly confirmed by Product
  before any implementation slice touches Reflection sharing** (Section
  D.1 already defers that slice) — this discovery flags it, it does not
  decide it.
- **Deletes/tombstones:** `PlannedActivityDeletionTombstone` already exists
  and is classified Shared (Section B) specifically so a deletion
  propagates as a tombstone record, not a silent local-only removal — a
  device that synced the original `PlannedActivity` before the delete will
  see the tombstone and know not to resurrect it. Reversible actions
  (Reopen Activity, Reopen Planning) are ordinary field mutations on
  already-Shared entities and need no special sync handling beyond what
  Section G's conflict handling already covers.

---

## H. Athlete participant/session-resolution architecture

Foundation A already solved "which `WorkspaceParticipant` is acting in this
session" (`CurrentSessionActor`) — never solved "which physical device/
iCloud account maps to which specific `WorkspaceParticipant` row."

**Verified, publicly documented Apple APIs relevant to this mapping**
(not speculative pseudo-APIs):

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

### H.1 Concrete flow (design-level; UI and full plumbing are a later slice)

**Parent:**
1. `FamilyWorkspace`, `AthleteProfile` already exist (or are created).
2. Parent invites the Athlete via Foundation A's existing
   `ParentWorkspaceRepository.createInvitedAthleteParticipant` — an
   `.invited`-state `WorkspaceParticipant` with `linkedAthleteId` now
   exists, exactly as today.
3. The implementation slice creates (or reuses) the workspace's
   `CKRecordZone` and a `CKShare` rooted at the `FamilyWorkspace` record,
   if this is the family's first Athlete connection.
4. Parent resolves the Athlete's `CKUserIdentity` (via CloudKit's own
   participant-lookup APIs, driven by an out-of-band identifier the
   Athlete provides *only for lookup*, e.g. email/phone — never stored as
   Vǫxtr identity) and adds them as a `CKShare.Participant` with a role.
5. The share is distributed via `UICloudSharingController` (Messages/
   Mail/AirDrop/link) — an Apple-system-supported mechanism, not a custom
   transport.

**Athlete:**
1. Accepts the share (system share-sheet flow → `CKContainer.accept(_:)`).
2. The shared zone's records — including the invited
   `WorkspaceParticipant` row itself — sync down via `CKSyncEngine` into
   the Athlete device's own local SwiftData store, through the same
   repository insert paths any other sync write uses.
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
   `CKUserIdentity` as a participant (H.1 step 4), Vǫxtr records that
   resolved `userRecordID` as an ordinary synced field on the *same*
   `WorkspaceParticipant` row already being shared (a small additive field,
   not a schema redesign — the entity is already Shared). On the Athlete
   device, after accepting, `CKContainer.userRecordID` gives "who am I,"
   and the app selects the one now-locally-visible `WorkspaceParticipant`
   row whose recorded mapping value matches it.

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
this repository today.** The first implementation slice (Section H →
B1/B2) must add, for both `ParentApp` and `AthleteApp` targets: an iCloud
capability with CloudKit enabled, a shared CloudKit container identifier (a
project-configuration change, not a code change), a `.entitlements` file
per target, and `CKSharingSupported = true` in each target's `Info.plist`.
This discovery performed **read-only** inspection only, per its own
instruction to prefer that and avoid touching signing/provisioning/
entitlements even reversibly — no such changes were made.

---

## J. Technical experiments performed

**None were run as compile-time/runtime spikes in this repository.** Every
architecture question this discovery needed to answer (SwiftData's CKShare
support gap, the `@Attribute(.unique)`/CloudKit incompatibility, the
zone-granularity of CloudKit sharing) is settled, current (2026-dated),
cross-corroborated, publicly documented Apple platform behavior — not
something a local compile-only spike in this sandbox (no Swift toolchain
available in this environment, consistent with every prior task on this
branch) could verify more reliably than the sourced documentation already
does. Per the task's own instruction to use spikes only "when repository
inspection cannot answer a concrete question," none of the open questions
met that bar. What *was* done instead: full repository-only inspection
(Section A) plus targeted web verification of Apple framework behavior
(Section C/H), explicitly separated from each other throughout this
document so a reader can tell which claims are repository-verified and
which are platform-verified.

---

## K. Open risks / decisions requiring Product Owner or Architecture input

1. **The "six governing documents" / Critical zone-sharing item** cited by
   `SyncProviding.swift`'s own doc comment is not accessible from this
   repository. This discovery's zone recommendation (Section D/E: one zone
   per `FamilyWorkspace`, with Reflection-family records conditionally
   included per `visibility`, Section D.1) should be checked against
   whatever that citation actually says before implementation begins.
2. **Reflection visibility change from shared → private after a record has
   already synced to the Parent's device** (Section D.1) — CloudKit cannot
   "unshow" already-cached content. Needs an explicit product decision on
   acceptable behavior, not a technical guess.
3. **Whether `AthleteAccessGrant` should ever become Athlete-visible** —
   this discovery recommends keeping it Parent-local for the first slice
   (Section B) specifically to avoid touching `AthleteAccessGrant`
   semantics, which is out of scope per this task's own explicit
   constraint.
4. **The Reflection duplicate-guard question** (Section G) — this
   discovery's reading (the existing `(loggedActivityId, athleteId)` guard
   is likely still correct because `ParentObservation` already carries the
   Parent's side) should be explicitly confirmed, not assumed, before a
   Reflection-sharing implementation slice begins.
5. **`PlannedActivity`/`LoggedActivity` gaining a `revision` field** for
   real cross-device optimistic concurrency (Section G) is a genuine
   design decision (what does a conflict banner look like? does Training
   ever need last-write-wins instead?) with product/UX consequences beyond
   this discovery's scope.
6. **The Athlete-lookup UX at invite time** (Section H.2) — how a Parent
   supplies an out-of-band identifier to resolve the Athlete's
   `CKUserIdentity` — is a real product/UX design question, not solved
   here.

---

## L. Recommended next implementation slices, in order

- **B1 — Persistence/entitlement foundation.** Add iCloud/CloudKit
  capability + entitlements + `CKSharingSupported` to both app targets
  (Section I); introduce the explicit CloudKit sync layer's skeleton
  (`CKContainer`/`CKDatabase` access, `CKSyncEngine` wiring) with **no**
  entity mapping wired up yet — provable independently via a Parent-only
  device successfully creating an (empty) `CKRecordZone` for its
  `FamilyWorkspace`.
- **B2 — FamilyWorkspace sharing transport.** Implement the `CKShare`
  creation/distribution flow (Section H.1 Parent steps 3-5) and the
  Athlete acceptance flow (H.1 Athlete step 1-2) for the Planning/Training
  Shared entities ONLY (Section B — the entities with no `visibility`
  field, therefore no Section D.1 problem to solve yet): `FamilyWorkspace`,
  `WorkspaceParticipant`, `AthleteProfile`, `AthleteSettings`, `WeekPlan`,
  `PlannedActivity`, `PlannedActivityDeletionTombstone`,
  `RecurringPlannedActivity`, `LoggedActivity`, `ActivityLoad`,
  `ActivityReminder`. Implement the H.2 durable-mapping mechanism here.
- **B3 — Minimal Parent connect + Athlete accept/session resolution.**
  Build the actual (currently out-of-scope-until-now) Athlete
  Connection UI: Parent-side "connect this athlete" action, Athlete-side
  share acceptance + `CurrentSessionActor` resolution (H.1 Athlete step 3).
  This is the first slice that produces a runnable cross-device proof.
- **B4 — Cross-device Planning → Training → Reflection proof.** Run the
  exact "Minimal Real Alpha Connection" success test the task defines
  (PlannedActivity created by Parent → seen by Athlete → logged by Athlete
  → seen by Parent as the same `LoggedActivity` linked to the same
  `PlannedActivity`), extended to Reflection **only after** Section D.1's
  visibility-gating design is worked out and explicitly confirmed (Section
  K item 2/4) — do not fold Reflection into B4's first pass if that
  design question is still open.

This subdivision matches the task's suggested B1-B4 shape; no repository
evidence surfaced during this discovery that argues for a different
sequence.

---

## M. Acceptance criteria — answered

- Whether native SwiftData CloudKit mirroring can be used: **for private
  single-user sync, yes; for the Parent↔Athlete sharing this task needs,
  no — verified platform gap (Section C).**
- Whether CloudKit Sharing works with the recommended store topology:
  **yes — `CKShare`/`CKRecordZone` sharing, used directly via an explicit
  transport layer outside SwiftData, is the standard Apple-native
  mechanism for exactly this (Section D/E).**
- What must happen to `@Attribute(.unique)`: **nothing — it is never
  exposed to a CloudKit-mirrored `ModelConfiguration` under the
  recommended architecture (Section E).**
- Where `FamilyWorkspace` and canonical development entities live: **one
  local SwiftData store per device (unchanged), mirrored to one
  `FamilyWorkspace`-rooted shared `CKRecordZone` for the Shared subset
  (Section B/E).**
- Which entities remain local/private: **Section B's full matrix — Parent
  profile, all Calendar-domain entities, `Sport` reference data, app
  diagnostics.**
- How existing local data migrates: **Section F — additive one-time
  backfill into a newly-created shared zone, keyed by existing IDs, no
  reset.**
- How AthleteApp resolves its own `WorkspaceParticipant` after share
  acceptance: **Section H.2 — a `CKUserIdentity.userRecordID`-keyed mapping
  field on the already-shared `WorkspaceParticipant` row, compared against
  the accepting device's own `CKContainer.userRecordID`.**
- How stable IDs survive: **by construction — `CKRecord.recordName =
  id.uuidString` for every Shared entity (Section D "identity impact").**
- What conflict semantics remain open: **Section G/K — `PlannedActivity`/
  `LoggedActivity` have no `revision` field yet; the Reflection duplicate
  guard needs explicit product confirmation, not just this discovery's
  reading of it.**
- Exact entitlements/project changes future implementation requires:
  **Section I.**
- The smallest next production implementation slice: **Section L, B1.**

---

## N. Confirmation

No production CloudKit sharing, CKShare creation, Athlete UI, pairing UI,
custom backend, or signing/entitlements change was implemented as part of
this discovery. This document and its companion pull request description
are the complete deliverable.
