import Foundation
import SwiftData
import VoxtrCore
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

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

/// VX-023 (Sleep V1) review follow-up: the current, live version — see
/// `AppCurrentSchema`'s own doc comment for the full reasoning. `models`
/// stays a live passthrough to `AppSchema.modelTypes` (this is now the
/// LATEST version, so nothing downstream needs it frozen yet); it will
/// need freezing itself, the same way `AppCurrentSchema` just was,
/// the next time a genuine `AppSchemaV3` is added.
public enum AppSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(2, 0, 0)
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
///    `AppSchemaV2`) to a hardcoded literal array — copy its current
///    passthrough result before changing anything, the same way
///    `AppCurrentSchema` was frozen when `AppSchemaV2` was introduced.
/// 2. Add a new `AppSchemaV3: VersionedSchema` enum in this file, with
///    `versionIdentifier: Schema.Version(3, 0, 0)` and `models`
///    passthrough to `AppSchema.modelTypes` (V3 becomes the new latest,
///    and `CompositionRoot.build`'s default `persistence:` parameter
///    must be updated to target it — see that type's own doc comment
///    for why this exact step was missed for years across V1-V6 before
///    this file's own simplification, and do not repeat that mistake).
/// 3. Update `AppSchema.modelTypes` — only if a model *type* is
///    actually being added/removed. A field-level change to an
///    already-listed type does not touch this array at all.
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
/// 5. Add `AppSchemaV3.self` to `schemas` below, alongside
///    `AppCurrentSchema.self`/`AppSchemaV2.self` (old versions are
///    never removed, only appended to).
/// 6. Add a real `MigrationStage` to `stages` describing the V2 → V3
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
        [AppCurrentSchema.self, AppSchemaV2.self]
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
    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: AppCurrentSchema.self, toVersion: AppSchemaV2.self),
        ]
    }
}
