import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

// MARK: - WeekPlan (v1.3 Section 8.1 / DDM-002, DDM-009)

@Model
public final class WeekPlan {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var weekStart: LocalDate
    public var status: WeekPlanStatus
    public var revision: Int
    public var focusNote: String?
    public var committedAt: Date?
    public var committedBy: UUID?
    public var closedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: WeekPlanId = WeekPlanId(),
        athleteId: AthleteId,
        weekStart: LocalDate,
        status: WeekPlanStatus = .draft,
        revision: Int = 1,
        focusNote: String? = nil,
        committedAt: Date? = nil,
        committedBy: ActorId? = nil,
        closedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        if let note = focusNote {
            precondition(note.count <= 300, "focusNote must be 0-300 characters (v1.3 Section 8.1)")
        }
        precondition(status != .committed || (committedAt != nil && committedBy != nil), "committedAt/committedBy required when status is committed (v1.3 Section 8.1)")
        precondition(status != .closed || closedAt != nil, "closedAt required when status is closed (v1.3 Section 8.1)")
        self.id = id.rawValue
        self.athleteId = athleteId.rawValue
        self.weekStart = weekStart
        self.status = status
        self.revision = revision
        self.focusNote = focusNote
        self.committedAt = committedAt
        self.committedBy = committedBy?.rawValue
        self.closedAt = closedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var weekPlanId: WeekPlanId { WeekPlanId(rawValue: id) }
}

// MARK: - PlannedActivity (v1.3 Section 8.2)

@Model
public final class PlannedActivity {
    @Attribute(.unique) public var id: UUID
    public var weekPlanId: UUID
    public var athleteId: UUID
    public var sportId: UUID?
    public var categoryIds: [UUID]
    public var activityType: ActivityType
    public var title: String
    public var localDate: LocalDate
    public var startLocalTime: LocalTime?
    public var timeZoneId: TimeZoneId
    public var plannedDurationMinutes: Int?
    public var plannedIntensity: Int?
    public var externalSourceId: String?
    public var externalSourceType: String?
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: PlannedActivityId = PlannedActivityId(),
        weekPlanId: WeekPlanId,
        athleteId: AthleteId,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        activityType: ActivityType,
        title: String,
        localDate: LocalDate,
        startLocalTime: LocalTime? = nil,
        timeZoneId: TimeZoneId,
        plannedDurationMinutes: Int? = nil,
        plannedIntensity: Int? = nil,
        externalSourceId: String? = nil,
        externalSourceType: String? = nil,
        notes: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition((1...120).contains(title.count), "title must be 1-120 characters (v1.3 Section 8.2)")
        if let duration = plannedDurationMinutes {
            precondition((1...1440).contains(duration), "plannedDurationMinutes must be 1-1440 (v1.3 Section 8.2)")
        }
        if let intensity = plannedIntensity {
            precondition((1...10).contains(intensity), "plannedIntensity must be 1-10 (v1.3 Section 8.2)")
        }
        if let n = notes {
            precondition(n.count <= 500, "notes must be 0-500 characters (v1.3 Section 8.2)")
        }
        self.id = id.rawValue
        self.weekPlanId = weekPlanId.rawValue
        self.athleteId = athleteId.rawValue
        self.sportId = sportId?.rawValue
        self.categoryIds = categoryIds.map(\.rawValue)
        self.activityType = activityType
        self.title = title
        self.localDate = localDate
        self.startLocalTime = startLocalTime
        self.timeZoneId = timeZoneId
        self.plannedDurationMinutes = plannedDurationMinutes
        self.plannedIntensity = plannedIntensity
        self.externalSourceId = externalSourceId
        self.externalSourceType = externalSourceType
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var plannedActivityId: PlannedActivityId { PlannedActivityId(rawValue: id) }
}

// MARK: - PlanningDecision (v1.3 Section 8.3)

@Model
public final class PlanningDecision {
    @Attribute(.unique) public var id: UUID
    public var weekPlanId: UUID
    public var baseRevision: Int
    public var resultingRevision: Int?
    public var authorId: UUID
    public var decisionType: PlanningDecisionType
    public var affectedActivityIds: [UUID]
    public var resolution: String?
    public var accepted: Bool
    public var createdAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        weekPlanId: WeekPlanId,
        baseRevision: Int,
        resultingRevision: Int? = nil,
        authorId: ActorId,
        decisionType: PlanningDecisionType,
        affectedActivityIds: [PlannedActivityId] = [],
        resolution: String? = nil,
        accepted: Bool,
        createdAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition(accepted == (resultingRevision != nil), "resultingRevision is nil exactly when rejected (v1.3 Section 8.3)")
        if let r = resolution {
            precondition(r.count <= 500, "resolution must be 0-500 characters (v1.3 Section 8.3)")
        }
        self.id = id
        self.weekPlanId = weekPlanId.rawValue
        self.baseRevision = baseRevision
        self.resultingRevision = resultingRevision
        self.authorId = authorId.rawValue
        self.decisionType = decisionType
        self.affectedActivityIds = affectedActivityIds.map(\.rawValue)
        self.resolution = resolution
        self.accepted = accepted
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - Domain events (v1.3 Section 8.1, 8.2, 16)

public struct WeekPlanCreated: DomainEvent {
    public static let eventName = "planning.weekPlanCreated"
    public let weekPlanId: WeekPlanId
    public let athleteId: AthleteId
    public init(weekPlanId: WeekPlanId, athleteId: AthleteId) {
        self.weekPlanId = weekPlanId; self.athleteId = athleteId
    }
}

public struct WeekPlanCommitted: DomainEvent {
    public static let eventName = "planning.weekPlanCommitted"
    public let weekPlanId: WeekPlanId
    public let athleteId: AthleteId
    public let revision: Int
    public let committedAt: Date
    public init(weekPlanId: WeekPlanId, athleteId: AthleteId, revision: Int, committedAt: Date = .now) {
        self.weekPlanId = weekPlanId; self.athleteId = athleteId; self.revision = revision; self.committedAt = committedAt
    }
}

public struct WeekPlanClosed: DomainEvent {
    public static let eventName = "planning.weekPlanClosed"
    public let weekPlanId: WeekPlanId
    public let athleteId: AthleteId
    public init(weekPlanId: WeekPlanId, athleteId: AthleteId) {
        self.weekPlanId = weekPlanId; self.athleteId = athleteId
    }
}

public struct WeekPlanConflictDetected: DomainEvent {
    public static let eventName = "planning.weekPlanConflictDetected"
    public let weekPlanId: WeekPlanId
    public let athleteId: AthleteId
    public init(weekPlanId: WeekPlanId, athleteId: AthleteId) {
        self.weekPlanId = weekPlanId; self.athleteId = athleteId
    }
}

public struct PlannedActivityCreated: DomainEvent {
    public static let eventName = "planning.plannedActivityCreated"
    public let plannedActivityId: PlannedActivityId
    public let athleteId: AthleteId
    public let weekPlanId: WeekPlanId
    public init(plannedActivityId: PlannedActivityId, athleteId: AthleteId, weekPlanId: WeekPlanId) {
        self.plannedActivityId = plannedActivityId; self.athleteId = athleteId; self.weekPlanId = weekPlanId
    }
}

public struct PlannedActivityChanged: DomainEvent {
    public static let eventName = "planning.plannedActivityChanged"
    public let plannedActivityId: PlannedActivityId
    public let athleteId: AthleteId
    public let weekPlanId: WeekPlanId
    public let changeType: String
    public init(plannedActivityId: PlannedActivityId, athleteId: AthleteId, weekPlanId: WeekPlanId, changeType: String) {
        self.plannedActivityId = plannedActivityId; self.athleteId = athleteId; self.weekPlanId = weekPlanId; self.changeType = changeType
    }
}

public struct PlannedActivityDeleted: DomainEvent {
    public static let eventName = "planning.plannedActivityDeleted"
    public let plannedActivityId: PlannedActivityId
    public let athleteId: AthleteId
    public init(plannedActivityId: PlannedActivityId, athleteId: AthleteId) {
        self.plannedActivityId = plannedActivityId; self.athleteId = athleteId
    }
}
