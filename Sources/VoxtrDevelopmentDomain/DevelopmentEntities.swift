import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

// MARK: - DevelopmentGoal (v1.3 Section 11.1)

@Model
public final class DevelopmentGoal {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var title: String
    public var goalDescription: String?
    public var status: GoalStatus
    public var category: String // skill, habit, physical, lifestyle, selfLeadership, other
    public var sportId: UUID?
    public var targetDate: LocalDate?
    public var createdBy: UUID
    public var activatedAt: Date?
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: GoalId = GoalId(),
        athleteId: AthleteId,
        title: String,
        goalDescription: String? = nil,
        status: GoalStatus = .draft,
        category: String,
        sportId: SportId? = nil,
        targetDate: LocalDate? = nil,
        createdBy: ActorId,
        activatedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition((1...120).contains(title.count), "title must be 1-120 characters (v1.3 Section 11.1)")
        if let d = goalDescription { precondition(d.count <= 1000, "description must be 0-1000 characters (v1.3 Section 11.1)") }
        precondition(status != .active || activatedAt != nil, "activatedAt required when active (v1.3 Section 11.1)")
        precondition(status != .completed || completedAt != nil, "completedAt required when completed (v1.3 Section 11.1)")
        self.id = id.rawValue
        self.athleteId = athleteId.rawValue
        self.title = title
        self.goalDescription = goalDescription
        self.status = status
        self.category = category
        self.sportId = sportId?.rawValue
        self.targetDate = targetDate
        self.createdBy = createdBy.rawValue
        self.activatedAt = activatedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var goalId: GoalId { GoalId(rawValue: id) }
}

// MARK: - DevelopmentFocus (v1.3 Section 11.2)

@Model
public final class DevelopmentFocus {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var goalId: UUID?
    public var title: String
    public var focusDescription: String?
    public var startDate: LocalDate
    public var endDate: LocalDate
    public var status: FocusStatus
    public var createdBy: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        athleteId: AthleteId,
        goalId: GoalId? = nil,
        title: String,
        focusDescription: String? = nil,
        startDate: LocalDate,
        endDate: LocalDate,
        status: FocusStatus = .planned,
        createdBy: ActorId,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition((1...120).contains(title.count), "title must be 1-120 characters (v1.3 Section 11.2)")
        if let d = focusDescription { precondition(d.count <= 500, "description must be 0-500 characters (v1.3 Section 11.2)") }
        precondition(!(endDate < startDate), "endDate must not precede startDate (v1.3 Section 11.2)")
        self.id = id
        self.athleteId = athleteId.rawValue
        self.goalId = goalId?.rawValue
        self.title = title
        self.focusDescription = focusDescription
        self.startDate = startDate
        self.endDate = endDate
        self.status = status
        self.createdBy = createdBy.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - DevelopmentInsight (v1.3 Section 11.3)

@Model
public final class DevelopmentInsight {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var insightType: String // trend, consistency, association, milestone, dataQuality, other
    public var title: String
    public var summary: String
    public var evidenceSummary: String
    public var sourceRecordIds: [UUID]
    public var sourceVersions: [Int]
    public var confidenceBand: String // low, moderate, high
    public var visibility: VisibilityPolicy
    public var generatedAt: Date
    public var validUntil: Date?
    public var calculationVersion: Int
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        athleteId: AthleteId,
        insightType: String,
        title: String,
        summary: String,
        evidenceSummary: String,
        sourceRecordIds: [UUID] = [],
        sourceVersions: [Int] = [],
        confidenceBand: String,
        visibility: VisibilityPolicy,
        generatedAt: Date = .now,
        validUntil: Date? = nil,
        calculationVersion: Int,
        schemaVersion: Int = 1
    ) {
        precondition((1...160).contains(title.count), "title must be 1-160 characters (v1.3 Section 11.3)")
        precondition((1...1000).contains(summary.count), "summary must be 1-1000 characters (v1.3 Section 11.3)")
        precondition(sourceRecordIds.count == sourceVersions.count, "sourceVersions must be parallel to sourceRecordIds (v1.3 Section 11.3)")
        precondition(!sourceRecordIds.isEmpty || insightType == "dataQuality", "sourceRecordIds may be empty only for dataQuality insight (v1.3 Section 11.3)")
        self.id = id
        self.athleteId = athleteId.rawValue
        self.insightType = insightType
        self.title = title
        self.summary = summary
        self.evidenceSummary = evidenceSummary
        self.sourceRecordIds = sourceRecordIds
        self.sourceVersions = sourceVersions
        self.confidenceBand = confidenceBand
        self.visibility = visibility
        self.generatedAt = generatedAt
        self.validUntil = validUntil
        self.calculationVersion = calculationVersion
        self.schemaVersion = schemaVersion
    }
}

// MARK: - WeeklySummaryProjection (v1.3 Section 11.4)

/// "Local Projection Store" per Section 17's placement matrix — disposable
/// and reproducible, never authoritative (Section 11.4). Implemented as a
/// plain value type, not a persisted `@Model`, since it must be trivially
/// rebuildable and is explicitly not source-of-truth data.
public struct WeeklySummaryProjection: Codable, Sendable {
    public let id: UUID
    public let athleteId: AthleteId
    public let weekStart: LocalDate
    public let plannedActivityCount: Int
    public let loggedActivityCount: Int
    public let plannedDurationMinutes: Int
    public let loggedDurationMinutes: Int
    public let totalSessionLoad: Int?
    public let planAdherenceRate: Double?
    public let averageSleepMinutes: Int?
    public let averageForm: Double?
    public let sourceFingerprint: String
    public let generatedAt: Date
    public let schemaVersion: Int

    public init(
        id: UUID = UUID(),
        athleteId: AthleteId,
        weekStart: LocalDate,
        plannedActivityCount: Int,
        loggedActivityCount: Int,
        plannedDurationMinutes: Int,
        loggedDurationMinutes: Int,
        totalSessionLoad: Int? = nil,
        planAdherenceRate: Double? = nil,
        averageSleepMinutes: Int? = nil,
        averageForm: Double? = nil,
        sourceFingerprint: String,
        generatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.athleteId = athleteId
        self.weekStart = weekStart
        self.plannedActivityCount = plannedActivityCount
        self.loggedActivityCount = loggedActivityCount
        self.plannedDurationMinutes = plannedDurationMinutes
        self.loggedDurationMinutes = loggedDurationMinutes
        self.totalSessionLoad = totalSessionLoad
        self.planAdherenceRate = planAdherenceRate
        self.averageSleepMinutes = averageSleepMinutes
        self.averageForm = averageForm
        self.sourceFingerprint = sourceFingerprint
        self.generatedAt = generatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - Domain events (v1.3 Section 11.1, 11.3, 16)

public struct DevelopmentGoalActivated: DomainEvent {
    public static let eventName = "development.goalActivated"
    public let goalId: GoalId
    public let athleteId: AthleteId
    public init(goalId: GoalId, athleteId: AthleteId) { self.goalId = goalId; self.athleteId = athleteId }
}

public struct DevelopmentGoalCompleted: DomainEvent {
    public static let eventName = "development.goalCompleted"
    public let goalId: GoalId
    public let athleteId: AthleteId
    public init(goalId: GoalId, athleteId: AthleteId) { self.goalId = goalId; self.athleteId = athleteId }
}

public struct DevelopmentInsightGenerated: DomainEvent {
    public static let eventName = "development.insightGenerated"
    public let athleteId: AthleteId
    public init(athleteId: AthleteId) { self.athleteId = athleteId }
}

public struct DevelopmentInsightInvalidated: DomainEvent {
    public static let eventName = "development.insightInvalidated"
    public let athleteId: AthleteId
    public init(athleteId: AthleteId) { self.athleteId = athleteId }
}

/// v1.3 Section 16: published by Development, consumed by the
/// application query/cache layer to know when to rebuild
/// WeeklySummaryProjection.
public struct DevelopmentProjectionInvalidated: DomainEvent {
    public static let eventName = "development.projectionInvalidated"
    public let athleteId: AthleteId
    public let dateRangeStart: LocalDate
    public let dateRangeEnd: LocalDate
    public let reason: String
    public init(athleteId: AthleteId, dateRangeStart: LocalDate, dateRangeEnd: LocalDate, reason: String) {
        self.athleteId = athleteId
        self.dateRangeStart = dateRangeStart
        self.dateRangeEnd = dateRangeEnd
        self.reason = reason
    }
}
