import Foundation
import SwiftData
import VoxtrCoreContracts

/// Frozen, historically-accurate snapshots of model shapes as they
/// existed at earlier schema versions — NEVER constructed or
/// referenced by application code. Their sole purpose is to give
/// SwiftData's schema-checksum computation a genuinely different shape
/// to compare against the live, current type, for versions where only
/// a field-level change happened (no model *type* added or removed).
///
/// ROOT CAUSE this file fixes (a critical, launch-blocking crash):
/// `AppSchemaV1` through `AppSchemaV6` are all `VersionedSchema`s that,
/// before this fix, listed the SAME LIVE Swift classes
/// (`VoxtrAthleteDomain.AthleteProfile`, `VoxtrParentDomain
/// .WorkspaceParticipant`) for every version — because a Swift class
/// has exactly one definition, "AppSchemaV5's AthleteProfile" and
/// "AppSchemaV6's AthleteProfile" were literally the same type,
/// reflecting whatever shape that class currently has in source. For
/// versions where a model TYPE was added or removed (e.g. V1→V2 added
/// `PlannedActivityDeletionTombstone`), the overall schema checksum
/// still genuinely differed because the type COUNT differed — so this
/// was never a problem there. But for a version bump that changed only
/// a FIELD on an already-listed type (V3→V4's `WorkspaceParticipant
/// .declinedAt` addition; V5→V6's `AthleteProfile.birthDate` →
/// `birthDateRaw` storage change), both "old" and "new" versions
/// referenced the identical live class — producing IDENTICAL
/// checksums for that stage. `NSLightweightMigrationStage
/// .init(versionChecksums:)` requires the two checksums to genuinely
/// differ to represent a real migration; given identical checksums, it
/// throws an uncaught `NSException`, which aborts the process —
/// BEFORE the persistent store is ever opened, before any row is read.
/// This crashed on launch for any real device whose store was
/// literally at the affected "from" version (V3 or V5) when the app
/// updated.
///
/// THE FIX: give each affected historical version its own frozen,
/// separately-declared type for the field(s) that actually changed,
/// nested in an enum namespace so its Swift type name differs from the
/// live type while its persisted SwiftData ENTITY name — derived from
/// the unqualified class name, "AthleteProfile"/"WorkspaceParticipant"
/// — stays identical to the live type's. This is Apple's own
/// documented pattern for typed schema migrations (see the SwiftData
/// migration documentation on "Define versioned schemas"): it is what
/// lets SwiftData recognize the old and new declarations as the same
/// logical entity undergoing a real, checksummable shape change,
/// rather than as two unrelated entities (which would drop the old
/// table and lose everything, not just one field). Never constructed,
/// never mutated, never referenced by any repository/service/view —
/// its only job is to exist with the correct historical shape so
/// `AppSchemaV1` through `AppSchemaV5` (for `AthleteProfile`) and
/// `AppSchemaV1` through `AppSchemaV3` (for `WorkspaceParticipant`) can
/// list it in `.models`, giving those versions' checksums genuine,
/// accurate fidelity to what real devices actually had persisted.
enum LegacyAthleteProfileSchema {
    /// Shape as it existed from V1 through V5: `birthDate` stored
    /// directly as `LocalDate`. See `VoxtrAthleteDomain.AthleteEntities
    /// .swift`'s own doc comment on `birthDateRaw` for why that
    /// direct-`LocalDate`-storage shape is what crashes when read back
    /// on the live type today — this frozen copy is never read by
    /// application code, so it cannot trigger that crash; it exists
    /// purely for its declared shape.
    @Model
    final class AthleteProfile {
        @Attribute(.unique) var id: UUID = UUID()
        var workspaceId: UUID = UUID()
        var givenName: String = ""
        var familyName: String?
        var preferredName: String?
        var birthDate: LocalDate = LocalDate(year: 1900, month: 1, day: 1)
        var timeZoneId: TimeZoneId = TimeZoneId(rawValue: "UTC")
        var developmentStage: DevelopmentStage = DevelopmentStage.parentLed
        var avatarAssetKey: String?
        var isArchived: Bool = false
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now
        var schemaVersion: Int = 1
        var revision: Int = 1
    }
}

enum LegacyWorkspaceParticipantSchema {
    /// Shape as it existed from V1 through V3: no `declinedAt` field
    /// (added at V4 — see `AppSchemaV4`'s own doc comment).
    @Model
    final class WorkspaceParticipant {
        @Attribute(.unique) var id: UUID = UUID()
        var workspaceId: UUID = UUID()
        var accountId: String = ""
        var role: WorkspaceRole = WorkspaceRole.workspaceOwner
        var state: ParticipantState = ParticipantState.invited
        var linkedAthleteId: UUID?
        var invitedBy: UUID?
        var invitedAt: Date?
        var acceptedAt: Date?
        var revokedAt: Date?
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now
        var schemaVersion: Int = 1
    }
}
