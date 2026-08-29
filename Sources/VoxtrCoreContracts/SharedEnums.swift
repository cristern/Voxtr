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

/// Sport / Activity Identity domain foundation round: `physicalTraining` remains
/// readable as a legacy persisted enum case for backward compatibility with historical
/// records. It is excluded from `ActivityType.selectableCases` so it cannot be selected for
/// new activity input. `strength` and `conditioning` are the current selectable replacements.
/// Historical activities persisted as `physicalTraining` remain readable and queryable, and
/// no reinstall or store reset is required.
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

// `ReminderDeliveryState` (v1.3 Section 13's original NotificationRule/
// ScheduledReminder/DeliveryRecord scaffold) removed by Notifications V1
// Activity Reminder Foundation — its only consumers were the superseded
// scaffold types (see `VoxtrNotificationsDomain/NotificationsEntities.swift`'s
// own doc comment for why); no delivery-state persistence exists in the
// approved V1 model, so this enum had no remaining consumer anywhere in
// the codebase. Do not re-add it without a real consumer.

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
