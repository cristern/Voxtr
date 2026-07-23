import Foundation
import SwiftData
import VoxtrCoreContracts

// MARK: - NotificationRule (v1.3 Section 13.1)

@Model
public final class NotificationRule {
    @Attribute(.unique) public var id: UUID
    public var workspaceId: UUID
    public var athleteId: UUID?
    public var ruleType: String // morningBrief, eveningCheckOut, weeklyReview, doubleSessionNutrition, postHighLoadRecovery, other
    public var enabled: Bool
    public var localTime: LocalTime?
    public var leadTimeMinutes: Int?
    public var timeZoneId: TimeZoneId
    public var createdBy: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        workspaceId: WorkspaceId,
        athleteId: AthleteId? = nil,
        ruleType: String,
        enabled: Bool = true,
        localTime: LocalTime? = nil,
        leadTimeMinutes: Int? = nil,
        timeZoneId: TimeZoneId,
        createdBy: ActorId,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        if let lead = leadTimeMinutes { precondition((0...10080).contains(lead), "leadTimeMinutes must be 0-10080 (v1.3 Section 13.1)") }
        self.id = id
        self.workspaceId = workspaceId.rawValue
        self.athleteId = athleteId?.rawValue
        self.ruleType = ruleType
        self.enabled = enabled
        self.localTime = localTime
        self.leadTimeMinutes = leadTimeMinutes
        self.timeZoneId = timeZoneId
        self.createdBy = createdBy.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - ScheduledReminder (v1.3 Section 13.2)

@Model
public final class ScheduledReminder {
    @Attribute(.unique) public var id: UUID
    public var ruleId: UUID?
    public var athleteId: UUID?
    public var recipientParticipantId: UUID
    public var titleKey: String
    public var bodyKey: String
    public var bodyArguments: [String]
    public var scheduledFor: Date
    public var state: ReminderDeliveryState
    public var deduplicationKey: String
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        ruleId: UUID? = nil,
        athleteId: AthleteId? = nil,
        recipientParticipantId: UUID,
        titleKey: String,
        bodyKey: String,
        bodyArguments: [String] = [],
        scheduledFor: Date,
        state: ReminderDeliveryState = .scheduled,
        deduplicationKey: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.ruleId = ruleId
        self.athleteId = athleteId?.rawValue
        self.recipientParticipantId = recipientParticipantId
        self.titleKey = titleKey
        self.bodyKey = bodyKey
        self.bodyArguments = bodyArguments
        self.scheduledFor = scheduledFor
        self.state = state
        self.deduplicationKey = deduplicationKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - DeliveryRecord (v1.3 Section 13.3)

@Model
public final class DeliveryRecord {
    @Attribute(.unique) public var id: UUID
    public var scheduledReminderId: UUID
    public var attemptedAt: Date
    public var state: ReminderDeliveryState // delivered, failed, suppressed
    public var failureCode: String?
    public var deviceIdHash: String?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        scheduledReminderId: UUID,
        attemptedAt: Date = .now,
        state: ReminderDeliveryState,
        failureCode: String? = nil,
        deviceIdHash: String? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.scheduledReminderId = scheduledReminderId
        self.attemptedAt = attemptedAt
        self.state = state
        self.failureCode = failureCode
        self.deviceIdHash = deviceIdHash
        self.schemaVersion = schemaVersion
    }
}
