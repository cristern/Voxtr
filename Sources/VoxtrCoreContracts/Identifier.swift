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

/// Added for Recurring Planned Activities — a new domain concept this
/// work package introduces, following the same pattern as every other
/// typed ID above.
public enum RecurringPlannedActivityTag {}
public typealias RecurringPlannedActivityId = Identifier<RecurringPlannedActivityTag>

public enum LoggedActivityTag {}
public typealias LoggedActivityId = Identifier<LoggedActivityTag>

public enum ReflectionTag {}
public typealias ReflectionId = Identifier<ReflectionTag>

public enum GoalTag {}
public typealias GoalId = Identifier<GoalTag>

public enum RecommendationTag {}
public typealias RecommendationId = Identifier<RecommendationTag>

/// Notifications V1 Activity Reminder Foundation: identifies one
/// persisted `ActivityReminder` — the reminder intent for a single
/// concrete `PlannedActivity` — the same stable-typed-ID pattern every
/// other cross-domain-referenceable entity above already follows. Not
/// in the v1.3 Domain & Data Model's own typed-ID list (that document
/// predates this concept), but follows this file's own established
/// convention for any entity another domain needs to address by stable
/// identity rather than title/date matching.
public enum ActivityReminderTag {}
public typealias ActivityReminderId = Identifier<ActivityReminderTag>

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

/// S1.1 DECISION: CloudKit account resolution doesn't exist until a
/// later sprint, but `ParentProfile.accountId`, `FamilyWorkspace.
/// technicalOwnerAccountId`, and `WorkspaceParticipant.accountId` are
/// all required, non-optional `AccountId` fields per v1.3. Rather than
/// generating a per-install random surrogate identity (explicitly
/// rejected), every account-scoped field created in Sprint 1 uses this
/// single, well-known, documented sentinel. This is NOT a real account
/// identifier and must not be treated as one anywhere — it exists so the
/// required field can be populated without inventing an identity.
/// Replacing it with real iCloud account identifiers is real migration
/// work for whichever sprint introduces CloudKit, not a cosmetic rename.
public extension AccountId {
    static let pending = AccountId(rawValue: "pending-account-id")
}
