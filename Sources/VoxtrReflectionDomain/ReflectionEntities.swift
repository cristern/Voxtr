import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

// MARK: - ActivityReflection (v1.3 Section 10.1 / DDM-004, DDM-007)

@Model
public final class ActivityReflection {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var loggedActivityId: UUID
    public var authorId: UUID
    public var visibility: VisibilityPolicy
    public var bodyFeeling: Int?
    public var energy: Int?
    public var satisfaction: Int?
    public var perceivedExertion: Int?
    public var mostSatisfiedWith: String?
    public var learningNote: String?
    public var nextTimeNote: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: ReflectionId = ReflectionId(),
        athleteId: AthleteId,
        loggedActivityId: LoggedActivityId,
        authorId: ActorId,
        visibility: VisibilityPolicy,
        bodyFeeling: Int? = nil,
        energy: Int? = nil,
        satisfaction: Int? = nil,
        perceivedExertion: Int? = nil,
        mostSatisfiedWith: String? = nil,
        learningNote: String? = nil,
        nextTimeNote: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        let hasNumeric = [bodyFeeling, energy, satisfaction, perceivedExertion].contains { $0 != nil }
        let hasText = [mostSatisfiedWith, learningNote, nextTimeNote].contains { ($0?.isEmpty ?? true) == false }
        precondition(hasNumeric || hasText, "At least one numeric or text response is required (v1.3 Section 10.1)")
        for field in [bodyFeeling, energy, satisfaction] {
            if let v = field { precondition((1...5).contains(v), "bodyFeeling/energy/satisfaction must be 1-5 (v1.3 Section 10.1)") }
        }
        if let rpe = perceivedExertion { precondition((1...10).contains(rpe), "perceivedExertion must be 1-10 (v1.3 Section 10.1)") }
        self.id = id.rawValue
        self.athleteId = athleteId.rawValue
        self.loggedActivityId = loggedActivityId.rawValue
        self.authorId = authorId.rawValue
        self.visibility = visibility
        self.bodyFeeling = bodyFeeling
        self.energy = energy
        self.satisfaction = satisfaction
        self.perceivedExertion = perceivedExertion
        self.mostSatisfiedWith = mostSatisfiedWith
        self.learningNote = learningNote
        self.nextTimeNote = nextTimeNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var reflectionId: ReflectionId { ReflectionId(rawValue: id) }
}

// MARK: - DailyStatus (v1.3 Section 10.2)

@Model
public final class DailyStatus {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var localDate: LocalDate
    public var sleepDurationMinutes: Int?
    public var sleepQuality: Int?
    public var energy: Int?
    public var generalForm: Int?
    public var soreness: Int?
    /// v1.3 Section 10.2: "retained in Reflection until Mental domain exists."
    public var motivation: Int?
    public var illnessFlag: Bool
    public var note: String?
    public var visibility: VisibilityPolicy
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        athleteId: AthleteId,
        localDate: LocalDate,
        sleepDurationMinutes: Int? = nil,
        sleepQuality: Int? = nil,
        energy: Int? = nil,
        generalForm: Int? = nil,
        soreness: Int? = nil,
        motivation: Int? = nil,
        illnessFlag: Bool = false,
        note: String? = nil,
        visibility: VisibilityPolicy,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        if let sleep = sleepDurationMinutes { precondition((0...1440).contains(sleep), "sleepDurationMinutes must be 0-1440 (v1.3 Section 10.2)") }
        for field in [sleepQuality, energy, generalForm, soreness, motivation] {
            if let v = field { precondition((1...5).contains(v), "wellbeing scales must be 1-5 (v1.3 Section 18)") }
        }
        if let n = note { precondition(n.count <= 300, "note must be 0-300 characters (v1.3 Section 10.2)") }
        self.id = id
        self.athleteId = athleteId.rawValue
        self.localDate = localDate
        self.sleepDurationMinutes = sleepDurationMinutes
        self.sleepQuality = sleepQuality
        self.energy = energy
        self.generalForm = generalForm
        self.soreness = soreness
        self.motivation = motivation
        self.illnessFlag = illnessFlag
        self.note = note
        self.visibility = visibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - WeeklyReflection (v1.3 Section 10.3)

@Model
public final class WeeklyReflection {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var weekStart: LocalDate
    public var authorId: UUID
    public var overallSatisfaction: Int?
    public var loadFelt: Int?
    public var whatWorked: String?
    public var whatWasDifficult: String?
    public var learning: String?
    public var nextWeekConsideration: String?
    public var visibility: VisibilityPolicy
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        athleteId: AthleteId,
        weekStart: LocalDate,
        authorId: ActorId,
        overallSatisfaction: Int? = nil,
        loadFelt: Int? = nil,
        whatWorked: String? = nil,
        whatWasDifficult: String? = nil,
        learning: String? = nil,
        nextWeekConsideration: String? = nil,
        visibility: VisibilityPolicy,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        for field in [overallSatisfaction, loadFelt] {
            if let v = field { precondition((1...5).contains(v), "overallSatisfaction/loadFelt must be 1-5 (v1.3 Section 10.3)") }
        }
        for text in [whatWorked, whatWasDifficult, learning, nextWeekConsideration] {
            if let t = text { precondition(t.count <= 1000, "free-text fields must be 0-1000 characters (v1.3 Section 10.3)") }
        }
        self.id = id
        self.athleteId = athleteId.rawValue
        self.weekStart = weekStart
        self.authorId = authorId.rawValue
        self.overallSatisfaction = overallSatisfaction
        self.loadFelt = loadFelt
        self.whatWorked = whatWorked
        self.whatWasDifficult = whatWasDifficult
        self.learning = learning
        self.nextWeekConsideration = nextWeekConsideration
        self.visibility = visibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - MonthlyReflection (v1.3 Section 10.4)

@Model
public final class MonthlyReflection {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var yearMonth: String // YYYY-MM
    public var authorId: UUID
    public var overallSatisfaction: Int?
    public var developmentSummary: String?
    public var loadComment: String?
    public var nextMonthFocus: String?
    public var visibility: VisibilityPolicy
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        athleteId: AthleteId,
        yearMonth: String,
        authorId: ActorId,
        overallSatisfaction: Int? = nil,
        developmentSummary: String? = nil,
        loadComment: String? = nil,
        nextMonthFocus: String? = nil,
        visibility: VisibilityPolicy,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        if let v = overallSatisfaction { precondition((1...5).contains(v), "overallSatisfaction must be 1-5 (v1.3 Section 10.4)") }
        if let d = developmentSummary { precondition(d.count <= 2000, "developmentSummary must be 0-2000 characters (v1.3 Section 10.4)") }
        if let n = nextMonthFocus { precondition(n.count <= 1000, "nextMonthFocus must be 0-1000 characters (v1.3 Section 10.4)") }
        self.id = id
        self.athleteId = athleteId.rawValue
        self.yearMonth = yearMonth
        self.authorId = authorId.rawValue
        self.overallSatisfaction = overallSatisfaction
        self.developmentSummary = developmentSummary
        self.loadComment = loadComment
        self.nextMonthFocus = nextMonthFocus
        self.visibility = visibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - ParentObservation (v1.3 Section 10.5)

@Model
public final class ParentObservation {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var authorId: UUID
    public var relatedLoggedActivityId: UUID?
    public var localDate: LocalDate
    public var text: String
    public var visibility: VisibilityPolicy
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        athleteId: AthleteId,
        authorId: ActorId,
        relatedLoggedActivityId: LoggedActivityId? = nil,
        localDate: LocalDate,
        text: String,
        visibility: VisibilityPolicy = .sharedWithGuardians,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition((1...1000).contains(text.count), "text must be 1-1000 characters (v1.3 Section 10.5)")
        precondition(visibility != .privateToAthlete, "privateToAthlete is not valid for parent-authored notes (v1.3 Section 10.5)")
        self.id = id
        self.athleteId = athleteId.rawValue
        self.authorId = authorId.rawValue
        self.relatedLoggedActivityId = relatedLoggedActivityId?.rawValue
        self.localDate = localDate
        self.text = text
        self.visibility = visibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - Domain events (v1.3 Section 10.1, 16)

public struct ReflectionRecorded: DomainEvent {
    public static let eventName = "reflection.reflectionRecorded"
    public let reflectionId: ReflectionId
    public let athleteId: AthleteId
    public let sourceType: String
    public let sourceId: UUID?
    public let visibility: VisibilityPolicy
    public init(reflectionId: ReflectionId, athleteId: AthleteId, sourceType: String, sourceId: UUID? = nil, visibility: VisibilityPolicy) {
        self.reflectionId = reflectionId
        self.athleteId = athleteId
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.visibility = visibility
    }
}

public struct ReflectionVisibilityChanged: DomainEvent {
    public static let eventName = "reflection.reflectionVisibilityChanged"
    public let reflectionId: ReflectionId
    public let athleteId: AthleteId
    public init(reflectionId: ReflectionId, athleteId: AthleteId) {
        self.reflectionId = reflectionId
        self.athleteId = athleteId
    }
}

public struct DailyStatusRecorded: DomainEvent {
    public static let eventName = "reflection.dailyStatusRecorded"
    public let athleteId: AthleteId
    public let localDate: LocalDate
    public let visibility: VisibilityPolicy
    public init(athleteId: AthleteId, localDate: LocalDate, visibility: VisibilityPolicy) {
        self.athleteId = athleteId
        self.localDate = localDate
        self.visibility = visibility
    }
}
