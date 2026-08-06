import Foundation
import SwiftData

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
/// Given there is no production user data to preserve — this app has
/// never left TestFlight, and the only affected stores are internal
/// test installations — the simplest, most defensible fix is this:
/// collapse the entire schema history to ONE current, live version,
/// with an EMPTY migration-stage list. This is not "bypassing
/// migration": `AppSchemaMigrationPlan` still exists, is still a real
/// `SchemaMigrationPlan`, and is still what `CompositionRoot` passes to
/// `ModelContainer.init` — there is simply nothing to migrate FROM yet,
/// because this is the first version of the simplified scheme. A future
/// genuine schema change gets a real `AppSchemaV2` and a real migration
/// stage, added the normal way (see "HOW TO ADD A NEW VERSION" below) —
/// but critically, `AppSchema.modelTypes`'s own *live* types
/// (`AthleteProfile` with `birthDateRaw`, `WorkspaceParticipant` with
/// `declinedAt`, etc.) are completely unchanged by this file's own
/// simplification. No live model type, no validation, no required
/// field was altered to make this fix — only the versioning
/// *scaffolding* around them was simplified.
///
/// A device with an existing store from ANY earlier build (any of the
/// old V1-V6 shapes) will NOT silently lose data: `ModelContainer.init`
/// will find that the store's own recorded schema doesn't match this
/// single declared version and doesn't match any migration path this
/// plan defines, and will throw — surfaced in full by
/// `StartupDiagnostics`, never hidden, never auto-deleted. Since this
/// is pre-release TestFlight software with no production data at
/// stake, the correct recovery for that case is deleting and
/// reinstalling the app, the same recovery already used once for
/// build 130 — not a silent, invisible reset performed by this code.
public enum AppCurrentSchema: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        AppSchema.modelTypes
    }
}

/// HOW TO ADD A NEW VERSION (read this before adding, renaming, or
/// removing any `@Model` property or type in `AppSchema.modelTypes`
/// from this point forward):
///
/// 1. Freeze `AppCurrentSchema.models` to a hardcoded literal array —
///    copy its current passthrough result before changing anything, the
///    same way every future version's predecessor must be frozen.
/// 2. Add a new `AppSchemaV2: VersionedSchema` enum in this file, with
///    `versionIdentifier: Schema.Version(2, 0, 0)` and `models`
///    passthrough to `AppSchema.modelTypes` (V2 becomes the new latest,
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
/// 5. Add `AppSchemaV2.self` to `schemas` below, alongside
///    `AppCurrentSchema.self` (old versions are never removed, only
///    appended to).
/// 6. Add a real `MigrationStage` to `stages` describing the V1 → V2
///    transition.
/// 7. Do not skip version numbers — each actually-shipped schema
///    change gets its own version and its own stage, in order.
public enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [AppCurrentSchema.self]
    }

    /// Empty, deliberately — `AppCurrentSchema` is the first and only
    /// version in this simplified scheme, so there is nothing to
    /// migrate from yet. An empty `stages` array is a valid,
    /// well-formed `SchemaMigrationPlan` — it means exactly "no
    /// migrations are currently defined," not "migration is bypassed."
    public static var stages: [MigrationStage] {
        []
    }
}
