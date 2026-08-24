import Foundation

// v1.3 Section 4: "Enums listed in this document are closed for v1.3;
// additions require a schema revision." Every case below is copied
// verbatim from Section 4's table — none invented, none omitted. Enums
// used by v1.2's implementation that are NOT in this table (IntensityBand,
// LogSource, PlanningSource, CompletionStatus, PlannedActivityStatus) have
// been removed; the fields that used them now use the type v1.3
// specifies instead (often a plain String or Int — see each entity).

public enum DevelopmentStage: String, Codable, Sendable, CaseIterable {
    case parentLed, sharedOwnership, guidedIndependence, athleteLed
}

/// Sport / Activity Identity domain foundation round: `strength`/
/// `conditioning` were added as the new, independently-queryable
/// replacements for the old single `physicalTraining` case — Statistics
/// needs the two queryable separately, and review correctly rejected
/// this round's first attempt (removing `physicalTraining` outright),
/// since that would have made any already-persisted row whose stored
/// `activityType` raw string is `"physicalTraining"` fail to decode —
/// existing activity history must remain readable, full stop, never
/// conditioned on a reinstall.
///
/// `physicalTraining` therefore stays a REAL case — decoding an
/// existing row never fails — but it is LEGACY / PERSISTENCE
/// COMPATIBILITY ONLY: never offered by any Picker, never a valid
/// choice for a newly-created `PlannedActivity`/`RecurringPlannedActivity`
/// (`PlanningService.addPlannedActivity`/`createRecurringPlannedActivity`
/// both reject it — see `ActivityType.isLegacyPersistenceOnly`).
/// Repository evidence (existing test fixtures/usage before this round)
/// showed no consistent, recoverable signal for which of the two new
/// cases any given historical `physicalTraining` activity actually
/// meant — one fixture used it for "Strength," another for "Wednesday
/// gym" (which could equally mean conditioning) — so no fuzzy/"neutral
/// default" auto-remap was written; inventing one would silently
/// misclassify some activities as a category their user never chose.
/// Keeping the honest, ambiguous historical value — rather than
/// guessing or discarding it — is the deliberate choice here: it reads
/// back exactly as it always did, and `isLegacyPersistenceOnly` is what
/// stops it from ever being written again, without requiring any
/// destructive migration, reinstall, or store reset.
public enum ActivityType: String, Codable, Sendable, CaseIterable {
    case teamTraining, match, competition, individualTraining
    case strength, conditioning, recovery, test, other
    /// LEGACY / PERSISTENCE COMPATIBILITY ONLY. Never offered by any
    /// Picker, never returned by `selectableCases`, and rejected by
    /// every genuinely-new-activity creation path (`PlanningService
    /// .addPlannedActivity`/`.createRecurringPlannedActivity`). Exists
    /// solely so an existing pre-this-round row keeps decoding — see
    /// this enum's own doc comment.
    case physicalTraining
}

public extension ActivityType {
    /// The product-facing case list every NEW-activity Picker/
    /// create-path must offer — excludes `physicalTraining`. Use this,
    /// never `allCases` directly, anywhere a human is choosing a
    /// classification for something new.
    static var selectableCases: [ActivityType] {
        [.teamTraining, .match, .competition, .individualTraining, .strength, .conditioning, .recovery, .test, .other]
    }

    /// True only for `physicalTraining` — the one case existing storage
    /// may still contain, never a case a human can newly choose.
    var isLegacyPersistenceOnly: Bool {
        self == .physicalTraining
    }
}

public enum ActivityStatus: String, Codable, Sendable, CaseIterable {
    case scheduled, completed, partiallyCompleted, cancelled, missed
}

public enum WeekPlanStatus: String, Codable, Sendable, CaseIterable {
    case draft, committed, closed
}

public enum PlanningDecisionType: String, Codable, Sendable, CaseIterable {
    case createActivity, updateActivity, deleteActivity, restoreActivity
    case commitWeek, reopenWeek, closeWeek, resolveConflict
}

public enum VisibilityPolicy: String, Codable, Sendable, CaseIterable {
    case sharedWithGuardians, summaryOnly, privateToAthlete
}

public enum WorkspaceRole: String, Codable, Sendable, CaseIterable {
    case workspaceOwner, guardianEditor, guardianViewer, athlete
}

public enum ParticipantState: String, Codable, Sendable, CaseIterable {
    case invited, active, revoked, declined
}

public enum GoalStatus: String, Codable, Sendable, CaseIterable {
    case draft, active, paused, completed, abandoned
}

public enum FocusStatus: String, Codable, Sendable, CaseIterable {
    case planned, active, completed, cancelled
}

public enum RecommendationStatus: String, Codable, Sendable, CaseIterable {
    case generated, presented, accepted, declined, dismissed, expired
}

public enum RecommendationResponseType: String, Codable, Sendable, CaseIterable {
    case accept, decline, postpone, needsDiscussion, notRelevant
}

public enum ReminderDeliveryState: String, Codable, Sendable, CaseIterable {
    case scheduled, delivered, failed, cancelled, suppressed
}

public enum SyncState: String, Codable, Sendable, CaseIterable {
    case localOnly, pendingUpload, synced, conflict, tombstoned
}

/// Design Foundation V0.1 (Athlete Color canonical preference round) —
/// NOT part of the original v1.3 Section 4 enum table this file's own
/// header comment describes; added under this task's explicit approval
/// to persist a single, canonical, user-configurable athlete-colour
/// preference (`AthleteSettings.preferredColor`, `VoxtrAthleteDomain`).
/// The eight cases are the approved Athlete Color palette — identity
/// only, never performance/readiness/status. Deliberately has no
/// `Color`/UIKit-facing members: this package cannot import SwiftUI (see
/// `Package.swift`'s dependency rule), so the actual hex values and
/// `Color` rendering live entirely in `VoxtrAppShell` as an extension on
/// this same type (`VoxtrDesignSystem.swift`) — one canonical type, one
/// persisted representation, no parallel/duplicate colour enum.
public enum AthleteColor: String, Codable, Sendable, CaseIterable {
    case blue, indigo, purple, rose, orange, amber, green, cyan
}
