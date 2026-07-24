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
}
