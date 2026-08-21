import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

// MARK: - LoggedActivity (v1.3 Section 9.1 / DDM-003)

@Model
public final class LoggedActivity {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var plannedActivityId: UUID?
    public var sportId: UUID?
    public var categoryIds: [UUID]
    public var activityType: ActivityType
    /// Sport / Activity Identity domain foundation: optional, same
    /// representation and same canonical invariant as
    /// `PlannedActivity.title` — see that property's own doc comment
    /// and `ActivityIdentity.swift`.
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var durationMinutes: Int
    public var status: ActivityStatus
    public var perceivedExertion: Int?
    public var source: String // manual, planned, imported (v1.3 Section 9.1)
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: LoggedActivityId = LoggedActivityId(),
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId? = nil,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        activityType: ActivityType,
        title: String?,
        startedAt: Date,
        endedAt: Date? = nil,
        durationMinutes: Int,
        status: ActivityStatus,
        perceivedExertion: Int? = nil,
        source: String,
        notes: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        let normalizedTitle = ActivityIdentity.normalizedName(title)
        precondition(
            ActivityIdentity.isValid(normalizedName: normalizedTitle, sportId: sportId),
            "LoggedActivity requires a non-blank title or a sportId (Sport / Activity Identity round)"
        )
        precondition((1...1440).contains(durationMinutes), "durationMinutes must be 1-1440 (v1.3 Section 9.1)")
        if let rpe = perceivedExertion {
            precondition((1...10).contains(rpe), "perceivedExertion must be 1-10 (v1.3 Section 9.1)")
        }
        if let n = notes {
            precondition(n.count <= 500, "notes must be 0-500 characters (v1.3 Section 9.1)")
        }
        self.id = id.rawValue
        self.athleteId = athleteId.rawValue
        self.plannedActivityId = plannedActivityId?.rawValue
        self.sportId = sportId?.rawValue
        self.categoryIds = categoryIds.map(\.rawValue)
        self.activityType = activityType
        self.title = normalizedTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMinutes = durationMinutes
        self.status = status
        self.perceivedExertion = perceivedExertion
        self.source = source
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var loggedActivityId: LoggedActivityId { LoggedActivityId(rawValue: id) }
}

// MARK: - ActivityLoad (v1.3 Section 9.2)

/// Derived and reproducible from LoggedActivity; "must never be edited
/// directly by the user" (Section 9.2). The Calculation Engine design
/// discussed separately is the intended producer of `sessionLoad` —
/// this entity is the storage shape, not the calculation itself.
@Model
public final class ActivityLoad {
    @Attribute(.unique) public var id: UUID
    public var loggedActivityId: UUID
    public var durationMinutes: Int
    public var rpe: Int?
    public var sessionLoad: Int?
    public var calculationVersion: Int
    public var calculatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        loggedActivityId: LoggedActivityId,
        durationMinutes: Int,
        rpe: Int? = nil,
        sessionLoad: Int? = nil,
        calculationVersion: Int,
        calculatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.loggedActivityId = loggedActivityId.rawValue
        self.durationMinutes = durationMinutes
        self.rpe = rpe
        self.sessionLoad = sessionLoad
        self.calculationVersion = calculationVersion
        self.calculatedAt = calculatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - TrainingAttachment (v1.3 Section 9.3)

/// SCHEMA ONLY per Section 19: "TrainingAttachment remains schema-only
/// and must not receive upload logic." This type exists so the shape is
/// reserved; no upload/download code is implemented anywhere in this
/// codebase.
@Model
public final class TrainingAttachment {
    @Attribute(.unique) public var id: UUID
    public var loggedActivityId: UUID
    public var kind: String
    public var fileName: String
    public var mimeType: String
    public var byteCount: Int64
    public var assetReference: String
    public var createdAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        loggedActivityId: LoggedActivityId,
        kind: String,
        fileName: String,
        mimeType: String,
        byteCount: Int64,
        assetReference: String,
        createdAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition(byteCount >= 0, "byteCount must be non-negative (v1.3 Section 9.3)")
        self.id = id
        self.loggedActivityId = loggedActivityId.rawValue
        self.kind = kind
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.assetReference = assetReference
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - Domain events (v1.3 Section 9.1, 16)

public struct ActivityLogged: DomainEvent {
    public static let eventName = "training.activityLogged"
    public let loggedActivityId: LoggedActivityId
    public let athleteId: AthleteId
    public let plannedActivityId: PlannedActivityId?
    public let durationMinutes: Int
    public init(loggedActivityId: LoggedActivityId, athleteId: AthleteId, plannedActivityId: PlannedActivityId? = nil, durationMinutes: Int) {
        self.loggedActivityId = loggedActivityId
        self.athleteId = athleteId
        self.plannedActivityId = plannedActivityId
        self.durationMinutes = durationMinutes
    }
}

public struct ActivityLogCorrected: DomainEvent {
    public static let eventName = "training.activityLogCorrected"
    public let loggedActivityId: LoggedActivityId
    public let athleteId: AthleteId
    public let changedFields: [String]
    public init(loggedActivityId: LoggedActivityId, athleteId: AthleteId, changedFields: [String]) {
        self.loggedActivityId = loggedActivityId
        self.athleteId = athleteId
        self.changedFields = changedFields
    }
}

public struct ActivityLogDeleted: DomainEvent {
    public static let eventName = "training.activityLogDeleted"
    public let loggedActivityId: LoggedActivityId
    public let athleteId: AthleteId
    public init(loggedActivityId: LoggedActivityId, athleteId: AthleteId) {
        self.loggedActivityId = loggedActivityId
        self.athleteId = athleteId
    }
}
