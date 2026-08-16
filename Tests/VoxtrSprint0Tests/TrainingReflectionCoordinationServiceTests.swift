import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("TrainingReflectionCoordinationService (VX-022)", .serialized)
struct TrainingReflectionCoordinationServiceTests {

    @Test("Logging with a valid Form value creates the LoggedActivity and saves it as ActivityReflection.bodyFeeling, defaulting to sharedWithGuardians")
    @MainActor
    func logActivityWithValidFormSavesReflection() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()

        let result = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: authorId, sessionForm: 4
        )

        guard case .saved(let reflection) = result.sessionFormOutcome else {
            Issue.record("Expected .saved"); return
        }
        #expect(reflection.bodyFeeling == 4)
        #expect(reflection.loggedActivityId == result.loggedActivity.id)
        #expect(reflection.athleteId == athleteId.rawValue)
        // VX-022 correction: family-first MVP default, not
        // privateToAthlete — no canonical visibility resolver is
        // actually reachable anywhere in this codebase (verified).
        #expect(reflection.visibility == .sharedWithGuardians)
    }

    @Test("Logging with sessionForm == nil still logs the activity and reports .notRequested — this type itself remains a general-purpose optional-Form primitive; V1's required-Form policy is enforced one layer up")
    @MainActor
    func logActivityWithoutSessionFormIsNotRequestedAtThisLayer() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()

        let result = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: ActorId(), sessionForm: nil
        )

        guard case .notRequested = result.sessionFormOutcome else {
            Issue.record("Expected .notRequested"); return
        }
        #expect(try reflectionService.fetchActivityReflections(forAthlete: athleteId).isEmpty)
    }

    @Test("A reflection write failure preserves the LoggedActivity and reports .failed, never throwing — the activity is never rolled back")
    @MainActor
    func reflectionWriteFailurePreservesLoggedActivityAndReportsFailed() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()

        // Out-of-range bodyFeeling deterministically forces
        // ReflectionService to throw .invalidField — TrainingService.logActivity
        // itself has no such validation, so the LoggedActivity is
        // genuinely created regardless.
        let result = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: ActorId(), sessionForm: 99
        )

        guard case .failed = result.sessionFormOutcome else {
            Issue.record("Expected .failed"); return
        }
        #expect(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).count == 1)
        #expect(try reflectionService.fetchActivityReflections(forLoggedActivity: result.loggedActivity.loggedActivityId).isEmpty)
    }

    @Test("Retrying recordSessionForm against the same LoggedActivity after a failure succeeds and never creates a duplicate LoggedActivity")
    @MainActor
    func retryingRecordSessionFormNeverDuplicatesTheLoggedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()

        let firstAttempt = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: authorId, sessionForm: 99
        )
        guard case .failed = firstAttempt.sessionFormOutcome else {
            Issue.record("Expected .failed on the first attempt"); return
        }
        let loggedActivityId = firstAttempt.loggedActivity.loggedActivityId

        // Retry ONLY the reflection write, against the exact same
        // LoggedActivityId the first attempt produced — never calls
        // logActivity again.
        let reflection = try coordinator.recordSessionForm(
            athleteId: athleteId, loggedActivityId: loggedActivityId, authorId: authorId, bodyFeeling: 4
        )

        #expect(reflection.bodyFeeling == 4)
        #expect(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).count == 1)
        let allLogged = try trainingRepository.fetchLoggedActivities(forAthlete: athleteId)
        #expect(allLogged.first?.loggedActivityId == loggedActivityId)
        #expect(try reflectionService.fetchActivityReflections(forLoggedActivity: loggedActivityId).count == 1)
    }
}
