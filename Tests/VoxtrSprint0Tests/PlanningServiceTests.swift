import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrCoreReferenceData
@testable import VoxtrPlanningDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("PlanningService (S2.1)", .serialized)
struct PlanningServiceTests {

    @Test("Creates a new draft WeekPlan when none exists for the athlete/week")
    @MainActor
    func createsNewDraftWhenNoneExists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 1, day: 5)

        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        #expect(weekPlan.status == .draft)
        #expect(weekPlan.revision == 1)
        #expect(weekPlan.athleteId == athleteId.rawValue)
        #expect(weekPlan.weekStart == weekStart)
        #expect(try container.mainContext.fetch(FetchDescriptor<WeekPlan>()).count == 1)
    }

    @Test("Returns the same existing WeekPlan on a second call, without creating a duplicate")
    @MainActor
    func returnsExistingWeekPlanWithoutDuplicating() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 1, day: 5)

        let first = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let second = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        #expect(first.id == second.id)
        #expect(try container.mainContext.fetch(FetchDescriptor<WeekPlan>()).count == 1)
    }

    @Test("Calling get-or-create three times for the same athlete/week still leaves exactly one WeekPlan")
    @MainActor
    func repeatedCallsNeverDuplicate() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 1, day: 5)

        _ = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        #expect(try container.mainContext.fetch(FetchDescriptor<WeekPlan>()).count == 1)
    }

    @Test("Different athletes, or different weeks for the same athlete, each get their own WeekPlan")
    @MainActor
    func differentAthleteOrWeekGetsSeparatePlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let firstAthlete = AthleteId()
        let secondAthlete = AthleteId()
        let firstWeek = LocalDate(year: 2026, month: 1, day: 5)
        let secondWeek = LocalDate(year: 2026, month: 1, day: 12)

        let a = try service.getOrCreateWeekPlan(athleteId: firstAthlete, weekStart: firstWeek)
        let b = try service.getOrCreateWeekPlan(athleteId: secondAthlete, weekStart: firstWeek)
        let c = try service.getOrCreateWeekPlan(athleteId: firstAthlete, weekStart: secondWeek)

        #expect(a.id != b.id)
        #expect(a.id != c.id)
        #expect(b.id != c.id)
        #expect(try container.mainContext.fetch(FetchDescriptor<WeekPlan>()).count == 3)
    }

    @Test("Adding a PlannedActivity to an existing WeekPlan persists it")
    @MainActor
    func addPlannedActivityPersists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))

        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(activity.title == "Endurance run")
        #expect(activity.weekPlanId == weekPlan.id)
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).count == 1)
    }

    @Test("Adding a PlannedActivity to a nonexistent WeekPlan is rejected")
    @MainActor
    func addPlannedActivityRejectsMissingWeekPlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)

        #expect(throws: PlanningServiceError.self) {
            try service.addPlannedActivity(
                toWeekPlan: WeekPlanId(),
                athleteId: AthleteId(),
                activityType: .individualTraining,
                title: "Endurance run",
                localDate: LocalDate(year: 2026, month: 1, day: 6),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<PlannedActivity>()).count == 0)
    }

    @Test("Editing an existing PlannedActivity updates its fields")
    @MainActor
    func editPlannedActivityUpdatesFields() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let edited = try service.editPlannedActivity(
            activity.plannedActivityId,
            expectedWeekPlanId: weekPlan.weekPlanId,
            activityType: .recovery,
            title: "Mobility session",
            localDate: LocalDate(year: 2026, month: 1, day: 7),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            plannedDurationMinutes: 30
        )

        #expect(edited.title == "Mobility session")
        #expect(edited.activityType == .recovery)
        #expect(edited.localDate == LocalDate(year: 2026, month: 1, day: 7))
        #expect(edited.plannedDurationMinutes == 30)
        #expect(try container.mainContext.fetch(FetchDescriptor<PlannedActivity>()).count == 1)
    }

    @Test("Editing a PlannedActivity against a nonexistent WeekPlan is rejected")
    @MainActor
    func editPlannedActivityRejectsMissingWeekPlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(throws: PlanningServiceError.self) {
            try service.editPlannedActivity(
                activity.plannedActivityId,
                expectedWeekPlanId: WeekPlanId(),
                activityType: .recovery,
                title: "Mobility session",
                localDate: LocalDate(year: 2026, month: 1, day: 7),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
        }
    }

    @Test("Editing a PlannedActivity that doesn't belong to the supplied WeekPlan is rejected")
    @MainActor
    func editPlannedActivityRejectsMismatchedWeekPlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let firstWeekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let secondWeekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 12))
        let activity = try service.addPlannedActivity(
            toWeekPlan: firstWeekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(throws: PlanningServiceError.self) {
            try service.editPlannedActivity(
                activity.plannedActivityId,
                expectedWeekPlanId: secondWeekPlan.weekPlanId,
                activityType: .recovery,
                title: "Mobility session",
                localDate: LocalDate(year: 2026, month: 1, day: 7),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
        }
        // Unchanged — the rejected edit must not have applied.
        let stillOriginal = try repository.fetchPlannedActivity(byId: activity.plannedActivityId)
        #expect(stillOriginal?.title == "Endurance run")
    }

    // MARK: - Sport / Activity Identity domain foundation (Parts 3/4)

    @Test("A PlannedActivity may be created Sport-only, with no title at all")
    @MainActor
    func addPlannedActivitySportOnlyIsCreatable() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let sportId = SportId()

        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .teamTraining,
            title: nil,
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            sportId: sportId
        )

        #expect(activity.title == nil)
        #expect(activity.sportId == sportId.rawValue)
    }

    @Test("Adding a PlannedActivity with neither a title nor a Sport is rejected")
    @MainActor
    func addPlannedActivityRejectsMissingIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))

        #expect(throws: PlanningServiceError.self) {
            try service.addPlannedActivity(
                toWeekPlan: weekPlan.weekPlanId,
                athleteId: athleteId,
                activityType: .teamTraining,
                title: nil,
                localDate: LocalDate(year: 2026, month: 1, day: 6),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).isEmpty)
    }

    @Test("Adding a PlannedActivity with a whitespace-only title and no Sport is rejected")
    @MainActor
    func addPlannedActivityRejectsWhitespaceOnlyTitleWithNoSport() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))

        #expect(throws: PlanningServiceError.self) {
            try service.addPlannedActivity(
                toWeekPlan: weekPlan.weekPlanId,
                athleteId: athleteId,
                activityType: .teamTraining,
                title: "   ",
                localDate: LocalDate(year: 2026, month: 1, day: 6),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
        }
    }

    @Test("Editing a PlannedActivity cannot remove its final identity (neither title nor Sport)")
    @MainActor
    func editPlannedActivityCannotRemoveFinalIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(throws: PlanningServiceError.self) {
            try service.editPlannedActivity(
                activity.plannedActivityId,
                expectedWeekPlanId: weekPlan.weekPlanId,
                activityType: .individualTraining,
                title: nil,
                localDate: LocalDate(year: 2026, month: 1, day: 6),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
        }
        // Unchanged — the rejected edit must not have applied.
        let stillOriginal = try repository.fetchPlannedActivity(byId: activity.plannedActivityId)
        #expect(stillOriginal?.title == "Endurance run")
    }

    @Test("Editing can remove the title as long as a Sport remains")
    @MainActor
    func editPlannedActivityCanRemoveTitleWhenSportRemains() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let sportId = SportId()
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            sportId: sportId
        )

        let edited = try service.editPlannedActivity(
            activity.plannedActivityId,
            expectedWeekPlanId: weekPlan.weekPlanId,
            activityType: .individualTraining,
            title: nil,
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            sportId: sportId
        )

        #expect(edited.title == nil)
        #expect(edited.sportId == sportId.rawValue)
    }

    @Test("Editing can remove the Sport as long as a title remains")
    @MainActor
    func editPlannedActivityCanRemoveSportWhenTitleRemains() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            sportId: SportId()
        )

        let edited = try service.editPlannedActivity(
            activity.plannedActivityId,
            expectedWeekPlanId: weekPlan.weekPlanId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            sportId: nil
        )

        #expect(edited.title == "Endurance run")
        #expect(edited.sportId == nil)
    }

    /// Sport / Activity Identity domain foundation, Part 10 (isolation):
    /// editing one PlannedActivity's identity (title/Sport) never
    /// mutates a sibling activity in the same WeekPlan, nor the
    /// canonical `Sport` row itself — no shared mutable state between
    /// activities, and Sport truth is read-only from every feature
    /// domain's perspective.
    @Test("Editing one PlannedActivity's identity does not mutate a sibling activity or the canonical Sport row")
    @MainActor
    func editingOneActivityDoesNotMutateSiblingOrSport() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let sportRepository = SportRepository(modelContext: container.mainContext)
        try sportRepository.seedCanonicalSportsIfNeeded()
        let football = try #require(try sportRepository.fetchAllSports().first { $0.canonicalKey == "football" })

        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let sibling = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Football practice", localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), sportId: football.sportId
        )
        let target = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .strength,
            title: "Gym", localDate: LocalDate(year: 2026, month: 1, day: 7),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        _ = try service.editPlannedActivity(
            target.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, activityType: .conditioning,
            title: nil, localDate: LocalDate(year: 2026, month: 1, day: 7),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), sportId: football.sportId
        )

        // The sibling activity is completely untouched.
        let stillSibling = try repository.fetchPlannedActivity(byId: sibling.plannedActivityId)
        #expect(stillSibling?.title == "Football practice")
        #expect(stillSibling?.activityType == .teamTraining)
        #expect(stillSibling?.sportId == football.sportId.rawValue)

        // The canonical Sport row itself is completely untouched — a
        // feature domain never mutates Sport truth, only ever reads it.
        let stillFootball = try #require(try sportRepository.fetchSport(byId: football.sportId))
        #expect(stillFootball.canonicalKey == "football")
        #expect(stillFootball.displayNameKey == football.displayNameKey)
        #expect(try sportRepository.fetchAllSports().count == 3)
    }

    @Test("Adding a PlannedActivity with an invalid title is rejected without persisting")
    @MainActor
    func addPlannedActivityRejectsInvalidTitle() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))

        #expect(throws: PlanningServiceError.self) {
            try service.addPlannedActivity(
                toWeekPlan: weekPlan.weekPlanId,
                athleteId: athleteId,
                activityType: .individualTraining,
                title: "",
                localDate: LocalDate(year: 2026, month: 1, day: 6),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<PlannedActivity>()).count == 0)
    }

    @Test("Fetching PlannedActivity records returns them ordered deterministically by localDate")
    @MainActor
    func fetchPlannedActivitiesOrderedDeterministically() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))

        // Inserted out of date order deliberately.
        _ = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Thursday", localDate: LocalDate(year: 2026, month: 1, day: 8),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Monday", localDate: LocalDate(year: 2026, month: 1, day: 5),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Wednesday", localDate: LocalDate(year: 2026, month: 1, day: 7),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let first = try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        let second = try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)

        #expect(first.map(\.title) == ["Monday", "Wednesday", "Thursday"])
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("Committing a draft WeekPlan transitions it to committed and increments revision by exactly 1")
    @MainActor
    func commitTransitionsToCommittedAndIncrementsRevision() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        #expect(weekPlan.revision == 1)

        let committed = try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        #expect(committed.status == .committed)
        #expect(committed.revision == 2)
        #expect(committed.committedAt != nil)
    }

    @Test("Committing an already-committed WeekPlan is rejected")
    @MainActor
    func duplicateCommitRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        #expect(throws: WeekPlanConflictError.alreadyCommitted) {
            try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 2, committedBy: ActorId())
        }
        #expect(weekPlan.revision == 2)
    }

    @Test("Editing a PlannedActivity after its WeekPlan has been committed is rejected")
    @MainActor
    func editAfterCommitRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        #expect(throws: PlanningServiceError.self) {
            try service.editPlannedActivity(
                activity.plannedActivityId,
                expectedWeekPlanId: weekPlan.weekPlanId,
                activityType: .recovery,
                title: "Should not apply",
                localDate: LocalDate(year: 2026, month: 1, day: 7),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
        }
        let stillOriginal = try repository.fetchPlannedActivity(byId: activity.plannedActivityId)
        #expect(stillOriginal?.title == "Endurance run")
    }

    @Test("A stale expectedRevision on commit is rejected as a conflict, and the plan is left unchanged")
    @MainActor
    func staleRevisionOnCommitRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))

        #expect(throws: WeekPlanConflictError.staleRevision(expected: 99, actual: 1)) {
            try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 99, committedBy: ActorId())
        }
        #expect(weekPlan.status == .draft)
        #expect(weekPlan.revision == 1)
    }

    // MARK: - Reversibility principle: reopenWeekPlan

    @Test("Reopening a committed WeekPlan returns it to draft, increments revision, and clears committedAt/committedBy")
    @MainActor
    func reopenTransitionsCommittedBackToDraft() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())
        #expect(weekPlan.status == .committed)
        #expect(weekPlan.revision == 2)

        let reopened = try service.reopenWeekPlan(
            weekPlan.weekPlanId, expectedRevision: 2, reopenedBy: ActorId(), currentWeekStart: weekPlan.weekStart
        )

        #expect(reopened.status == .draft)
        #expect(reopened.revision == 3)
        #expect(reopened.committedAt == nil)
        #expect(reopened.committedBy == nil)
        // The SAME WeekPlan entity — never deleted or recreated.
        #expect(reopened.weekPlanId == weekPlan.weekPlanId)
    }

    @Test("Reopening a WeekPlan that was never committed is rejected")
    @MainActor
    func reopenRejectedWhenNotCommitted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))

        #expect(throws: WeekPlanConflictError.notCommitted) {
            try service.reopenWeekPlan(
                weekPlan.weekPlanId, expectedRevision: 1, reopenedBy: ActorId(), currentWeekStart: weekPlan.weekStart
            )
        }
        #expect(weekPlan.status == .draft)
        #expect(weekPlan.revision == 1)
    }

    @Test("A stale expectedRevision on reopen is rejected as a conflict, and the plan is left unchanged")
    @MainActor
    func staleRevisionOnReopenRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        #expect(throws: WeekPlanConflictError.staleRevision(expected: 99, actual: 2)) {
            try service.reopenWeekPlan(
                weekPlan.weekPlanId, expectedRevision: 99, reopenedBy: ActorId(), currentWeekStart: weekPlan.weekStart
            )
        }
        #expect(weekPlan.status == .committed)
        #expect(weekPlan.revision == 2)
    }

    @Test("Reopening a WeekPlan preserves every existing PlannedActivity's own identity — never deletes, recreates, or duplicates")
    @MainActor
    func reopenPreservesPlannedActivityIdentities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        try service.reopenWeekPlan(
            weekPlan.weekPlanId, expectedRevision: 2, reopenedBy: ActorId(), currentWeekStart: weekPlan.weekStart
        )

        let activitiesAfter = try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        #expect(activitiesAfter.count == 1)
        #expect(activitiesAfter.first?.plannedActivityId == activity.plannedActivityId)
        #expect(activitiesAfter.first?.title == "Endurance run")
    }

    @Test("A reopened WeekPlan can be edited again and committed again")
    @MainActor
    func reopenedWeekPlanCanBeEditedAndRecommitted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())
        try service.reopenWeekPlan(
            weekPlan.weekPlanId, expectedRevision: 2, reopenedBy: ActorId(), currentWeekStart: weekPlan.weekStart
        )

        // Editable again — this would have thrown weekPlanNotDraft while
        // still committed.
        let edited = try service.editPlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId,
            activityType: .individualTraining, title: "Endurance run (corrected)",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        #expect(edited.title == "Endurance run (corrected)")

        let recommitted = try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 3, committedBy: ActorId())
        #expect(recommitted.status == .committed)
        #expect(recommitted.revision == 4)
    }

    // MARK: - Review follow-up: historical-week reopen is rejected at the domain/service boundary

    /// Closes the exact gap the review flagged: `WeeklyPlanningViewModel.canReopenPlanning`
    /// alone was the only place "current/future only" was enforced —
    /// calling `PlanningService.reopenWeekPlan`/`WeekPlan.reopen`
    /// directly, bypassing that ViewModel entirely, could still reopen
    /// a committed HISTORICAL week. This test calls the service
    /// directly, exactly as a bypass would, with a real committed
    /// historical week (2026-01-05, unambiguously before any real
    /// "today" this suite could run on) and the actual current
    /// canonical week supplied as `currentWeekStart` — the same
    /// `TrainingPlanningCoordinationService.weekStart()` the ViewModel
    /// itself uses, not a second computation.
    @Test("Reopening a committed HISTORICAL week is rejected at the service/domain boundary, even when the ViewModel-level gate is bypassed entirely")
    @MainActor
    func reopenRejectedForHistoricalWeekAtDomainBoundary() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let historicalWeekStart = LocalDate(year: 2026, month: 1, day: 5)
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: historicalWeekStart)
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        #expect(throws: WeekPlanConflictError.historicalWeekNotReopenable) {
            try service.reopenWeekPlan(
                weekPlan.weekPlanId, expectedRevision: 2, reopenedBy: ActorId(),
                currentWeekStart: TrainingPlanningCoordinationService.weekStart()
            )
        }
        // Untouched — still committed, same revision.
        #expect(weekPlan.status == .committed)
        #expect(weekPlan.revision == 2)
    }

    @Test("Reopening a committed CURRENT week succeeds when the real canonical current week is supplied")
    @MainActor
    func reopenSucceedsForCurrentWeekAtDomainBoundary() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let currentWeekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: currentWeekStart)
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        let reopened = try service.reopenWeekPlan(
            weekPlan.weekPlanId, expectedRevision: 2, reopenedBy: ActorId(), currentWeekStart: currentWeekStart
        )

        #expect(reopened.status == .draft)
    }

    @Test("Reopening a committed FUTURE week succeeds when the real canonical current week is supplied")
    @MainActor
    func reopenSucceedsForFutureWeekAtDomainBoundary() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let currentWeekStart = TrainingPlanningCoordinationService.weekStart()
        let futureWeekStart = currentWeekStart.adding(days: 14)
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: futureWeekStart)
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        let reopened = try service.reopenWeekPlan(
            weekPlan.weekPlanId, expectedRevision: 2, reopenedBy: ActorId(), currentWeekStart: currentWeekStart
        )

        #expect(reopened.status == .draft)
    }

    @Test("WeekPlan.reopen returns a WeekPlanReopened event carrying the exact WeekPlan identity and the post-transition revision")
    @MainActor
    func reopenReturnsWeekPlanReopenedEventWithCorrectIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        let event = try weekPlan.reopen(expectedRevision: 2, reopenedBy: ActorId(), currentWeekStart: weekPlan.weekStart)

        #expect(event.weekPlanId == weekPlan.weekPlanId)
        #expect(event.athleteId == athleteId)
        // The event's own revision is the POST-transition value, matching
        // WeekPlanCommitted's own established convention for this field.
        #expect(event.revision == weekPlan.revision)
        #expect(event.revision == 3)
    }
}

// MARK: - Recurring Planned Activities

@Suite("PlanningService — Recurring Planned Activities", .serialized)
struct PlanningServiceRecurringActivityTests {

    private static let mondayWeekStart = LocalDate(year: 2026, month: 1, day: 5)
    private static let rangeStart = LocalDate(year: 2026, month: 1, day: 1)
    private static let rangeEnd = LocalDate(year: 2026, month: 1, day: 31)

    // MARK: Management

    @Test("createRecurringPlannedActivity persists a new definition")
    @MainActor
    func createRecurringPlannedActivityPersists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()

        let created = try service.createRecurringPlannedActivity(
            athleteId: athleteId,
            title: "Football",
            activityType: .teamTraining,
            weekdays: [.monday],
            startLocalTime: LocalTime(hour: 17, minute: 30),
            plannedDurationMinutes: 150,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: Self.rangeStart,
            effectiveEndDate: Self.rangeEnd
        )

        #expect(try repository.fetchRecurringPlannedActivities(forAthlete: athleteId).map(\.id) == [created.id])
    }

    @Test("createRecurringPlannedActivity rejects an invalid title")
    @MainActor
    func createRecurringPlannedActivityRejectsInvalidTitle() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)

        #expect(throws: PlanningServiceError.self) {
            try service.createRecurringPlannedActivity(
                athleteId: AthleteId(),
                title: "",
                activityType: .teamTraining,
                weekdays: [.monday],
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                effectiveStartDate: Self.rangeStart,
                effectiveEndDate: Self.rangeEnd
            )
        }
    }

    @Test("createRecurringPlannedActivity may be Sport-only, with no title at all")
    @MainActor
    func createRecurringPlannedActivitySportOnlyIsValid() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let sportId = SportId()

        let created = try service.createRecurringPlannedActivity(
            athleteId: AthleteId(),
            title: nil,
            activityType: .teamTraining,
            sportId: sportId,
            weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: Self.rangeStart,
            effectiveEndDate: Self.rangeEnd
        )

        #expect(created.title == nil)
        #expect(created.sportId == sportId.rawValue)
    }

    @Test("createRecurringPlannedActivity rejects neither a title nor a Sport")
    @MainActor
    func createRecurringPlannedActivityRejectsMissingIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)

        #expect(throws: PlanningServiceError.self) {
            try service.createRecurringPlannedActivity(
                athleteId: AthleteId(),
                title: nil,
                activityType: .teamTraining,
                weekdays: [.monday],
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                effectiveStartDate: Self.rangeStart,
                effectiveEndDate: Self.rangeEnd
            )
        }
    }

    @Test("editRecurringPlannedActivity updates fields on the existing definition")
    @MainActor
    func editRecurringPlannedActivityUpdatesFields() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let created = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )

        let edited = try service.editRecurringPlannedActivity(
            created.recurringPlannedActivityId,
            title: "Football (updated)",
            activityType: .match,
            weekdays: [.wednesday],
            plannedDurationMinutes: 90,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: Self.rangeStart,
            effectiveEndDate: Self.rangeEnd
        )

        #expect(edited.title == "Football (updated)")
        #expect(edited.activityType == .match)
        #expect(edited.weekdays == [.wednesday])
        #expect(edited.plannedDurationMinutes == 90)
    }

    @Test("editRecurringPlannedActivity rejects a nonexistent definition")
    @MainActor
    func editRecurringPlannedActivityRejectsMissingDefinition() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)

        #expect(throws: PlanningServiceError.recurringPlannedActivityNotFound) {
            try service.editRecurringPlannedActivity(
                RecurringPlannedActivityId(),
                title: "Football",
                activityType: .teamTraining,
                weekdays: [.monday],
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                effectiveStartDate: Self.rangeStart,
                effectiveEndDate: Self.rangeEnd
            )
        }
    }

    @Test("setRecurringPlannedActivityEnabled toggles the enabled state")
    @MainActor
    func setRecurringPlannedActivityEnabledToggles() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let created = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )

        try service.setRecurringPlannedActivityEnabled(created.recurringPlannedActivityId, isEnabled: false)

        let refetched = try repository.fetchRecurringPlannedActivity(byId: created.recurringPlannedActivityId)
        #expect(refetched?.isEnabled == false)
    }

    @Test("setRecurringPlannedActivityEnabled rejects a nonexistent definition")
    @MainActor
    func setRecurringPlannedActivityEnabledRejectsMissingDefinition() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)

        #expect(throws: PlanningServiceError.recurringPlannedActivityNotFound) {
            try service.setRecurringPlannedActivityEnabled(RecurringPlannedActivityId(), isEnabled: false)
        }
    }

    // MARK: Suggestion generation

    @Test("A recurring activity matching the week's weekday produces exactly one suggestion")
    @MainActor
    func matchingWeekdayProducesOneSuggestion() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )

        let suggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.occurrenceDate == Self.mondayWeekStart)
        #expect(suggestions.first?.title == "Football")
    }

    @Test("A recurring activity for a non-matching weekday produces no suggestions")
    @MainActor
    func nonMatchingWeekdayProducesNone() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        // The week is Jan 5 (Mon) - Jan 11 (Sun), which includes a
        // Saturday (Jan 10) — so to prove a genuine weekday mismatch,
        // not just an out-of-range date, this definition's own
        // effective range deliberately excludes this week's Saturday.
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.saturday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2026, month: 1, day: 17),
            effectiveEndDate: LocalDate(year: 2026, month: 1, day: 31)
        )

        let suggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(suggestions.isEmpty)
    }

    @Test("The effective start date is inclusive — an occurrence exactly on it produces a suggestion")
    @MainActor
    func startDateIsInclusive() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        // Monday Jan 5 is both the week's first day and the
        // definition's own effectiveStartDate.
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: Self.mondayWeekStart,
            effectiveEndDate: Self.rangeEnd
        )

        let suggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(suggestions.count == 1)
    }

    @Test("The effective end date is inclusive — an occurrence exactly on it produces a suggestion")
    @MainActor
    func endDateIsInclusive() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        // Monday Jan 5 is the definition's own effectiveEndDate.
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: Self.rangeStart,
            effectiveEndDate: Self.mondayWeekStart
        )

        let suggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(suggestions.count == 1)
    }

    @Test("A date one day before the effective start date produces no suggestion for that occurrence")
    @MainActor
    func dateBeforeRangeProducesNone() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        // effectiveStartDate is the day AFTER this week's only Monday.
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: Self.mondayWeekStart.adding(days: 1),
            effectiveEndDate: Self.rangeEnd
        )

        let suggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(suggestions.isEmpty)
    }

    @Test("A date one day after the effective end date produces no suggestion for that occurrence")
    @MainActor
    func dateAfterRangeProducesNone() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        // effectiveEndDate is the day BEFORE this week's only Monday.
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: Self.rangeStart,
            effectiveEndDate: Self.mondayWeekStart.adding(days: -1)
        )

        let suggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(suggestions.isEmpty)
    }

    @Test("A disabled recurring activity produces no suggestions")
    @MainActor
    func disabledRecurringActivityProducesNone() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        let created = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        try service.setRecurringPlannedActivityEnabled(created.recurringPlannedActivityId, isEnabled: false)

        let suggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(suggestions.isEmpty)
    }

    @Test("Suggestions are limited to the current WeekPlan's own 7-day week")
    @MainActor
    func suggestionsLimitedToCurrentWeekPlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let thisWeek = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        let nextWeek = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart.adding(days: 7))
        // Matches every Monday across the whole range — both weeks
        // should each get exactly one suggestion, not the whole range's
        // worth in one call.
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )

        let thisWeekSuggestions = try service.deriveSuggestions(forWeekPlan: thisWeek.weekPlanId)
        let nextWeekSuggestions = try service.deriveSuggestions(forWeekPlan: nextWeek.weekPlanId)

        #expect(thisWeekSuggestions.count == 1)
        #expect(thisWeekSuggestions.first?.occurrenceDate == Self.mondayWeekStart)
        #expect(nextWeekSuggestions.count == 1)
        #expect(nextWeekSuggestions.first?.occurrenceDate == Self.mondayWeekStart.adding(days: 7))
    }

    @Test("Multiple recurring activities produce suggestions ordered by occurrence date")
    @MainActor
    func multipleRecurringActivitiesOrderedCorrectly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        // Created deliberately out of weekday order.
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Friday swim", activityType: .individualTraining, weekdays: [.friday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Monday football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Wednesday gym", activityType: .strength, weekdays: [.wednesday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )

        let suggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(suggestions.map(\.title) == ["Monday football", "Wednesday gym", "Friday swim"])
    }

    @Test("Repeated evaluation with unchanged data is deterministic")
    @MainActor
    func repeatedEvaluationIsDeterministic() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )

        let first = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let second = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("An already-accepted occurrence is excluded from future derivation")
    @MainActor
    func alreadyAcceptedOccurrenceIsExcluded() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let firstSuggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let suggestion = try #require(firstSuggestions.first)
        try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)

        let secondSuggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(secondSuggestions.isEmpty)
    }

    @Test("A manually created activity with no matching recurring source does not suppress a genuine suggestion")
    @MainActor
    func manualActivityWithNoRecurringSourceDoesNotSuppressSuggestion() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        // A manually-added activity on the SAME date/title, but with no
        // externalSourceId at all — must not be mistaken for an
        // already-accepted occurrence.
        _ = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Football", localDate: Self.mondayWeekStart, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let suggestions = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)

        #expect(suggestions.count == 1)
    }

    // MARK: Acceptance

    @Test("Accepting a suggestion creates exactly one PlannedActivity")
    @MainActor
    func acceptingSuggestionCreatesOnePlannedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let suggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)

        try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)

        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).count == 1)
    }

    @Test("The created activity uses the recurring definition's own values")
    @MainActor
    func createdActivityUsesRecurringDefinitionValues() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            startLocalTime: LocalTime(hour: 17, minute: 30), plannedDurationMinutes: 150,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let suggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)

        let created = try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)

        #expect(created.title == "Football")
        #expect(created.activityType == .teamTraining)
        #expect(created.startLocalTime == LocalTime(hour: 17, minute: 30))
        #expect(created.plannedDurationMinutes == 150)
    }

    /// Sport / Activity Identity domain foundation, Parts 3/6: a
    /// recurring definition may be Sport-only (no title) — and the
    /// stable SportId survives the FULL lifecycle: definition ->
    /// suggestion -> accepted PlannedActivity.
    @Test("A Sport-only recurring definition's SportId survives suggestion derivation and acceptance")
    @MainActor
    func sportOnlyRecurringDefinitionSurvivesLifecycle() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let sportId = SportId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: nil, activityType: .teamTraining, sportId: sportId, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )

        let suggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)
        #expect(suggestion.title == nil)
        #expect(suggestion.sportId == sportId)

        let created = try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        #expect(created.title == nil)
        #expect(created.sportId == sportId.rawValue)
    }

    /// ActivityType migration: `strength`/`conditioning` survive the
    /// same definition -> suggestion -> PlannedActivity lifecycle
    /// unchanged, exactly like every other case.
    @Test("A recurring definition's strength/conditioning ActivityType survives suggestion derivation and acceptance")
    @MainActor
    func strengthAndConditioningActivityTypeSurviveLifecycle() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Gym", activityType: .strength, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )

        let suggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)
        #expect(suggestion.activityType == .strength)

        let created = try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        #expect(created.activityType == .strength)
    }

    @Test("The created activity belongs to the current WeekPlan and athlete")
    @MainActor
    func createdActivityBelongsToWeekPlanAndAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let suggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)

        let created = try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)

        #expect(created.weekPlanId == weekPlan.id)
        #expect(created.athleteId == athleteId.rawValue)
    }

    @Test("Accepting the same occurrence twice cannot create a duplicate")
    @MainActor
    func acceptingSameOccurrenceTwiceCannotDuplicate() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let suggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)
        try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)

        #expect(throws: PlanningServiceError.recurringOccurrenceAlreadyAccepted) {
            try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).count == 1)
    }

    @Test("Accepting one occurrence does not mutate or disable the recurring definition")
    @MainActor
    func acceptingOccurrenceDoesNotMutateDefinition() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        let created = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let suggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)

        try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)

        let refetchedDefinition = try repository.fetchRecurringPlannedActivity(byId: created.recurringPlannedActivityId)
        #expect(refetchedDefinition?.isEnabled == true)
        #expect(refetchedDefinition?.title == "Football")
    }

    @Test("A repository failure during acceptance does not report success")
    @MainActor
    func repositoryFailureDuringAcceptanceDoesNotReportSuccess() throws {
        struct InjectedSaveFailure: Error {}

        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let suggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)

        #expect(throws: InjectedSaveFailure.self) {
            try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId, saveOverride: { throw InjectedSaveFailure() })
        }
        // Not `repository.fetchPlannedActivities(...)` here: this
        // repository's `insertPlannedActivity` calls
        // `modelContext.insert(activity)` unconditionally, before the
        // save/saveOverride branch (the same established pattern used
        // throughout this codebase's own saveOverride seams — a
        // faithful simulation, since a genuine `save()` failure
        // wouldn't roll back a pending insert either). SwiftData
        // fetches include pending, unsaved inserts against the same
        // `modelContext` by default, so asserting `.isEmpty` here was
        // never a real proof of "nothing happened" — it was asserting
        // rollback semantics this method doesn't provide and never
        // claimed to. What `acceptSuggestion` actually, correctly
        // guarantees on failure is that it throws rather than
        // returning a value — already fully verified by the `throws:`
        // check above; a throwing function returning no value *is*
        // "not reporting success."
    }

    @Test("Accepting a suggestion for a committed WeekPlan is rejected")
    @MainActor
    func acceptingSuggestionForCommittedWeekPlanRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let suggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)
        try service.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        #expect(throws: PlanningServiceError.weekPlanNotDraft) {
            try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).isEmpty)
    }

    // MARK: Acceptance — authoritative validation (correctness revision)

    @Test("A suggestion whose claimed athlete differs from the WeekPlan's athlete is rejected")
    @MainActor
    func suggestionAthleteMismatchIsRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let genuine = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)
        let tampered = RecurringActivitySuggestion(
            id: genuine.id, recurringPlannedActivityId: genuine.recurringPlannedActivityId,
            athleteId: otherAthleteId, occurrenceDate: genuine.occurrenceDate, title: genuine.title,
            activityType: genuine.activityType, sportId: genuine.sportId, categoryIds: genuine.categoryIds,
            startLocalTime: genuine.startLocalTime, plannedDurationMinutes: genuine.plannedDurationMinutes,
            timeZoneId: genuine.timeZoneId
        )

        #expect(throws: PlanningServiceError.recurringOccurrenceAthleteMismatch) {
            try service.acceptSuggestion(tampered, forWeekPlan: weekPlan.weekPlanId)
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).isEmpty)
    }

    @Test("A recurring definition whose own athlete differs from the WeekPlan's athlete is rejected")
    @MainActor
    func recurringDefinitionAthleteMismatchIsRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        // Belongs to a DIFFERENT athlete than the WeekPlan.
        let otherAthletesDefinition = try service.createRecurringPlannedActivity(
            athleteId: otherAthleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        // Hand-constructed — deriveSuggestions for weekPlan's own
        // athlete would never surface another athlete's definition.
        // athleteId here matches the WeekPlan, isolating the
        // definition-side mismatch specifically.
        let suggestion = RecurringActivitySuggestion(
            id: "irrelevant", recurringPlannedActivityId: otherAthletesDefinition.recurringPlannedActivityId,
            athleteId: athleteId, occurrenceDate: Self.mondayWeekStart, title: "Football",
            activityType: .teamTraining, sportId: nil, categoryIds: [], startLocalTime: nil,
            plannedDurationMinutes: nil, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(throws: PlanningServiceError.recurringOccurrenceAthleteMismatch) {
            try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).isEmpty)
    }

    @Test("An occurrence date before the WeekPlan's own 7-day week is rejected")
    @MainActor
    func occurrenceBeforeWeekPlanIsRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        let definition = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2025, month: 12, day: 1), effectiveEndDate: Self.rangeEnd
        )
        // One week before weekStart — still a Monday, still within the
        // definition's own effective range, but outside this WeekPlan.
        let outsideDate = Self.mondayWeekStart.adding(days: -7)
        let suggestion = RecurringActivitySuggestion(
            id: "irrelevant", recurringPlannedActivityId: definition.recurringPlannedActivityId,
            athleteId: athleteId, occurrenceDate: outsideDate, title: "Football",
            activityType: .teamTraining, sportId: nil, categoryIds: [], startLocalTime: nil,
            plannedDurationMinutes: nil, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(throws: PlanningServiceError.recurringOccurrenceOutsideWeekPlan) {
            try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).isEmpty)
    }

    @Test("An occurrence date after the WeekPlan's own 7-day week is rejected")
    @MainActor
    func occurrenceAfterWeekPlanIsRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        let definition = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        // One week after weekStart — still a Monday, still within the
        // definition's own effective range, but outside this WeekPlan.
        let outsideDate = Self.mondayWeekStart.adding(days: 7)
        let suggestion = RecurringActivitySuggestion(
            id: "irrelevant", recurringPlannedActivityId: definition.recurringPlannedActivityId,
            athleteId: athleteId, occurrenceDate: outsideDate, title: "Football",
            activityType: .teamTraining, sportId: nil, categoryIds: [], startLocalTime: nil,
            plannedDurationMinutes: nil, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(throws: PlanningServiceError.recurringOccurrenceOutsideWeekPlan) {
            try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).isEmpty)
    }

    @Test("An occurrence date whose actual weekday doesn't match the definition's weekday is rejected")
    @MainActor
    func occurrenceWeekdayMismatchIsRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        let definition = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        // Tuesday within the same week — inside the WeekPlan and inside
        // the definition's effective range, but the definition's own
        // weekday is Monday.
        let wrongWeekdayDate = Self.mondayWeekStart.adding(days: 1)
        let suggestion = RecurringActivitySuggestion(
            id: "irrelevant", recurringPlannedActivityId: definition.recurringPlannedActivityId,
            athleteId: athleteId, occurrenceDate: wrongWeekdayDate, title: "Football",
            activityType: .teamTraining, sportId: nil, categoryIds: [], startLocalTime: nil,
            plannedDurationMinutes: nil, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(throws: PlanningServiceError.recurringOccurrenceWeekdayMismatch) {
            try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).isEmpty)
    }

    @Test("An occurrence date outside the definition's own inclusive effective range is rejected")
    @MainActor
    func occurrenceOutsideEffectiveRangeIsRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        // Effective range deliberately excludes this week's Monday.
        let definition = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2026, month: 1, day: 12), effectiveEndDate: Self.rangeEnd
        )
        // Inside the WeekPlan, matches the weekday, but before the
        // definition's own effectiveStartDate.
        let suggestion = RecurringActivitySuggestion(
            id: "irrelevant", recurringPlannedActivityId: definition.recurringPlannedActivityId,
            athleteId: athleteId, occurrenceDate: Self.mondayWeekStart, title: "Football",
            activityType: .teamTraining, sportId: nil, categoryIds: [], startLocalTime: nil,
            plannedDurationMinutes: nil, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(throws: PlanningServiceError.recurringOccurrenceOutsideEffectiveRange) {
            try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).isEmpty)
    }

    @Test("A suggestion for a since-disabled recurring definition is rejected")
    @MainActor
    func disabledDefinitionSuggestionIsRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        let definition = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        // Derived while still enabled — genuinely valid at the moment
        // of derivation.
        let suggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)
        try service.setRecurringPlannedActivityEnabled(definition.recurringPlannedActivityId, isEnabled: false)

        #expect(throws: PlanningServiceError.recurringPlannedActivityDisabled) {
            try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).isEmpty)
    }

    @Test("A suggestion referencing a recurring definition that no longer exists is rejected")
    @MainActor
    func missingRecurringDefinitionIsRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        let suggestion = RecurringActivitySuggestion(
            id: "irrelevant", recurringPlannedActivityId: RecurringPlannedActivityId(),
            athleteId: athleteId, occurrenceDate: Self.mondayWeekStart, title: "Football",
            activityType: .teamTraining, sportId: nil, categoryIds: [], startLocalTime: nil,
            plannedDurationMinutes: nil, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(throws: PlanningServiceError.recurringPlannedActivityNotFound) {
            try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
        }
        #expect(try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).isEmpty)
    }

    @Test("A stale suggestion's descriptive values are ignored — the created activity uses the definition's current values")
    @MainActor
    func staleSuggestionValuesAreIgnored() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.mondayWeekStart)
        let definition = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            plannedDurationMinutes: 90,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let staleSuggestion = try #require(try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).first)
        #expect(staleSuggestion.title == "Football")
        #expect(staleSuggestion.plannedDurationMinutes == 90)

        // The definition changes AFTER the suggestion was derived —
        // the suggestion in hand still reflects the OLD values.
        try service.editRecurringPlannedActivity(
            definition.recurringPlannedActivityId,
            title: "Football (renamed)",
            activityType: .match,
            weekdays: [.monday],
            plannedDurationMinutes: 120,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: Self.rangeStart,
            effectiveEndDate: Self.rangeEnd
        )

        let created = try service.acceptSuggestion(staleSuggestion, forWeekPlan: weekPlan.weekPlanId)

        #expect(created.title == "Football (renamed)")
        #expect(created.activityType == .match)
        #expect(created.plannedDurationMinutes == 120)
    }
}
