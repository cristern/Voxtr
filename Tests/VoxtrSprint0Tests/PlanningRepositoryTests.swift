import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
@testable import VoxtrPlanningDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("PlanningRepository (S2.0)", .serialized)
struct PlanningRepositoryTests {

    @Test("Inserting a WeekPlan persists it as a draft with revision 1")
    @MainActor
    func insertWeekPlanPersistsAsDraft() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()

        let weekPlan = try repository.insertWeekPlan(
            athleteId: athleteId,
            weekStart: LocalDate(year: 2026, month: 1, day: 5)
        )

        #expect(weekPlan.status == .draft)
        #expect(weekPlan.revision == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<WeekPlan>()).count == 1)
    }

    @Test("Fetching a WeekPlan by athlete and week returns the matching plan, scoped correctly")
    @MainActor
    func fetchWeekPlanScopesByAthleteAndWeek() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let firstAthlete = AthleteId()
        let secondAthlete = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 1, day: 5)
        _ = try repository.insertWeekPlan(athleteId: firstAthlete, weekStart: weekStart)
        _ = try repository.insertWeekPlan(athleteId: secondAthlete, weekStart: weekStart)
        _ = try repository.insertWeekPlan(athleteId: firstAthlete, weekStart: LocalDate(year: 2026, month: 1, day: 12))

        let found = try repository.fetchWeekPlan(forAthlete: firstAthlete, weekStart: weekStart)

        #expect(found != nil)
        #expect(found?.athleteId == firstAthlete.rawValue)
        #expect(found?.weekStart == weekStart)
    }

    @Test("Fetching a WeekPlan for an athlete/week with nothing persisted returns nil")
    @MainActor
    func fetchWeekPlanReturnsNilWhenNotFound() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)

        let found = try repository.fetchWeekPlan(
            forAthlete: AthleteId(),
            weekStart: LocalDate(year: 2026, month: 1, day: 5)
        )

        #expect(found == nil)
    }

    @Test("Inserting PlannedActivity records persists them against their WeekPlan")
    @MainActor
    func insertPlannedActivityPersists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()
        let weekPlan = try repository.insertWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))

        let activity = try repository.insertPlannedActivity(
            weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(activity.title == "Endurance run")
        #expect(activity.weekPlanId == weekPlan.id)
        #expect(try container.mainContext.fetch(FetchDescriptor<PlannedActivity>()).count == 1)
    }

    @Test("Fetching PlannedActivity records by WeekPlan ID returns only that plan's activities")
    @MainActor
    func fetchPlannedActivitiesScopesByWeekPlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()
        let firstWeekPlan = try repository.insertWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let secondWeekPlan = try repository.insertWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 12))

        _ = try repository.insertPlannedActivity(
            weekPlanId: firstWeekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try repository.insertPlannedActivity(
            weekPlanId: firstWeekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .recovery,
            title: "Mobility session",
            localDate: LocalDate(year: 2026, month: 1, day: 7),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try repository.insertPlannedActivity(
            weekPlanId: secondWeekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Interval session",
            localDate: LocalDate(year: 2026, month: 1, day: 13),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let firstPlanActivities = try repository.fetchPlannedActivities(forWeekPlan: firstWeekPlan.weekPlanId)
        let secondPlanActivities = try repository.fetchPlannedActivities(forWeekPlan: secondWeekPlan.weekPlanId)

        #expect(firstPlanActivities.count == 2)
        #expect(secondPlanActivities.count == 1)
        #expect(secondPlanActivities.first?.title == "Interval session")
    }

    // MARK: - insertPlannedActivity with externalSourceId (Recurring Planned Activities)

    @Test("insertPlannedActivity still works with no externalSourceId/externalSourceType supplied — existing behavior unchanged")
    @MainActor
    func insertPlannedActivityExistingBehaviorUnchanged() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()
        let weekPlan = try repository.insertWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))

        let activity = try repository.insertPlannedActivity(
            weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Endurance run",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(activity.externalSourceId == nil)
        #expect(activity.externalSourceType == nil)
    }

    @Test("insertPlannedActivity persists externalSourceId/externalSourceType when supplied")
    @MainActor
    func insertPlannedActivityPersistsExternalSourceFields() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()
        let weekPlan = try repository.insertWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))

        let activity = try repository.insertPlannedActivity(
            weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Football",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            externalSourceId: "some-occurrence-id",
            externalSourceType: RecurringPlannedActivity.externalSourceType
        )

        #expect(activity.externalSourceId == "some-occurrence-id")
        #expect(activity.externalSourceType == RecurringPlannedActivity.externalSourceType)
    }

    @Test("fetchPlannedActivity(forExternalSourceId:weekPlanId:) finds a matching activity, scoped to the WeekPlan")
    @MainActor
    func fetchPlannedActivityByExternalSourceIdScopesToWeekPlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()
        let firstWeekPlan = try repository.insertWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let secondWeekPlan = try repository.insertWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 12))
        _ = try repository.insertPlannedActivity(
            weekPlanId: firstWeekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Football",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            externalSourceId: "occurrence-A",
            externalSourceType: RecurringPlannedActivity.externalSourceType
        )

        let foundInFirst = try repository.fetchPlannedActivity(forExternalSourceId: "occurrence-A", weekPlanId: firstWeekPlan.weekPlanId)
        let foundInSecond = try repository.fetchPlannedActivity(forExternalSourceId: "occurrence-A", weekPlanId: secondWeekPlan.weekPlanId)

        #expect(foundInFirst != nil)
        #expect(foundInSecond == nil)
    }

    // MARK: - RecurringPlannedActivity

    @Test("insertRecurringPlannedActivity persists a recurring definition, fetchable by ID")
    @MainActor
    func insertRecurringPlannedActivityPersistsAndFetches() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()

        let created = try repository.insertRecurringPlannedActivity(
            athleteId: athleteId,
            title: "Football",
            activityType: .teamTraining,
            weekdays: [.monday],
            startLocalTime: LocalTime(hour: 17, minute: 30),
            plannedDurationMinutes: 150,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2026, month: 8, day: 10),
            effectiveEndDate: LocalDate(year: 2026, month: 12, day: 14)
        )

        let fetched = try repository.fetchRecurringPlannedActivity(byId: created.recurringPlannedActivityId)
        #expect(fetched?.id == created.id)
        #expect(fetched?.title == "Football")
    }

    @Test("Athlete ownership is preserved on a persisted recurring definition")
    @MainActor
    func recurringPlannedActivityPreservesAthleteOwnership() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()

        let created = try repository.insertRecurringPlannedActivity(
            athleteId: athleteId,
            title: "Football",
            activityType: .teamTraining,
            weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2026, month: 8, day: 10),
            effectiveEndDate: LocalDate(year: 2026, month: 12, day: 14)
        )

        #expect(created.athleteId == athleteId.rawValue)
    }

    @Test("Weekday and inclusive date range are preserved on a persisted recurring definition")
    @MainActor
    func recurringPlannedActivityPreservesWeekdayAndDateRange() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()
        let start = LocalDate(year: 2026, month: 8, day: 10)
        let end = LocalDate(year: 2026, month: 12, day: 14)

        let created = try repository.insertRecurringPlannedActivity(
            athleteId: athleteId,
            title: "Football",
            activityType: .teamTraining,
            weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: start,
            effectiveEndDate: end
        )

        #expect(created.weekdays == [.monday])
        #expect(created.effectiveStartDate == start)
        #expect(created.effectiveEndDate == end)
    }

    @Test("Optional start time and duration are preserved when supplied")
    @MainActor
    func recurringPlannedActivityPreservesOptionalTimeAndDuration() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()

        let created = try repository.insertRecurringPlannedActivity(
            athleteId: athleteId,
            title: "Football",
            activityType: .teamTraining,
            weekdays: [.monday],
            startLocalTime: LocalTime(hour: 17, minute: 30),
            plannedDurationMinutes: 150,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2026, month: 8, day: 10),
            effectiveEndDate: LocalDate(year: 2026, month: 12, day: 14)
        )

        #expect(created.startLocalTime == LocalTime(hour: 17, minute: 30))
        #expect(created.plannedDurationMinutes == 150)
    }

    @Test("Optional start time and duration remain nil when not supplied")
    @MainActor
    func recurringPlannedActivityLeavesOptionalFieldsNilWhenOmitted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()

        let created = try repository.insertRecurringPlannedActivity(
            athleteId: athleteId,
            title: "Football",
            activityType: .teamTraining,
            weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2026, month: 8, day: 10),
            effectiveEndDate: LocalDate(year: 2026, month: 12, day: 14)
        )

        #expect(created.startLocalTime == nil)
        #expect(created.plannedDurationMinutes == nil)
    }

    @Test("setRecurringPlannedActivityEnabled persists the enabled/disabled state")
    @MainActor
    func setRecurringPlannedActivityEnabledPersists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()
        let created = try repository.insertRecurringPlannedActivity(
            athleteId: athleteId,
            title: "Football",
            activityType: .teamTraining,
            weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2026, month: 8, day: 10),
            effectiveEndDate: LocalDate(year: 2026, month: 12, day: 14)
        )
        #expect(created.isEnabled == true)

        try repository.setRecurringPlannedActivityEnabled(created, isEnabled: false)

        let refetched = try repository.fetchRecurringPlannedActivity(byId: created.recurringPlannedActivityId)
        #expect(refetched?.isEnabled == false)
    }

    @Test("fetchRecurringPlannedActivities(forAthlete:) scopes to the requested athlete only")
    @MainActor
    func fetchRecurringPlannedActivitiesScopesByAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let firstAthlete = AthleteId()
        let secondAthlete = AthleteId()
        _ = try repository.insertRecurringPlannedActivity(
            athleteId: firstAthlete, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2026, month: 8, day: 10), effectiveEndDate: LocalDate(year: 2026, month: 12, day: 14)
        )
        _ = try repository.insertRecurringPlannedActivity(
            athleteId: secondAthlete, title: "Swimming", activityType: .individualTraining, weekdays: [.tuesday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2026, month: 8, day: 10), effectiveEndDate: LocalDate(year: 2026, month: 12, day: 14)
        )

        let firstAthleteActivities = try repository.fetchRecurringPlannedActivities(forAthlete: firstAthlete)

        #expect(firstAthleteActivities.count == 1)
        #expect(firstAthleteActivities.first?.title == "Football")
    }

    @Test("A save failure during insertRecurringPlannedActivity propagates")
    @MainActor
    func insertRecurringPlannedActivityPropagatesSaveFailure() throws {
        struct InjectedSaveFailure: Error {}

        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)

        #expect(throws: InjectedSaveFailure.self) {
            try repository.insertRecurringPlannedActivity(
                athleteId: AthleteId(),
                title: "Football",
                activityType: .teamTraining,
                weekdays: [.monday],
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                effectiveStartDate: LocalDate(year: 2026, month: 8, day: 10),
                effectiveEndDate: LocalDate(year: 2026, month: 12, day: 14),
                saveOverride: { throw InjectedSaveFailure() }
            )
        }
    }
}
