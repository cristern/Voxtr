import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrPlanningDomain

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
}
