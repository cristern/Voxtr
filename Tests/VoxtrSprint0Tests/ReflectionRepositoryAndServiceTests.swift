import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("ReflectionRepository and ReflectionService (S4.0)", .serialized)
struct ReflectionRepositoryAndServiceTests {

    @Test("Recording an ActivityReflection persists it, linked to a LoggedActivity by typed ID")
    @MainActor
    func recordActivityReflectionPersistsWithLink() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let loggedActivityId = LoggedActivityId()

        let reflection = try service.recordActivityReflection(
            athleteId: athleteId,
            loggedActivityId: loggedActivityId,
            authorId: ActorId(),
            visibility: .privateToAthlete,
            satisfaction: 4
        )

        #expect(reflection.loggedActivityId == loggedActivityId.rawValue)
        #expect(reflection.visibility == .privateToAthlete)
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReflection>()).count == 1)
    }

    @Test("Recording a ParentObservation persists it, optionally linked to a LoggedActivity")
    @MainActor
    func recordParentObservationPersistsWithOptionalLink() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let loggedActivityId = LoggedActivityId()

        let observation = try service.recordParentObservation(
            athleteId: athleteId,
            authorId: ActorId(),
            relatedLoggedActivityId: loggedActivityId,
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            text: "Looked strong today."
        )

        #expect(observation.relatedLoggedActivityId == loggedActivityId.rawValue)
        #expect(observation.visibility == .sharedWithGuardians)
        #expect(try container.mainContext.fetch(FetchDescriptor<ParentObservation>()).count == 1)
    }

    @Test("Recording a ParentObservation without a LoggedActivity link is allowed")
    @MainActor
    func recordParentObservationWithoutLinkIsAllowed() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)

        let observation = try service.recordParentObservation(
            athleteId: AthleteId(),
            authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            text: "General note."
        )

        #expect(observation.relatedLoggedActivityId == nil)
    }

    @Test("Fetching reflections by athlete returns only that athlete's reflections, ordered deterministically")
    @MainActor
    func fetchReflectionsByAthleteScopesAndOrders() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let firstAthlete = AthleteId()
        let secondAthlete = AthleteId()

        _ = try service.recordActivityReflection(
            athleteId: firstAthlete, loggedActivityId: LoggedActivityId(), authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 3
        )
        _ = try service.recordActivityReflection(
            athleteId: secondAthlete, loggedActivityId: LoggedActivityId(), authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 5
        )

        let first = try service.fetchActivityReflections(forAthlete: firstAthlete)
        let second = try service.fetchActivityReflections(forAthlete: firstAthlete)

        #expect(first.count == 1)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("Fetching reflections for one LoggedActivity returns only reflections linked to it")
    @MainActor
    func fetchReflectionsForOneLoggedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let firstLoggedActivity = LoggedActivityId()
        let secondLoggedActivity = LoggedActivityId()

        _ = try service.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: firstLoggedActivity, authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 3
        )
        _ = try service.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: secondLoggedActivity, authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 4
        )

        let results = try service.fetchActivityReflections(forLoggedActivity: firstLoggedActivity)

        #expect(results.count == 1)
        #expect(results.first?.loggedActivityId == firstLoggedActivity.rawValue)
    }

    @Test("Fetching parent observations by athlete returns only that athlete's observations, ordered deterministically by localDate")
    @MainActor
    func fetchParentObservationsByAthleteOrderedDeterministically() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()

        // Inserted out of chronological order deliberately.
        _ = try service.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 8), text: "Thursday"
        )
        _ = try service.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 5), text: "Monday"
        )
        _ = try service.recordParentObservation(
            athleteId: otherAthleteId, authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 6), text: "Other athlete"
        )

        let first = try service.fetchParentObservations(forAthlete: athleteId)
        let second = try service.fetchParentObservations(forAthlete: athleteId)

        #expect(first.map(\.text) == ["Monday", "Thursday"])
        #expect(first.map(\.id) == second.map(\.id))
    }
}
