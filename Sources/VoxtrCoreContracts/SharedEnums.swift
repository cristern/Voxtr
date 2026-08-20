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

/// Sport / Activity Identity domain foundation round: `physicalTraining`
/// was replaced with `strength`/`conditioning` — Statistics needs these
/// independently queryable, and the single broad case could not express
/// that. This is a genuine, intentional raw-value change (not additive):
/// any already-persisted row whose stored `activityType` raw string is
/// still `"physicalTraining"` will fail to decode after this change.
/// Repository evidence (existing test fixtures/usage before this round)
/// showed no consistent, recoverable signal for which of the two new
/// cases any given historical `physicalTraining` activity actually
/// meant — one fixture used it for "Strength," another for "Wednesday
/// gym" (which could equally mean conditioning) — so no deterministic
/// or "neutral default" auto-migration was written; inventing one would
/// silently misclassify some activities as a category their user never
/// chose. Per this codebase's own established Internal Alpha policy for
/// genuine field/enum reshapes with no production data at stake (see
/// `RecurringPlannedActivity.weekdays`'s own doc comment for the
/// identical precedent), this is documented as an explicit, accepted
/// Internal Alpha limitation rather than a fuzzy-mapped migration: any
/// existing local/TestFlight store containing a `physicalTraining`-typed
/// `PlannedActivity`/`LoggedActivity`/`RecurringPlannedActivity` row
/// needs a fresh install/store reset to pick this up cleanly. This must
/// be revisited with a real, explicit user-facing correction flow before
/// genuine production data exists.
public enum ActivityType: String, Codable, Sendable, CaseIterable {
    case teamTraining, match, competition, individualTraining
    case strength, conditioning, recovery, test, other

    /// Legacy classification present in historical persisted data (V3 and earlier).
    /// Kept for backward compatibility when decoding historical records.
    /// Excluded from `selectableCases` so it cannot be chosen for new activity input.
    case physicalTraining

    /// The canonical list of `ActivityType` cases selectable for new or edited activities.
    /// Excludes legacy/deprecated cases such as `.physicalTraining`.
    public static var selectableCases: [ActivityType] {
        [.teamTraining, .match, .competition, .individualTraining, .strength, .conditioning, .recovery, .test, .other]
    }

    /// User-visible display label for each activity type case.
    public var displayName: String {
        switch self {
        case .teamTraining: return "Team training"
        case .match: return "Match"
        case .competition: return "Competition"
        case .individualTraining: return "Individual training"
        case .strength: return "Strength"
        case .conditioning: return "Conditioning"
        case .recovery: return "Recovery"
        case .test: return "Test"
        case .other: return "Other"
        case .physicalTraining: return "Physical training"
        }
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
