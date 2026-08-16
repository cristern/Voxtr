import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrPlanningDomain
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

    // MARK: - VX-022 closeout: loggedActivityDetail (Activity Detail read path)

    @Test("loggedActivityDetail resolves the exact LoggedActivity and its linked ActivityReflection for a PlannedActivity")
    @MainActor
    func loggedActivityDetailResolvesLoggedActivityAndReflection() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let result = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
            title: "Morning run", startedAt: .now, perceivedExertion: 7, authorId: authorId, sessionForm: 4
        )

        let detail = try #require(try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId))
        #expect(detail.loggedActivity.loggedActivityId == result.loggedActivity.loggedActivityId)
        #expect(detail.loggedActivity.perceivedExertion == 7)
        #expect(detail.reflection?.bodyFeeling == 4)
        #expect(detail.reflection?.loggedActivityId == result.loggedActivity.id)
    }

    @Test("loggedActivityDetail returns nil when nothing has been logged for that PlannedActivity")
    @MainActor
    func loggedActivityDetailReturnsNilWhenNothingLogged() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Not yet logged", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId) == nil)
    }

    @Test("loggedActivityDetail never mixes up two different PlannedActivities' LoggedActivity/reflection data")
    @MainActor
    func loggedActivityDetailNeverCrossesActivities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activityA = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Session A", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let activityB = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Session B", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activityA.plannedActivityId, activityType: .individualTraining,
            title: "Session A", startedAt: .now, perceivedExertion: 3, authorId: authorId, sessionForm: 2
        )
        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activityB.plannedActivityId, activityType: .individualTraining,
            title: "Session B", startedAt: .now, perceivedExertion: 8, authorId: authorId, sessionForm: 5
        )

        let detailA = try #require(try coordinator.loggedActivityDetail(forPlannedActivity: activityA.plannedActivityId))
        let detailB = try #require(try coordinator.loggedActivityDetail(forPlannedActivity: activityB.plannedActivityId))

        #expect(detailA.loggedActivity.perceivedExertion == 3)
        #expect(detailA.reflection?.bodyFeeling == 2)
        #expect(detailB.loggedActivity.perceivedExertion == 8)
        #expect(detailB.reflection?.bodyFeeling == 5)
        #expect(detailA.loggedActivity.loggedActivityId != detailB.loggedActivity.loggedActivityId)
    }

    // MARK: - Planned/Logged Activity lifecycle consistency cleanup: correctLoggedActivity (Edit Logged Activity -> RPE + Form)

    @Test("correctLoggedActivity updates RPE on the canonical LoggedActivity and Form on the exact linked ActivityReflection")
    @MainActor
    func correctLoggedActivityUpdatesRPEAndForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()

        let logged = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, perceivedExertion: 5, authorId: authorId, sessionForm: 3
        )

        let corrected = try coordinator.correctLoggedActivity(
            loggedActivityId: logged.loggedActivity.loggedActivityId,
            athleteId: athleteId, authorId: authorId,
            durationMinutes: 45, perceivedExertion: 8, sessionForm: 2
        )

        #expect(corrected.loggedActivity.durationMinutes == 45)
        #expect(corrected.loggedActivity.perceivedExertion == 8)
        guard case .saved(let reflection) = corrected.sessionFormOutcome else {
            Issue.record("Expected .saved"); return
        }
        #expect(reflection.bodyFeeling == 2)
        // Same linked reflection updated in place — never a second one
        // created for the same LoggedActivity.
        #expect(try reflectionService.fetchActivityReflections(forLoggedActivity: logged.loggedActivity.loggedActivityId).count == 1)
    }

    @Test("correctLoggedActivity creates an ActivityReflection when a legacy LoggedActivity had none yet and a Form value is entered")
    @MainActor
    func correctLoggedActivityCreatesReflectionWhenNoneExisted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()

        // Logged with no Form entered — no ActivityReflection exists yet.
        let logged = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: authorId, sessionForm: nil
        )
        #expect(try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivity.loggedActivityId) == nil)

        let corrected = try coordinator.correctLoggedActivity(
            loggedActivityId: logged.loggedActivity.loggedActivityId,
            athleteId: athleteId, authorId: authorId,
            durationMinutes: 30, perceivedExertion: nil, sessionForm: 4
        )

        guard case .saved(let reflection) = corrected.sessionFormOutcome else {
            Issue.record("Expected .saved"); return
        }
        #expect(reflection.bodyFeeling == 4)
        #expect(reflection.loggedActivityId == logged.loggedActivity.id)
    }

    @Test("correctLoggedActivity never touches a LoggedActivity belonging to a different athlete")
    @MainActor
    func correctLoggedActivityEnforcesAthleteIsolation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let authorId = ActorId()

        let logged = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, perceivedExertion: 5, authorId: authorId, sessionForm: 3
        )

        #expect(throws: TrainingServiceError.loggedActivityNotFound) {
            try coordinator.correctLoggedActivity(
                loggedActivityId: logged.loggedActivity.loggedActivityId,
                athleteId: otherAthleteId, authorId: authorId,
                durationMinutes: 45, perceivedExertion: 9, sessionForm: nil
            )
        }
        // Untouched.
        let stillOriginal = try #require(try trainingService.fetchLoggedActivities(forAthlete: athleteId).first)
        #expect(stillOriginal.perceivedExertion == 5)
    }

    // MARK: - Planned/Logged Activity lifecycle consistency cleanup: cancellation

    @Test("Cancelling a planned activity links a LoggedActivity with status .cancelled to the SAME PlannedActivity, preserving its identity — never a delete")
    @MainActor
    func cancellingLinksCancelledLoggedActivityPreservingPlanIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let result = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
            title: activity.title, startedAt: .now, durationMinutes: 1, status: .cancelled,
            authorId: authorId, sessionForm: nil
        )

        #expect(result.loggedActivity.status == .cancelled)
        #expect(result.loggedActivity.plannedActivityId == activity.plannedActivityId.rawValue)
        // The plan itself is completely untouched — cancellation is
        // never a delete.
        let plannedActivities = try planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        #expect(plannedActivities.contains { $0.plannedActivityId == activity.plannedActivityId })

        let detail = try #require(try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId))
        #expect(detail.loggedActivity.status == .cancelled)
    }

    @Test("Cancelling twice never creates a duplicate LoggedActivity — retrying the cancel is rejected the same way a duplicate log is")
    @MainActor
    func cancellingTwiceNeverDuplicatesTheLoggedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
            title: activity.title, startedAt: .now, durationMinutes: 1, status: .cancelled,
            authorId: authorId, sessionForm: nil
        )

        #expect(throws: TrainingServiceError.plannedActivityAlreadyLinked) {
            try coordinator.logActivity(
                athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
                title: activity.title, startedAt: .now, durationMinutes: 1, status: .cancelled,
                authorId: authorId, sessionForm: nil
            )
        }
        #expect(try trainingService.fetchLoggedActivities(forAthlete: athleteId).count == 1)
    }

    @Test("Cancelled and Missed remain distinct outcomes for two different planned activities")
    @MainActor
    func cancelledAndMissedRemainDistinct() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let cancelledActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Cancelled session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let missedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Missed session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: cancelledActivity.plannedActivityId, activityType: .individualTraining,
            title: cancelledActivity.title, startedAt: .now, durationMinutes: 1, status: .cancelled,
            authorId: authorId, sessionForm: nil
        )
        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: missedActivity.plannedActivityId, activityType: .individualTraining,
            title: missedActivity.title, startedAt: .now, durationMinutes: 1, status: .missed,
            authorId: authorId, sessionForm: nil
        )

        let cancelledDetail = try #require(try coordinator.loggedActivityDetail(forPlannedActivity: cancelledActivity.plannedActivityId))
        let missedDetail = try #require(try coordinator.loggedActivityDetail(forPlannedActivity: missedActivity.plannedActivityId))
        #expect(cancelledDetail.loggedActivity.status == .cancelled)
        #expect(missedDetail.loggedActivity.status == .missed)
    }
}
