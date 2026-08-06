import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

// MARK: - AthleteProfile (v1.3 Section 6.1)

/// Canonical identity and development configuration for one athlete.
///
/// `revision` (Domain & Data Model v1.4 — resolves the v1.3 gap flagged
/// against Section 16's AthleteProfileUpdated payload): required, starts
/// at 1, used for optimistic concurrency the same way WeekPlan.revision
/// is (v1.3 Section 8.1/DDM-009). `private(set)` is deliberate — the only
/// sanctioned way to change it is `applyMutation(expectedRevision:...)`
/// below; UI and external callers cannot set it directly, including at
/// construction (there is no `revision:` init parameter — every new
/// profile starts at 1, full stop).
@Model
public final class AthleteProfile {
    @Attribute(.unique) public var id: UUID
    public var workspaceId: UUID
    public var givenName: String
    public var familyName: String?
    public var preferredName: String?
    // TestFlight crash fix: `birthDate` was previously stored directly
    // as `LocalDate` — a custom-`Codable` struct — on this `@Model`.
    // SwiftData's own internal decoder (`CompositeSingleValueDecoding`,
    // visible in the crash trace) does not read that value back through
    // `LocalDate`'s own `Decodable` conformance the way it was written;
    // reading `.birthDate` on an existing, persisted row triggers a
    // fatal, uncatchable runtime trap (`swift_dynamicCastFailure` →
    // `swift::fatalError` → `abort()`) inside SwiftData's own private
    // implementation — not a throwable `DecodingError`, so no
    // `do`/`catch` in `LocalDate.init(from:)` or here could ever
    // intercept it. This is the exact same storage-shape issue already
    // solved elsewhere in this codebase (see `WeekPlan.weekStart`,
    // `PlannedActivity.localDate`, `RecurringPlannedActivity`'s own
    // effective-date fields) — stored as a plain ISO date `String`,
    // which SwiftData handles as a native, unambiguous column type, with
    // a computed `LocalDate` wrapper below providing the same public API
    // every existing caller already uses. See `AppSchemaVersioning.swift`
    // (`AppSchemaV6`) for the migration this storage change required.
    private var birthDateRaw: String = "1900-01-01"
    public var timeZoneId: TimeZoneId
    public var developmentStage: DevelopmentStage
    public var avatarAssetKey: String?
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int
    public private(set) var revision: Int

    public init(
        id: AthleteId = AthleteId(),
        workspaceId: WorkspaceId,
        givenName: String,
        familyName: String? = nil,
        preferredName: String? = nil,
        birthDate: LocalDate,
        timeZoneId: TimeZoneId,
        developmentStage: DevelopmentStage,
        avatarAssetKey: String? = nil,
        isArchived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition((1...80).contains(givenName.count), "givenName must be 1-80 characters (v1.3 Section 6.1)")
        self.id = id.rawValue
        self.workspaceId = workspaceId.rawValue
        self.givenName = givenName
        self.familyName = familyName
        self.preferredName = preferredName
        self.birthDateRaw = birthDate.isoString
        self.timeZoneId = timeZoneId
        self.developmentStage = developmentStage
        self.avatarAssetKey = avatarAssetKey
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
        self.revision = 1
    }

    public var athleteId: AthleteId { AthleteId(rawValue: id) }

    /// Existing rows migrated from before this fix (`AppSchemaV5` and
    /// earlier) have no recoverable prior value — the crash this fixes
    /// happens inside SwiftData's own decoder, before any application
    /// code (including a migration's `willMigrate`) could safely read
    /// the old value; see `AppSchemaVersioning.swift`'s `AppSchemaV6`
    /// migration for exactly what a migrated row's `birthDate` becomes,
    /// and why. `LocalDate(isoString:)` returning `nil` here (which
    /// should not happen for any row written by this or a later
    /// version) falls back to the same placeholder used by that
    /// migration, rather than crashing.
    public var birthDate: LocalDate {
        get { LocalDate(isoString: birthDateRaw) ?? Self.unknownBirthDatePlaceholder }
        set { birthDateRaw = newValue.isoString }
    }

    /// A deliberately implausible date for a youth athlete (not `1970-
    /// 01-01`, which could be mistaken for a real, if unlikely, value) —
    /// signals "needs re-entry," both here and in
    /// `AppSchemaVersioning.swift`'s migration, which is the only other
    /// place this exact value is written.
    static let unknownBirthDatePlaceholder = LocalDate(year: 1900, month: 1, day: 1)
}

// MARK: - AthleteProfile mutation API (Domain & Data Model v1.4)

/// Thrown when a caller's `expectedRevision` no longer matches the
/// profile's persisted revision — i.e. someone else (another device,
/// another guardian) mutated it first. Per v1.4's explicit rule: this is
/// surfaced as a conflict, never silently resolved with last-write-wins.
public enum AthleteProfileConflictError: Error, Sendable, Equatable {
    case staleRevision(expected: Int, actual: Int)
}

public extension AthleteProfile {
    /// The ONLY sanctioned way to mutate a persisted AthleteProfile.
    ///
    /// `expectedRevision` must be the revision the caller last read. If it
    /// no longer matches `self.revision` (someone else mutated first),
    /// this throws `AthleteProfileConflictError.staleRevision` and leaves
    /// the profile completely untouched — no partial mutation, no
    /// silent overwrite.
    ///
    /// On success, `mutate` is applied and `revision` is incremented by
    /// exactly 1 in the same call, before this method returns — there is
    /// no window where one changes without the other. Both live on the
    /// same in-memory object and are persisted together by the caller's
    /// single `context.save()`, which is what makes the update atomic:
    /// SwiftData/CloudKit has no partial-object save.
    ///
    /// Returns the event to publish; its `revision` is read from `self`
    /// AFTER incrementing, so it always reflects the resulting persisted
    /// value, never the caller's stale input.
    @discardableResult
    func applyMutation(
        expectedRevision: Int,
        changedFields: [String],
        mutate: (AthleteProfile) -> Void
    ) throws -> AthleteProfileUpdated {
        guard revision == expectedRevision else {
            throw AthleteProfileConflictError.staleRevision(expected: expectedRevision, actual: revision)
        }
        mutate(self)
        revision += 1
        updatedAt = .now
        return AthleteProfileUpdated(athleteId: athleteId, changedFields: changedFields, revision: revision)
    }
}

// MARK: - AthleteSettings (v1.3 Section 6.2)

/// Athlete-specific product behaviour, distinct from global app
/// preferences (see VoxtrSettings.AppPreference).
@Model
public final class AthleteSettings {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var weekStartsOn: Int
    public var defaultReflectionVisibility: VisibilityPolicy
    public var preferredUnits: String
    public var morningBriefEnabled: Bool
    public var eveningCheckOutEnabled: Bool
    public var weeklyReviewDay: Int
    public var weeklyReviewLocalTime: LocalTime?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        athleteId: AthleteId,
        weekStartsOn: Int,
        defaultReflectionVisibility: VisibilityPolicy,
        preferredUnits: String = "metric",
        morningBriefEnabled: Bool,
        eveningCheckOutEnabled: Bool,
        weeklyReviewDay: Int,
        weeklyReviewLocalTime: LocalTime? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition((1...7).contains(weekStartsOn), "weekStartsOn must be 1-7 (v1.3 Section 6.2)")
        precondition((1...7).contains(weeklyReviewDay), "weeklyReviewDay must be 1-7 (v1.3 Section 6.2)")
        self.id = id
        self.athleteId = athleteId.rawValue
        self.weekStartsOn = weekStartsOn
        self.defaultReflectionVisibility = defaultReflectionVisibility
        self.preferredUnits = preferredUnits
        self.morningBriefEnabled = morningBriefEnabled
        self.eveningCheckOutEnabled = eveningCheckOutEnabled
        self.weeklyReviewDay = weeklyReviewDay
        self.weeklyReviewLocalTime = weeklyReviewLocalTime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - AthleteSportParticipation (v1.3 Section 6.3)

/// Athlete-specific relationship to a Sport, without making Sport
/// athlete-owned (Sport stays Core Reference Data; this stores only
/// SportId).
@Model
public final class AthleteSportParticipation {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var sportId: UUID
    public var displayLabel: String?
    public var teamName: String?
    public var startedOn: LocalDate?
    public var endedOn: LocalDate?
    public var isPrimary: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        athleteId: AthleteId,
        sportId: SportId,
        displayLabel: String? = nil,
        teamName: String? = nil,
        startedOn: LocalDate? = nil,
        endedOn: LocalDate? = nil,
        isPrimary: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        if let started = startedOn, let ended = endedOn {
            precondition(!(ended < started), "endedOn must not precede startedOn (v1.3 Section 6.3)")
        }
        self.id = id
        self.athleteId = athleteId.rawValue
        self.sportId = sportId.rawValue
        self.displayLabel = displayLabel
        self.teamName = teamName
        self.startedOn = startedOn
        self.endedOn = endedOn
        self.isPrimary = isPrimary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - Domain events (v1.3 Section 6.1, Section 16)

public struct AthleteProfileCreated: DomainEvent {
    public static let eventName = "athlete.athleteProfileCreated"
    public let athleteId: AthleteId
    public init(athleteId: AthleteId) { self.athleteId = athleteId }
}

public struct AthleteProfileUpdated: DomainEvent {
    public static let eventName = "athlete.athleteProfileUpdated"
    public let athleteId: AthleteId
    public let changedFields: [String]
    /// The resulting PERSISTED revision after the mutation (v1.4) — always
    /// constructed via `AthleteProfile.applyMutation`, never set by a
    /// caller from a value it computed itself.
    public let revision: Int
    public init(athleteId: AthleteId, changedFields: [String], revision: Int) {
        self.athleteId = athleteId
        self.changedFields = changedFields
        self.revision = revision
    }
}

public struct AthleteArchived: DomainEvent {
    public static let eventName = "athlete.athleteArchived"
    public let athleteId: AthleteId
    public init(athleteId: AthleteId) { self.athleteId = athleteId }
}
