import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

// MARK: - Recommendation (v1.3 Section 12.1)

@Model
public final class Recommendation {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var recommendationType: String // planningPlacement, recoveryPrompt, reflectionPrompt, nutritionReminder, loadReflection, other
    public var title: String
    public var message: String
    public var status: RecommendationStatus
    public var confidenceBand: String // low, moderate, high
    public var validFrom: Date
    public var validUntil: Date?
    public var targetEntityId: UUID?
    public var createdAt: Date
    public var presentedAt: Date?
    public var resolvedAt: Date?
    public var calculationVersion: Int
    public var schemaVersion: Int

    public init(
        id: RecommendationId = RecommendationId(),
        athleteId: AthleteId,
        recommendationType: String,
        title: String,
        message: String,
        status: RecommendationStatus = .generated,
        confidenceBand: String,
        validFrom: Date = .now,
        validUntil: Date? = nil,
        targetEntityId: UUID? = nil,
        createdAt: Date = .now,
        presentedAt: Date? = nil,
        resolvedAt: Date? = nil,
        calculationVersion: Int,
        schemaVersion: Int = 1
    ) {
        precondition((1...160).contains(title.count), "title must be 1-160 characters (v1.3 Section 12.1)")
        precondition((1...1000).contains(message.count), "message must be 1-1000 characters (v1.3 Section 12.1)")
        self.id = id.rawValue
        self.athleteId = athleteId.rawValue
        self.recommendationType = recommendationType
        self.title = title
        self.message = message
        self.status = status
        self.confidenceBand = confidenceBand
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.targetEntityId = targetEntityId
        self.createdAt = createdAt
        self.presentedAt = presentedAt
        self.resolvedAt = resolvedAt
        self.calculationVersion = calculationVersion
        self.schemaVersion = schemaVersion
    }

    public var recommendationId: RecommendationId { RecommendationId(rawValue: id) }
}

// MARK: - RecommendationEvidence (v1.3 Section 12.2)

@Model
public final class RecommendationEvidence {
    @Attribute(.unique) public var id: UUID
    public var recommendationId: UUID
    public var evidenceType: String // plannedLoad, recentSleep, formTrend, scheduleSpacing, historicalPattern, ruleReference, other
    public var label: String
    public var valueText: String
    public var sourceEntityId: UUID?
    public var sourceVersion: Int?
    public var weight: Double?
    public var createdAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        recommendationId: RecommendationId,
        evidenceType: String,
        label: String,
        valueText: String,
        sourceEntityId: UUID? = nil,
        sourceVersion: Int? = nil,
        weight: Double? = nil,
        createdAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        if let w = weight { precondition((0...1).contains(w), "weight must be 0-1 (v1.3 Section 12.2)") }
        self.id = id
        self.recommendationId = recommendationId.rawValue
        self.evidenceType = evidenceType
        self.label = label
        self.valueText = valueText
        self.sourceEntityId = sourceEntityId
        self.sourceVersion = sourceVersion
        self.weight = weight
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - RecommendationResponse (v1.3 Section 12.3)

@Model
public final class RecommendationResponse {
    @Attribute(.unique) public var id: UUID
    public var recommendationId: UUID
    public var actorId: UUID
    public var responseType: RecommendationResponseType
    public var note: String?
    public var createdAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        recommendationId: RecommendationId,
        actorId: ActorId,
        responseType: RecommendationResponseType,
        note: String? = nil,
        createdAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        if let n = note { precondition(n.count <= 500, "note must be 0-500 characters (v1.3 Section 12.3)") }
        self.id = id
        self.recommendationId = recommendationId.rawValue
        self.actorId = actorId.rawValue
        self.responseType = responseType
        self.note = note
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - Domain events (v1.3 Section 16)

public struct RecommendationGenerated: DomainEvent {
    public static let eventName = "decisionSupport.recommendationGenerated"
    public let recommendationId: RecommendationId
    public let athleteId: AthleteId
    public let recommendationType: String
    public init(recommendationId: RecommendationId, athleteId: AthleteId, recommendationType: String) {
        self.recommendationId = recommendationId
        self.athleteId = athleteId
        self.recommendationType = recommendationType
    }
}

public struct RecommendationResponded: DomainEvent {
    public static let eventName = "decisionSupport.recommendationResponded"
    public let recommendationId: RecommendationId
    public let actorId: ActorId
    public let responseType: RecommendationResponseType
    public init(recommendationId: RecommendationId, actorId: ActorId, responseType: RecommendationResponseType) {
        self.recommendationId = recommendationId
        self.actorId = actorId
        self.responseType = responseType
    }
}
