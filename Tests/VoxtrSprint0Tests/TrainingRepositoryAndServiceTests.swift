import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrTrainingDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("TrainingRepository and TrainingService (S3.0)", .serialized)
struct TrainingRepositoryAndServiceTests {

    @Test("Logging an activity persists it, optionally linked to a PlannedActivity by typed ID")
    @MainActor
    func logActivityPersistsWithOptionalLink() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let athleteId = AthleteId()
        let plannedActivityId = PlannedActivityId()

        let logged = try service.logActivity(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            activityType: .individualTraining,
            title: "Endurance run",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            durationMinutes: 45,
            status: .completed,
            source: "manual"
        )

        #expect(logged.title == "Endurance run")
        #expect(logged.plannedActivityId == plannedActivityId.rawValue)
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == 1)
    }

    @Test("Logging an activity without a PlannedActivity link is allowed")
    @MainActor
    func logActivityWithoutLinkIsAllowed() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)

        let logged = try service.logActivity(
            athleteId: AthleteId(),
            activityType: .physicalTraining,
            title: "Gym session",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            durationMinutes: 60,
            status: .completed,
            source: "manual"
        )

        #expect(logged.plannedActivityId == nil)
    }

    @Test("Fetching by athlete returns only that athlete's activities, ordered deterministically by startedAt")
    @MainActor
    func fetchByAthleteScopesAndOrdersDeterministically() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let firstAthlete = AthleteId()
        let secondAthlete = AthleteId()
        let base = Date(timeIntervalSince1970: 1_767_000_000)

        // Inserted out of chronological order deliberately.
        _ = try service.logActivity(
            athleteId: firstAthlete, activityType: .individualTraining, title: "Thursday",
            startedAt: base.addingTimeInterval(3 * 86_400), durationMinutes: 30, status: .completed, source: "manual"
        )
        _ = try service.logActivity(
            athleteId: firstAthlete, activityType: .individualTraining, title: "Monday",
            startedAt: base, durationMinutes: 30, status: .completed, source: "manual"
        )
        _ = try service.logActivity(
            athleteId: secondAthlete, activityType: .individualTraining, title: "Other athlete",
            startedAt: base.addingTimeInterval(86_400), durationMinutes: 30, status: .completed, source: "manual"
        )
        _ = try service.logActivity(
            athleteId: firstAthlete, activityType: .individualTraining, title: "Wednesday",
            startedAt: base.addingTimeInterval(2 * 86_400), durationMinutes: 30, status: .completed, source: "manual"
        )

        let first = try service.fetchLoggedActivities(forAthlete: firstAthlete)
        let second = try service.fetchLoggedActivities(forAthlete: firstAthlete)

        #expect(first.map(\.title) == ["Monday", "Wednesday", "Thursday"])
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("Fetching by athlete and date range returns only activities within that range")
    @MainActor
    func fetchByAthleteAndDateRangeFiltersCorrectly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let athleteId = AthleteId()
        let base = Date(timeIntervalSince1970: 1_767_000_000)

        _ = try service.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Before range",
            startedAt: base.addingTimeInterval(-86_400), durationMinutes: 30, status: .completed, source: "manual"
        )
        _ = try service.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "In range",
            startedAt: base.addingTimeInterval(1 * 86_400), durationMinutes: 30, status: .completed, source: "manual"
        )
        _ = try service.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "After range",
            startedAt: base.addingTimeInterval(10 * 86_400), durationMinutes: 30, status: .completed, source: "manual"
        )

        let inRange = try service.fetchLoggedActivities(
            forAthlete: athleteId,
            from: base,
            to: base.addingTimeInterval(5 * 86_400)
        )

        #expect(inRange.count == 1)
        #expect(inRange.first?.title == "In range")
    }
}
