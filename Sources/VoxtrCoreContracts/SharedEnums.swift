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

public enum ActivityType: String, Codable, Sendable, CaseIterable {
    case teamTraining, match, competition, individualTraining
    case physicalTraining, recovery, test, other
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
