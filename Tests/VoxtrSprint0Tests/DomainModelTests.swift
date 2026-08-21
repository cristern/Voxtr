import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like PersistenceTests.swift, these exercise @Model types and
// therefore require the Xcode/macOS SwiftData runtime to actually run —
// written but not executed in this sandbox.

@Suite("Identifier and value types")
struct IdentifierTests {
    @Test("A generated identifier round-trips through its rawValue")
    func roundTrips() {
        let id = AthleteId()
        #expect(AthleteId(rawValue: id.rawValue) == id)
    }

    @Test("LocalDate parses and formats as YYYY-MM-DD")
    func localDateISOFormat() {
        let date = LocalDate(year: 2026, month: 3, day: 5)
        #expect(date.isoString == "2026-03-05")
        #expect(LocalDate(isoString: "2026-03-05") == date)
    }
}

@Suite("Planning domain model (v1.3)")
struct PlanningDomainModelTests {

    @Test("WeekPlan starts at revision 1 in draft status")
    func weekPlanDefaults() {
        let plan = WeekPlan(athleteId: AthleteId(), weekStart: LocalDate(year: 2026, month: 3, day: 2))
        #expect(plan.revision == 1)
        #expect(plan.status == .draft)
    }

    @Test("PlannedActivity may omit sport, duration and intensity")
    func plannedActivityOptionalFields() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(),
            athleteId: AthleteId(),
            activityType: .individualTraining,
            title: "Strength session",
            localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        #expect(activity.sportId == nil)
        #expect(activity.plannedDurationMinutes == nil)
    }

    /// Sport / Activity Identity domain foundation, Part 3/4: Sport-only
    /// (no Activity Name) is a valid identity — `title` is optional, and
    /// `sportId` alone satisfies `ActivityIdentity`'s canonical rule.
    @Test("PlannedActivity may be Sport-only, with no title at all")
    func plannedActivitySportOnlyIsValid() {
        let sportId = SportId()
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(),
            athleteId: AthleteId(),
            sportId: sportId,
            activityType: .teamTraining,
            title: nil,
            localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        #expect(activity.title == nil)
        #expect(activity.sportId == sportId.rawValue)
    }

    /// Whitespace-only input is treated as absent (the same rule
    /// `ActivityIdentity.normalizedName` enforces) — a whitespace-only
    /// title with a Sport present is still valid (Sport alone satisfies
    /// identity), and the stored title is normalized to `nil`, never
    /// persisted as a blank string.
    @Test("A whitespace-only title normalizes to nil when a Sport is present")
    func plannedActivityWhitespaceOnlyTitleNormalizesToNil() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(),
            athleteId: AthleteId(),
            sportId: SportId(),
            activityType: .teamTraining,
            title: "   ",
            localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        #expect(activity.title == nil)
    }

    @Test("PlanningDecision requires resultingRevision exactly when accepted")
    func planningDecisionAcceptedInvariant() {
        let decision = PlanningDecision(
            weekPlanId: WeekPlanId(),
            baseRevision: 1,
            resultingRevision: 2,
            authorId: ActorId(),
            decisionType: .commitWeek,
            accepted: true
        )
        #expect(decision.resultingRevision == 2)
    }
}

@Suite("Training domain model (v1.3)")
struct TrainingDomainModelTests {

    @Test("LoggedActivity carries a traceability-only planned activity ID")
    func loggedActivityTraceability() {
        let plannedId = PlannedActivityId()
        let logged = LoggedActivity(
            athleteId: AthleteId(),
            plannedActivityId: plannedId,
            activityType: .match,
            title: "Saturday match",
            startedAt: .now,
            durationMinutes: 90,
            status: .completed,
            perceivedExertion: 8,
            source: "planned"
        )
        #expect(logged.plannedActivityId == plannedId.rawValue)
    }

    /// Sport / Activity Identity domain foundation, Part 7: the domain
    /// model must support a Sport-only `LoggedActivity` (no Activity
    /// Name at all) — future unplanned logging/External Sources must be
    /// able to supply `SportId` directly without a title heuristic.
    @Test("LoggedActivity may be Sport-only, with no title at all")
    func loggedActivitySportOnlyIsValid() {
        let sportId = SportId()
        let logged = LoggedActivity(
            athleteId: AthleteId(),
            sportId: sportId,
            activityType: .individualTraining,
            title: nil,
            startedAt: .now,
            durationMinutes: 45,
            status: .completed,
            source: "manual"
        )
        #expect(logged.title == nil)
        #expect(logged.sportId == sportId.rawValue)
    }

    /// ActivityType migration: `strength`/`conditioning` are real,
    /// independently persistable cases replacing `physicalTraining` —
    /// round-trips through `LoggedActivity` exactly like every other
    /// case.
    @Test("LoggedActivity persists the new strength and conditioning ActivityType cases")
    func loggedActivityStrengthAndConditioningCases() {
        let strength = LoggedActivity(
            athleteId: AthleteId(), activityType: .strength, title: "Gym",
            startedAt: .now, durationMinutes: 60, status: .completed, source: "manual"
        )
        let conditioning = LoggedActivity(
            athleteId: AthleteId(), activityType: .conditioning, title: "Track",
            startedAt: .now, durationMinutes: 30, status: .completed, source: "manual"
        )
        #expect(strength.activityType == .strength)
        #expect(conditioning.activityType == .conditioning)
    }

    /// ActivityType backward compatibility: `physicalTraining` remains
    /// readable from historical persisted raw strings, while `selectableCases`
    /// excludes `physicalTraining` so it cannot be selected for new activity input.
    @Test("ActivityType physicalTraining decodes for historical rows and is excluded from selectableCases")
    func physicalTrainingRawValueDecodesAndIsExcludedFromSelectableCases() {
        #expect(ActivityType(rawValue: "physicalTraining") == .physicalTraining)
        #expect(ActivityType(rawValue: "strength") == .strength)
        #expect(ActivityType(rawValue: "conditioning") == .conditioning)
        #expect(!ActivityType.selectableCases.contains(.physicalTraining))
        #expect(ActivityType.selectableCases.count == 9)
    }
}

/// Sport / Activity Identity domain foundation: the ONE canonical
/// validation rule every activity-shaped mutation boundary shares. Pure
/// function tests — no persistence needed.
@Suite("ActivityIdentity canonical validation")
struct ActivityIdentityTests {
    @Test("A non-blank name alone is valid")
    func nameAloneIsValid() {
        #expect(ActivityIdentity.isValid(normalizedName: "Football practice", sportId: nil))
    }

    @Test("A Sport alone, with no name, is valid")
    func sportAloneIsValid() {
        #expect(ActivityIdentity.isValid(normalizedName: nil, sportId: SportId()))
    }

    @Test("Both a name and a Sport together are valid")
    func bothIsValid() {
        #expect(ActivityIdentity.isValid(normalizedName: "Football practice", sportId: SportId()))
    }

    @Test("Neither a name nor a Sport is invalid")
    func neitherIsInvalid() {
        #expect(!ActivityIdentity.isValid(normalizedName: nil, sportId: nil))
    }

    @Test("Whitespace-only name normalizes to nil, and with no Sport is invalid")
    func whitespaceOnlyNameWithNoSportIsInvalid() {
        #expect(ActivityIdentity.normalizedName("   ") == nil)
        #expect(!ActivityIdentity.isValid(normalizedName: ActivityIdentity.normalizedName("   "), sportId: nil))
    }

    @Test("normalizedName trims surrounding whitespace from a real name")
    func normalizedNameTrimsWhitespace() {
        #expect(ActivityIdentity.normalizedName("  Football practice  ") == "Football practice")
    }

    @Test("validate(name:sportId:) throws missingIdentity when neither is present")
    func validateThrowsWhenBothAbsent() {
        #expect(throws: ActivityIdentityError.missingIdentity) {
            try ActivityIdentity.validate(name: nil, sportId: nil)
        }
        #expect(throws: ActivityIdentityError.missingIdentity) {
            try ActivityIdentity.validate(name: "   ", sportId: nil)
        }
    }

    @Test("validate(name:sportId:) succeeds when a name or a Sport (or both) is present")
    func validateSucceedsWhenEitherIsPresent() throws {
        try ActivityIdentity.validate(name: "Football practice", sportId: nil)
        try ActivityIdentity.validate(name: nil, sportId: SportId())
        try ActivityIdentity.validate(name: "Football practice", sportId: SportId())
    }
}

@Suite("ActivityLabelResolver primary activity label resolution")
struct ActivityLabelResolverTests {
    private static let footballId = SportId(rawValue: UUID(uuidString: "9E3F6E9E-2B7A-4A0B-8C1D-000000000001")!)

    @Test("1. Name + Sport -> Activity Name wins")
    @MainActor
    func nameAndSportReturnsName() {
        let resolver = ActivityLabelResolver()
        let result = resolver.primaryLabel(name: "Football Practice", sportId: Self.footballId)
        #expect(result == "Football Practice")
    }

    @Test("2. Name only -> Activity Name")
    @MainActor
    func nameOnlyReturnsName() {
        let resolver = ActivityLabelResolver()
        let result = resolver.primaryLabel(name: "Morning Run", sportId: nil)
        #expect(result == "Morning Run")
    }

    @Test("3. Sport only -> Canonical Sport display name")
    @MainActor
    func sportOnlyReturnsSportDisplayName() {
        let resolver = ActivityLabelResolver(customSportLookup: { id in
            id == Self.footballId ? "Football" : nil
        })
        let result = resolver.primaryLabel(name: nil, sportId: Self.footballId)
        #expect(result == "Football")
    }

    @Test("4. Whitespace-only Name + Sport -> Canonical Sport display name")
    @MainActor
    func whitespaceNameAndSportReturnsSportDisplayName() {
        let resolver = ActivityLabelResolver(customSportLookup: { id in
            id == Self.footballId ? "Football" : nil
        })
        let result = resolver.primaryLabel(name: "   \n\t  ", sportId: Self.footballId)
        #expect(result == "Football")
    }

    @Test("5. ActivityType is never used as primary label fallback")
    @MainActor
    func activityTypeIsNeverUsedAsFallback() {
        let resolver = ActivityLabelResolver()
        let resultNoSport = resolver.primaryLabel(name: nil, sportId: nil)
        #expect(resultNoSport != ActivityType.strength.displayName)
        #expect(resultNoSport != ActivityType.teamTraining.displayName)
        #expect(resultNoSport != ActivityType.strength.rawValue)
        #expect(resultNoSport == "Activity")
    }

    @Test("6. Sport resolution uses stable SportId, not title/string matching")
    @MainActor
    func sportResolutionUsesStableSportId() {
        let customSportId = SportId()
        let resolver = ActivityLabelResolver(customSportLookup: { id in
            if id == customSportId {
                return "Custom Sport"
            }
            return nil
        })
        let result = resolver.primaryLabel(name: nil, sportId: customSportId)
        #expect(result == "Custom Sport")
    }

    @Test("7. Corrupted/missing SportId fallback behavior")
    @MainActor
    func missingSportReferenceFallback() {
        let unknownSportId = SportId()
        let resolver = ActivityLabelResolver()
        let result = resolver.primaryLabel(name: nil, sportId: unknownSportId)
        #expect(result == "Activity")
    }

    @Test("Factual metadata is Sport and Type for named activities, otherwise Type")
    @MainActor
    func factualMetadataFollowsPrimaryIdentity() {
        let resolver = ActivityLabelResolver(customSportLookup: { id in
            id == Self.footballId ? "Football" : nil
        })

        #expect(
            resolver.metadataLabel(
                name: "Passing practice", sportId: Self.footballId, activityType: .teamTraining
            ) == "Football · Team training"
        )
        #expect(
            resolver.metadataLabel(
                name: nil, sportId: Self.footballId, activityType: .teamTraining
            ) == "Team training"
        )
        #expect(
            resolver.metadataLabel(name: "Run", sportId: nil, activityType: .conditioning)
                == "Conditioning"
        )
    }
}

/// Sport / Activity Identity domain foundation, Part 1/2: the
/// previously-dormant canonical `Sport` model, now activated —
/// persistence-backed via `SportRepository`.
@Suite("Sport canonical reference data", .serialized)
struct SportRepositoryTests {
    @Test("Seeding populates exactly the bounded canonical set (Football, Hockey, Bandy)")
    @MainActor
    func seedsCanonicalSet() throws {
        let controller = InMemoryPersistenceController(modelTypes: [Sport.self])
        let container = try controller.makeModelContainer()
        let repository = SportRepository(modelContext: container.mainContext)

        let seeded = try repository.seedCanonicalSportsIfNeeded()

        #expect(seeded.count == 3)
        #expect(Set(seeded.map(\.canonicalKey)) == ["football", "hockey", "bandy"])
    }

    @Test("Seeding twice never duplicates — idempotent by canonicalKey")
    @MainActor
    func seedingIsIdempotent() throws {
        let controller = InMemoryPersistenceController(modelTypes: [Sport.self])
        let container = try controller.makeModelContainer()
        let repository = SportRepository(modelContext: container.mainContext)

        try repository.seedCanonicalSportsIfNeeded()
        let secondSeed = try repository.seedCanonicalSportsIfNeeded()

        #expect(secondSeed.isEmpty)
        #expect(try repository.fetchAllSports().count == 3)
    }

    @Test("fetchSport(byId:) resolves stable identity, never by displayNameKey")
    @MainActor
    func fetchByStableId() throws {
        let controller = InMemoryPersistenceController(modelTypes: [Sport.self])
        let container = try controller.makeModelContainer()
        let repository = SportRepository(modelContext: container.mainContext)
        try repository.seedCanonicalSportsIfNeeded()

        let all = try repository.fetchAllSports()
        let football = try #require(all.first { $0.canonicalKey == "football" })

        let resolved = try repository.fetchSport(byId: football.sportId)
        #expect(resolved?.id == football.id)
        #expect(resolved?.canonicalKey == "football")
    }

    @Test("Seeded Sport identity is deterministic across separate seed calls/containers, never randomly generated")
    @MainActor
    func seededIdentityIsDeterministic() throws {
        let firstContainer = try InMemoryPersistenceController(modelTypes: [Sport.self]).makeModelContainer()
        let firstRepository = SportRepository(modelContext: firstContainer.mainContext)
        try firstRepository.seedCanonicalSportsIfNeeded()
        let firstFootballId = try #require(try firstRepository.fetchAllSports().first { $0.canonicalKey == "football" }?.sportId)

        let secondContainer = try InMemoryPersistenceController(modelTypes: [Sport.self]).makeModelContainer()
        let secondRepository = SportRepository(modelContext: secondContainer.mainContext)
        try secondRepository.seedCanonicalSportsIfNeeded()
        let secondFootballId = try #require(try secondRepository.fetchAllSports().first { $0.canonicalKey == "football" }?.sportId)

        #expect(firstFootballId == secondFootballId)
    }

    @Test("fetchAllSports is ordered deterministically by sortOrder")
    @MainActor
    func fetchAllSportsIsOrdered() throws {
        let controller = InMemoryPersistenceController(modelTypes: [Sport.self])
        let container = try controller.makeModelContainer()
        let repository = SportRepository(modelContext: container.mainContext)
        try repository.seedCanonicalSportsIfNeeded()

        let all = try repository.fetchAllSports()
        #expect(all.map(\.canonicalKey) == ["football", "hockey", "bandy"])
    }
}

@Suite("AthleteProfile revision (v1.4)")
struct AthleteProfileRevisionTests {

    @Test("A new AthleteProfile starts at revision 1")
    func initialRevisionIsOne() {
        let profile = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .sharedOwnership
        )
        #expect(profile.revision == 1)
    }

    @Test("A successful mutation increments revision by exactly 1 and the event carries the resulting revision")
    func successfulMutationIncrementsRevision() throws {
        let profile = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .sharedOwnership
        )
        let event = try profile.applyMutation(expectedRevision: 1, changedFields: ["preferredName"]) {
            $0.preferredName = "Jonte"
        }
        #expect(profile.revision == 2)
        #expect(event.revision == 2)
        #expect(profile.preferredName == "Jonte")
    }

    @Test("Two sequential successful mutations each increment by exactly 1")
    func sequentialMutationsIncrementOneAtATime() throws {
        let profile = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .sharedOwnership
        )
        try profile.applyMutation(expectedRevision: 1, changedFields: ["preferredName"]) { $0.preferredName = "Jonte" }
        try profile.applyMutation(expectedRevision: 2, changedFields: ["developmentStage"]) { $0.developmentStage = .guidedIndependence }
        #expect(profile.revision == 3)
    }

    @Test("A stale expectedRevision is rejected as a conflict, and the profile is left unchanged")
    func staleWriteIsRejected() {
        let profile = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .sharedOwnership
        )
        // Simulate another device/guardian committing first.
        try? profile.applyMutation(expectedRevision: 1, changedFields: ["preferredName"]) { $0.preferredName = "Jonte" }
        #expect(profile.revision == 2)

        // This caller is still working off revision 1 — stale.
        #expect(throws: AthleteProfileConflictError.staleRevision(expected: 1, actual: 2)) {
            try profile.applyMutation(expectedRevision: 1, changedFields: ["givenName"]) { $0.givenName = "Should not apply" }
        }
        // Rejected mutation must not have been applied.
        #expect(profile.givenName == "Jonas")
        #expect(profile.revision == 2)
    }
}


struct ReflectionDomainModelTests {

    @Test("ActivityReflection requires at least one numeric or text response")
    func reflectionRequiresContent() {
        let reflection = ActivityReflection(
            athleteId: AthleteId(),
            loggedActivityId: LoggedActivityId(),
            authorId: ActorId(),
            visibility: .sharedWithGuardians,
            energy: 4
        )
        #expect(reflection.energy == 4)
    }

    @Test("ParentObservation cannot be privateToAthlete")
    func parentObservationVisibilityConstraint() {
        let observation = ParentObservation(
            athleteId: AthleteId(),
            authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 3, day: 3),
            text: "Looked tired after the match",
            visibility: .summaryOnly
        )
        #expect(observation.visibility == .summaryOnly)
    }
}
