import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrCoreReferenceData

/// CRITICAL PERSISTENCE RECOVERY (see this work's own root-cause
/// writeup for the full investigation): this file previously declared
/// six historical `VersionedSchema` versions (`AppSchemaV1` through
/// `AppSchemaV6`), five of them frozen to reflect earlier field-level
/// shapes of `AthleteProfile`/`WorkspaceParticipant` via separately-
/// declared "legacy" types in `LegacySchemaTypes.swift` (now deleted).
/// That approach caused a real, launch-blocking `NSLightweightMigrationStage`
/// crash, was patched, then caused a `SwiftDataError` on existing-store
/// startup, was patched again, and then coincided with a *fresh install*
/// failing during onboarding — a failure mode that cannot be explained
/// by anything migration-stage-related at all, since a fresh install
/// never migrates. That sequence — four consecutive fixes to the same
/// mechanism, each one surfacing a new failure — is itself evidence
/// that having two Swift types (a live one and a "legacy" one) both
/// declare the same persisted SwiftData entity name in the same
/// compiled binary is not the safe, well-supported pattern it was
/// assumed to be when introduced; that assumption was never verified
/// against a real compiler or SwiftData runtime, only reasoned about.
///
/// Given there was no production user data to preserve at the time —
/// this app has never left TestFlight — the fix was to collapse the
/// entire schema history to ONE current, live version
/// (`AppCurrentSchema`, "1.0.0"), with an EMPTY migration-stage list.
/// `AppCurrentSchema.models` was, at that point, a LIVE passthrough to
/// `AppSchema.modelTypes` — safe only because nothing had yet changed
/// `AppSchema.modelTypes` since that collapse.
///
/// VX-023 (Sleep V1) review follow-up — genuine V2 bump: adding
/// `DailyStatus`/`AthleteSettings` to `AppSchema.modelTypes` is exactly
/// the case this file's own "HOW TO ADD A NEW VERSION" instructions
/// (below) were written for, and an earlier round of this same feature
/// incorrectly treated a live-passthrough `AppCurrentSchema.models` as a
/// safe way to skip that recipe. It is not: `AppCurrentSchema`'s
/// `versionIdentifier` ("1.0.0") is a fixed, on-disk-persisted identity.
/// An existing TestFlight store, saved under "1.0.0" back when
/// `AppCurrentSchema.models` had 15 entities, would have been reopened
/// on the NEXT launch by a `ModelContainer` whose `Schema(versionedSchema:
/// AppCurrentSchema.self)` NOW carried 17 entities under that SAME
/// "1.0.0" identity — a real version-identity/shape mismatch that this
/// project's own migration-plan machinery (`ModelContainer(for:
/// migrationPlan:)`) never got a chance to reason about, since nothing
/// told it the shape had changed. Whether SwiftData would have handled
/// that silently, thrown, or done something worse was never verified
/// against a real device/compiler — exactly the kind of unverified
/// assumption this file's own history above already warns against
/// repeating.
///
/// The fix: `AppCurrentSchema.models` is now FROZEN to a hardcoded
/// literal — the exact 15 entities it already had on every TestFlight
/// build before VX-023 — so its "1.0.0" identity now means the same
/// fixed shape forever, on disk and in source, matching what any
/// existing store already has. `AppSchemaV2` ("2.0.0") is the new
/// current version, a live passthrough to `AppSchema.modelTypes` (17
/// entities). `AppSchemaMigrationPlan.stages` now carries a genuine
/// `.lightweight` V1→V2 stage — the class of migration Apple's own
/// SwiftData migration guidance documents as covering exactly this
/// shape of change (new model types added, no existing entity/property
/// renamed, removed, or changed in place). A fresh install skips the
/// stage entirely and is created directly under V2. An existing store
/// still on V1 is migrated forward automatically the next time it's
/// opened, with its existing 15 entities' data completely untouched (a
/// `.lightweight` migration synthesizes the new tables; it does not
/// rewrite existing ones) — see `PersistenceRecoveryTests.existingV1StoreMigratesToV2Successfully`
/// for this migration exercised for real, end to end, against an actual
/// on-disk store.
public enum AppCurrentSchema: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    /// FROZEN — do not change. This is the exact 15-entity shape every
    /// TestFlight build before VX-023 (Sleep V1) shipped under version
    /// "1.0.0". `AppSchema.modelTypes` has since grown to 17 entities;
    /// that growth lives in `AppSchemaV2` below, never here. Changing
    /// this list would silently redefine what an already-persisted
    /// on-disk "1.0.0" store is assumed to contain — exactly the mistake
    /// this file's own doc comment above documents fixing.
    public static var models: [any PersistentModel.Type] {
        [
            AppDiagnosticsRecord.self,
            AthleteProfile.self,
            ParentProfile.self,
            FamilyWorkspace.self,
            WorkspaceParticipant.self,
            AthleteAccessGrant.self,
            WeekPlan.self,
            PlannedActivity.self,
            LoggedActivity.self,
            ActivityLoad.self,
            ActivityReflection.self,
            ParentObservation.self,
            PlannedActivityDeletionTombstone.self,
            WeeklyReflection.self,
            RecurringPlannedActivity.self,
        ]
    }
}

/// VX-023 (Sleep V1) review follow-up: was the live-passthrough current
/// version; now FROZEN following this file's own "HOW TO ADD A NEW
/// VERSION" recipe below, since `AppSchemaV3` (Design Foundation V0.1
/// Athlete Color round) is now the latest. `models` is the exact
/// 17-entity shape every build shipped under "2.0.0" before that round.
///
/// CODEMAGIC FIX (Athlete Color round follow-up) — root cause of
/// "Duplicate version checksums detected.": freezing `models` to a
/// hardcoded literal ARRAY (as done here and for `AppCurrentSchema`)
/// only freezes WHICH TYPES are listed — it does NOT freeze the
/// per-type field SHAPE of a type that is still referenced by its
/// live, current declaration. `AthleteSettings.self` below used to
/// mean the same thing here as in `AppSchemaV3.self`, but the Athlete
/// Color round added `AthleteSettings.preferredColor` to the ONE, live
/// `VoxtrAthleteDomain.AthleteSettings` class — so V2's `models` and
/// V3's `models` ended up pointing at the literal SAME compiled type,
/// including the field V2 must NOT have. SwiftData computes each
/// `VersionedSchema`'s checksum from its entities' actual persisted
/// shape, not from the array literal or the `versionIdentifier`
/// string — so V2 and V3 hashed identically, and `ModelContainer`
/// throws validating the shared `AppSchemaMigrationPlan` (surfacing
/// inside whichever test/call site constructs a container against it
/// first — `existingV1StoreMigratesToV2Successfully` in Codemagic,
/// even though the actual mismatch is V2-vs-V3, not V1-vs-V2).
///
/// Fix: `AthleteSettings` below is this enum's OWN nested, frozen copy
/// — the genuine V2-era shape, WITHOUT `preferredColor` — following
/// SwiftData's own documented `VersionedSchema` convention (Apple's
/// migration guidance nests a frozen model type per version inside
/// that version's own `VersionedSchema` enum; SwiftData matches it to
/// later versions' same-named entity for migration purposes by its
/// unqualified type name, not by Swift-level identity). This is
/// deliberately narrow, unlike this file's own deleted
/// `LegacySchemaTypes.swift` history (five fully-duplicated legacy
/// entities across six versions, top-level and not namespaced under
/// their own version): exactly ONE entity is frozen here, because
/// `AthleteSettings` is the ONLY entity whose actual field shape
/// diverges between V2 and V3, it is nested inside this enum (not a
/// separate top-level file/type), and it is referenced ONLY from this
/// `models` array — never by `AppSchema.modelTypes` (the live app's
/// own current schema), any repository, service, or UI. Every other
/// entity below is still the same live top-level type V1/V3 also use,
/// unchanged, since none of them diverge in shape.
public enum AppSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(2, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        [
            AppDiagnosticsRecord.self,
            AthleteProfile.self,
            ParentProfile.self,
            FamilyWorkspace.self,
            WorkspaceParticipant.self,
            AthleteAccessGrant.self,
            WeekPlan.self,
            PlannedActivity.self,
            LoggedActivity.self,
            ActivityLoad.self,
            ActivityReflection.self,
            ParentObservation.self,
            PlannedActivityDeletionTombstone.self,
            WeeklyReflection.self,
            RecurringPlannedActivity.self,
            DailyStatus.self,
            AthleteSettings.self,
        ]
    }

    /// FROZEN — the genuine V2-era shape of `AthleteSettings`, the
    /// exact field list Sleep V1 shipped with, before the Athlete
    /// Color round added `preferredColor` to the live type in
    /// `VoxtrAthleteDomain`. Do not add `preferredColor` (or any other
    /// field the live type gains later) here — doing so would
    /// silently recreate this exact checksum collision. This type
    /// exists ONLY to give `AppSchemaV2.models` above an accurate
    /// historical shape for migration purposes; nothing in this
    /// codebase's live repositories/services/UI may construct or read
    /// it — see `AthleteRepository`/`SleepCoordinationService` for the
    /// real, live, current `AthleteSettings`.
    @Model
    public final class AthleteSettings {
        @Attribute(.unique) public var id: UUID
        public var athleteId: UUID
        public var weekStartsOn: Int
        public var defaultReflectionVisibility: VisibilityPolicy
        public var preferredUnits: String
        public var morningBriefEnabled: Bool
        public var eveningCheckOutEnabled: Bool
        public var weeklyReviewDay: Int
        public var weeklyReviewLocalTime: LocalTime?
        public var sleepTrackingEnabled: Bool
        public var createdAt: Date
        public var updatedAt: Date
        public var schemaVersion: Int

        public init(
            id: UUID = UUID(),
            athleteId: UUID,
            weekStartsOn: Int = Weekday.monday.rawValue,
            defaultReflectionVisibility: VisibilityPolicy = .sharedWithGuardians,
            preferredUnits: String = "metric",
            morningBriefEnabled: Bool = false,
            eveningCheckOutEnabled: Bool = false,
            weeklyReviewDay: Int = Weekday.sunday.rawValue,
            weeklyReviewLocalTime: LocalTime? = nil,
            sleepTrackingEnabled: Bool = true,
            createdAt: Date = .now,
            updatedAt: Date = .now,
            schemaVersion: Int = 1
        ) {
            self.id = id
            self.athleteId = athleteId
            self.weekStartsOn = weekStartsOn
            self.defaultReflectionVisibility = defaultReflectionVisibility
            self.preferredUnits = preferredUnits
            self.morningBriefEnabled = morningBriefEnabled
            self.eveningCheckOutEnabled = eveningCheckOutEnabled
            self.weeklyReviewDay = weeklyReviewDay
            self.weeklyReviewLocalTime = weeklyReviewLocalTime
            self.sleepTrackingEnabled = sleepTrackingEnabled
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.schemaVersion = schemaVersion
        }
    }
}

/// Design Foundation V0.1 (Athlete Color canonical preference round):
/// the current, live version. `AthleteSettings` gains one new OPTIONAL
/// property (`preferredColor: AthleteColor?`) — no model *type* is
/// added or removed, so `AppSchema.modelTypes` itself is unchanged (see
/// that file's own "HOW TO ADD" step 3); this is purely the field-level
/// case step 4 describes, and `.lightweight` is exactly what Apple's own
/// SwiftData migration guidance documents as covering "new optional
/// properties with inferable defaults" — `nil` is the only value an
/// existing row's new column can mean, with nothing to transform.
/// `models` was a live passthrough to `AppSchema.modelTypes` while V3
/// was the latest version; now FROZEN (Sport / Activity Identity domain
/// foundation round) to the exact 17-entity shape it shipped with, since
/// `AppSchemaV4` below is now latest — same freezing rationale as
/// `AppCurrentSchema`/`AppSchemaV2` above. No entity here diverges in
/// field shape from its live top-level declaration (the title-optional
/// and `ActivityType` raw-value changes landed directly on the live
/// `PlannedActivity`/`LoggedActivity`/`RecurringPlannedActivity` types
/// with no version-specific nested copy — see `AppSchemaV4`'s own doc
/// comment for why), so freezing the type LIST here is sufficient; no
/// nested legacy copy is needed for this version.
public enum AppSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(3, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        [
            AppDiagnosticsRecord.self,
            AthleteProfile.self,
            ParentProfile.self,
            FamilyWorkspace.self,
            WorkspaceParticipant.self,
            AthleteAccessGrant.self,
            WeekPlan.self,
            PlannedActivity.self,
            LoggedActivity.self,
            ActivityLoad.self,
            ActivityReflection.self,
            ParentObservation.self,
            PlannedActivityDeletionTombstone.self,
            WeeklyReflection.self,
            RecurringPlannedActivity.self,
            DailyStatus.self,
            AthleteSettings.self,
        ]
    }
}

/// Sport / Activity Identity domain foundation: the current, live
/// version. Adds ONE model type, `Sport.self` (`VoxtrCoreReferenceData`)
/// — the type already existed (used by every `SportId?` field already on
/// `PlannedActivity`/`LoggedActivity`/`RecurringPlannedActivity`/
/// `DevelopmentGoal`) but was never itself registered/persisted before
/// this round; registering it is a genuine model-type addition per this
/// file's own "HOW TO ADD" step 3.
///
/// This same version also bundles two field-level changes to
/// already-listed live types:
///   - `PlannedActivity.title` / `LoggedActivity.title` /
///     `RecurringPlannedActivity.title`: `String` → `String?`
///     (Activity Name becomes optional; see `ActivityIdentity.swift`).
///   - `ActivityType`: `physicalTraining` retained as legacy case for backward
///     compatibility; `strength` + `conditioning` added.
///
/// Per step 4's own instruction to "seriously consider whether the
/// disproportionate complexity... [of frozen legacy copies]... [is]
/// worth it for whatever data is actually at stake": there is still no
/// production data at stake (this app has never left TestFlight/Internal
/// Alpha), and this exact codebase already has a directly-precedented,
/// already-accepted answer for that situation —
/// `RecurringPlannedActivity.weekdays`'s own shape change (`Weekday` →
/// `[Weekday]`) shipped with NO frozen legacy copy, only a documented
/// "existing installs may need a reinstall/store reset" Internal Alpha
/// note. The title-optionality and `ActivityType` changes follow that
/// same precedent here, for the same reason: building three fully
/// duplicated nested legacy entity copies (`PlannedActivity`,
/// `LoggedActivity`, `RecurringPlannedActivity`) to preserve field shapes
/// nobody's real data depends on would reintroduce exactly the
/// "disproportionate complexity" this file's own history (the deleted
/// six-version `LegacySchemaTypes.swift` saga) already burned real launch
/// failures to learn from — see `ActivityType`'s own doc comment in
/// `SharedEnums.swift` for the equivalent, explicit "Internal Alpha
/// limitation, reinstall required" note for that change specifically.
/// `.lightweight` is still the correct stage kind: SwiftData's own
/// migration guidance covers "new optional properties" (the title
/// changes) the same way regardless of whether the OLD shape is
/// separately frozen — a `.lightweight` stage does not require a source
/// type to exist for a property that is simply becoming optional on the
/// SAME live type; there is no separate V3-shaped `PlannedActivity` for
/// it to migrate FROM in the first place; the `ActivityType` raw-value
/// change carries the same accepted Internal Alpha risk described above
/// regardless of migration-stage kind.
///
/// `models` stays a live passthrough to `AppSchema.modelTypes` (this is
/// now the LATEST version); it will need freezing itself the next time a
/// genuine `AppSchemaV5` is added.
public enum AppSchemaV4: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(4, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        AppSchema.modelTypes
    }
}

/// HOW TO ADD A NEW VERSION (read this before adding, renaming, or
/// removing any `@Model` property or type in `AppSchema.modelTypes`
/// from this point forward):
///
/// 1. Freeze the CURRENT latest version's `models` (right now, that's
///    `AppSchemaV4`) to a hardcoded literal array — copy its current
///    passthrough result before changing anything, the same way
///    `AppSchemaV3` was frozen when `AppSchemaV4` was introduced (see
///    that enum's own doc comment for a worked example).
/// 2. Add a new `AppSchemaV5: VersionedSchema` enum in this file, with
///    `versionIdentifier: Schema.Version(5, 0, 0)` and `models`
///    passthrough to `AppSchema.modelTypes` (V5 becomes the new latest,
///    and `CompositionRoot.build`'s default `persistence:` parameter
///    must be updated to target it — see that type's own doc comment
///    for why this exact step was missed for years across V1-V6 before
///    this file's own simplification, and do not repeat that mistake).
/// 3. Update `AppSchema.modelTypes` — only if a model *type* is
///    actually being added/removed. A field-level change to an
///    already-listed type does not touch this array at all (the
///    `AthleteSettings.preferredColor` addition that produced
///    `AppSchemaV3` is exactly this case — see its own doc comment).
/// 4. If the change is field-level on an already-listed type (not a
///    whole type addition/removal): before repeating the
///    "separately-declared legacy type" pattern this file's own
///    history warns against, seriously consider whether the
///    disproportionate complexity and repeated failures documented
///    above are worth it for whatever data is actually at stake. If
///    there IS real user data to preserve by the time this matters,
///    that pattern may still be the only SwiftData-supported way to do
///    it — but verify it against an actual compiler and device before
///    trusting it again, not just reasoning from source code.
/// 5. Add `AppSchemaV5.self` to `schemas` below, alongside every prior
///    version (old versions are never removed, only appended to).
/// 6. Add a real `MigrationStage` to `stages` describing the V4 → V5
///    transition — `.lightweight` if the change is purely additive
///    (new type(s), new optional propert(y/ies)), `.custom` if it needs
///    real data transformation.
/// 7. Do not skip version numbers — each actually-shipped schema
///    change gets its own version and its own stage, in order.
///
/// IMPORTANT — a model *type addition* is NOT an exemption from this
/// recipe, even under "no production data at stake" reasoning: an
/// EXISTING TestFlight install already has a store persisted under the
/// prior version's fixed identity, and that identity must keep meaning
/// the same fixed shape it always has, or that install's next launch
/// becomes unverified behavior. "No production data to preserve"
/// justifies choosing `.lightweight` migration (rather than a more
/// complex, data-preserving custom stage) over an actually-broken
/// store — it does not justify skipping the version bump itself.
public enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [AppCurrentSchema.self, AppSchemaV2.self, AppSchemaV3.self, AppSchemaV4.self]
    }

    /// V1 ("1.0.0", 15 entities) → V2 ("2.0.0", 17 entities — adds
    /// `DailyStatus`/`AthleteSettings`). `.lightweight`: no existing
    /// entity or property is renamed, removed, or changed in place —
    /// this is purely additive, exactly the class of change Apple's own
    /// SwiftData migration guidance documents `.lightweight` as
    /// covering (new model types, new optional properties with
    /// inferable defaults). A custom stage with explicit
    /// `willMigrate`/`didMigrate` closures is unnecessary here since
    /// there is no data to transform — the new tables start empty.
    ///
    /// V2 ("2.0.0", 17 entities) → V3 ("3.0.0", same 17 entities — adds
    /// `AthleteSettings.preferredColor: AthleteColor?`). `.lightweight`
    /// again: no entity is added/removed and no existing property is
    /// renamed/removed/retyped — a genuinely new, genuinely optional
    /// column with no other value it could infer for an existing row
    /// than `nil`, which is exactly what a `nil`-valued
    /// `preferredColor` already means at the application layer ("no
    /// explicit choice yet, use the stable AthleteId-derived fallback"
    /// — see `AthleteSettings.preferredColor`'s own doc comment). Every
    /// existing athlete's existing `AthleteSettings` row (if any) — and
    /// every athlete with no row at all — is completely unaffected by
    /// this migration; there is nothing to transform.
    /// V3 ("3.0.0", 17 entities) → V4 ("4.0.0", 18 entities — adds
    /// `Sport.self`; also carries the title-optionality and
    /// `ActivityType` raw-value changes described on `AppSchemaV4`'s own
    /// doc comment). `.lightweight`: the only structural change SwiftData
    /// itself needs to reason about here is the new `Sport` entity/table,
    /// which is purely additive — same class of change as V1→V2's
    /// `DailyStatus`/`AthleteSettings` addition above. A fresh install
    /// starts directly under V4 (`Sport` seeded empty, then populated by
    /// `SportRepository.seedCanonicalSportsIfNeeded()` at first launch);
    /// an existing V3 store gains the new empty `Sport` table with its
    /// existing 17 entities' data completely untouched.
    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: AppCurrentSchema.self, toVersion: AppSchemaV2.self),
            .lightweight(fromVersion: AppSchemaV2.self, toVersion: AppSchemaV3.self),
            .lightweight(fromVersion: AppSchemaV3.self, toVersion: AppSchemaV4.self),
        ]
    }
}
