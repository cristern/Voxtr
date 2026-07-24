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
}
