import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

// MARK: - WeekPlan (v1.3 Section 8.1 / DDM-002, DDM-009)

@Model
public final class WeekPlan {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    // CRASH FIX: stored as an ISO date String, not `LocalDate` directly.
    // SwiftData on this Xcode/OS generation has a documented bug
    // ("Could not cast value of type '__NSCFNumber' to 'NSString'")
    // persisting custom Codable struct properties directly on a
    // @Model, reproduced by multiple independent Apple Developer Forum
    // reports of this exact message on Xcode 26 — triggered here when
    // fetching multiple WeekPlan rows with differing `weekStart`
    // values. `weekStart` below is the same public `LocalDate` API
    // every caller (repository, tests) already uses — nothing about
    // storage format is business behavior.
    private var weekStartRaw: String
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
        self.weekStartRaw = weekStart.isoString
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

    /// Same public type every caller already uses — see the storage
    /// note above. Falls back to the epoch only if `weekStartRaw` were
    /// ever externally corrupted; every write through this property
    /// itself always produces a valid ISO string.
    public var weekStart: LocalDate {
        get { LocalDate(isoString: weekStartRaw) ?? LocalDate(year: 1970, month: 1, day: 1) }
        set { weekStartRaw = newValue.isoString }
    }
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
    // Same fix as WeekPlan.weekStart above, applied proactively here:
    // fetching/sorting multiple PlannedActivity rows with differing
    // `localDate` values hits the identical documented SwiftData bug.
    private var localDateRaw: String
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
        self.localDateRaw = localDate.isoString
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

    public var localDate: LocalDate {
        get { LocalDate(isoString: localDateRaw) ?? LocalDate(year: 1970, month: 1, day: 1) }
        set { localDateRaw = newValue.isoString }
    }
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
