import Foundation

/// v1.3 Section 3 lists exactly these as strongly-typed shared
/// identifiers. Every other entity's own `id` field is a plain UUID
/// (per each entity's own field table) — do not add a typed ID for
/// anything not in this list without a document revision.
public struct Identifier<Tag>: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public enum AthleteTag {}
public typealias AthleteId = Identifier<AthleteTag>

public enum ActorTag {}
/// v1.3 Section 18: "ActorId references WorkspaceParticipant; system-generated
/// operations use a reserved SystemActorId value."
public typealias ActorId = Identifier<ActorTag>

public enum WorkspaceTag {}
public typealias WorkspaceId = Identifier<WorkspaceTag>

public enum SportTag {}
public typealias SportId = Identifier<SportTag>

public enum ActivityCategoryTag {}
public typealias ActivityCategoryId = Identifier<ActivityCategoryTag>

public enum WeekPlanTag {}
public typealias WeekPlanId = Identifier<WeekPlanTag>

public enum PlannedActivityTag {}
public typealias PlannedActivityId = Identifier<PlannedActivityTag>

public enum LoggedActivityTag {}
public typealias LoggedActivityId = Identifier<LoggedActivityTag>

public enum ReflectionTag {}
public typealias ReflectionId = Identifier<ReflectionTag>

public enum GoalTag {}
public typealias GoalId = Identifier<GoalTag>

public enum RecommendationTag {}
public typealias RecommendationId = Identifier<RecommendationTag>

/// v1.3 Section 3: "String wrapper. Opaque platform account identifier;
/// never used as email." Deliberately NOT built on the UUID-based
/// `Identifier<Tag>` generic — its representation is genuinely different.
public struct AccountId: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// v1.3 Section 18: reserved value for system-generated operations
/// (e.g. automated recalculation), as opposed to a human
/// WorkspaceParticipant acting.
public extension ActorId {
    static let system = ActorId(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
}
