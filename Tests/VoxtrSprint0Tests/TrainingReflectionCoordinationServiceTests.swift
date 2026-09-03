import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
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

    // MARK: - Athlete Connection Foundation A: LoggedActivity actor attribution

    @Test("A manual log created via the real production path (TrainingReflectionCoordinationService.logActivity) stores the caller's own ActorId as loggedByActorId — e.g. the Parent workspace-owner participant's ActorId")
    @MainActor
    func manualLogStoresCallerActorId() throws {
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
        // Simulates the Parent owner participant's own ActorId, exactly
        // as `CurrentSessionActor.actorId` resolves it in production.
        let parentActorId = ActorId()

        let result = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: parentActorId, sessionForm: nil
        )

        #expect(result.loggedActivity.loggedByActorId == parentActorId.rawValue)
    }

    @Test("Actor attribution survives a repository fetch/reload — not merely present on the in-memory object returned at creation")
    @MainActor
    func actorAttributionSurvivesRepositoryFetch() throws {
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
        let actorId = ActorId()

        let result = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: actorId, sessionForm: nil
        )

        let refetched = try trainingRepository.fetchLoggedActivity(byId: result.loggedActivity.loggedActivityId)
        #expect(refetched?.loggedByActorId == actorId.rawValue)
    }

    @Test("loggedByActorId is independent of athleteId — the activity's subject never changes regardless of who logged it")
    @MainActor
    func athleteIdRemainsIndependentOfLoggedByActorId() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        // athleteId and actorId are deliberately unrelated identifiers —
        // proving neither is derived from the other.
        let athleteId = AthleteId()
        let actorId = ActorId()

        let result = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: actorId, sessionForm: nil
        )

        #expect(result.loggedActivity.athleteId == athleteId.rawValue)
        #expect(result.loggedActivity.loggedByActorId == actorId.rawValue)
        #expect(result.loggedActivity.athleteId != result.loggedActivity.loggedByActorId)
    }

    @Test("Regression: ActivityReflection.authorId attribution is unaffected by LoggedActivity's new loggedByActorId field — the existing, proven Reflection pattern this round reused is unchanged")
    @MainActor
    func reflectionAuthorAttributionUnchangedByLoggedActivityAttribution() throws {
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
            startedAt: .now, authorId: authorId, sessionForm: 3
        )

        guard case .saved(let reflection) = result.sessionFormOutcome else {
            Issue.record("Expected .saved"); return
        }
        #expect(reflection.authorId == authorId.rawValue)
        #expect(result.loggedActivity.loggedByActorId == authorId.rawValue)
    }

    @Test("A deliberately different actor can log an activity for the same AthleteProfile without creating a duplicate LoggedActivity model or changing the athlete's identity — actor attribution is provenance, never object ownership")
    @MainActor
    func differentActorLoggingSameAthleteCreatesNoDuplicateIdentity() throws {
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
        let parentActorId = ActorId()
        // A second, distinct actor — simulating a future Athlete
        // participant logging for their OWN existing AthleteProfile;
        // this test only proves the actor-attribution mechanism itself
        // is actor-agnostic, not any Athlete-session UI.
        let secondActorId = ActorId()
        #expect(parentActorId != secondActorId)

        let first = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: parentActorId, sessionForm: nil
        )
        let second = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Evening run",
            startedAt: .now.addingTimeInterval(3600), authorId: secondActorId, sessionForm: nil
        )

        // Two distinct LoggedActivity records, same athlete subject,
        // different actor attribution — never a second AthleteProfile,
        // never the same LoggedActivity id.
        #expect(first.loggedActivity.id != second.loggedActivity.id)
        #expect(first.loggedActivity.athleteId == athleteId.rawValue)
        #expect(second.loggedActivity.athleteId == athleteId.rawValue)
        #expect(first.loggedActivity.loggedByActorId == parentActorId.rawValue)
        #expect(second.loggedActivity.loggedByActorId == secondActorId.rawValue)
        let allForAthlete = try trainingService.fetchLoggedActivities(forAthlete: athleteId)
        #expect(allForAthlete.count == 2)
    }

    /// Sport / Activity Identity domain foundation, Part 6: traces the
    /// full Planned -> Logged lifecycle exactly as
    /// `LogActivityViewModel.save()` drives it (copying the planned
    /// activity's OWN current sportId/title/activityType straight
    /// through, never inferring anything) — a Sport-only planned
    /// activity's SportId and its ActivityType both survive unchanged
    /// onto the resulting LoggedActivity.
    @Test("Logging a Sport-only PlannedActivity preserves its SportId and ActivityType onto the resulting LoggedActivity")
    @MainActor
    func loggingSportOnlyPlannedActivityPreservesSportIdAndActivityType() throws {
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
        let sportId = SportId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let plannedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .strength,
            title: nil,
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            sportId: sportId
        )

        let result = try coordinator.logActivity(
            athleteId: athleteId,
            plannedActivityId: plannedActivity.plannedActivityId,
            sportId: plannedActivity.sportId.map(SportId.init(rawValue:)),
            activityType: plannedActivity.activityType,
            title: plannedActivity.title,
            startedAt: .now,
            authorId: ActorId(),
            sessionForm: nil
        )

        #expect(result.loggedActivity.title == nil)
        #expect(result.loggedActivity.sportId == sportId.rawValue)
        #expect(result.loggedActivity.activityType == .strength)
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

    @Test("Logged detail resolves planned-linked and standalone logs by exact LoggedActivityId")
    @MainActor
    func loggedDetailUsesExactStableIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let sameInstant = Date(timeIntervalSince1970: 1_767_000_000)
        let plannedActivityId = PlannedActivityId()
        let linked = try trainingService.logActivity(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            activityType: .individualTraining,
            title: "Same label",
            startedAt: sameInstant,
            durationMinutes: 30,
            status: .completed,
            loggedByActorId: ActorId()
        )
        let standalone = try trainingService.logActivity(
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Same label",
            startedAt: sameInstant,
            durationMinutes: 45,
            status: .completed,
            loggedByActorId: ActorId()
        )

        let linkedDetail = try coordinator.loggedActivityDetail(
            loggedActivityId: linked.loggedActivityId,
            athleteId: athleteId
        )
        let standaloneDetail = try coordinator.loggedActivityDetail(
            loggedActivityId: standalone.loggedActivityId,
            athleteId: athleteId
        )

        #expect(linkedDetail.loggedActivity.loggedActivityId == linked.loggedActivityId)
        #expect(linkedDetail.loggedActivity.plannedActivityId == plannedActivityId.rawValue)
        #expect(linkedDetail.loggedActivity.durationMinutes == 30)
        #expect(standaloneDetail.loggedActivity.loggedActivityId == standalone.loggedActivityId)
        #expect(standaloneDetail.loggedActivity.plannedActivityId == nil)
        #expect(standaloneDetail.loggedActivity.durationMinutes == 45)
    }

    @Test("Reopening Missed or Cancelled removes its linked ActivityReflection before removing the log")
    @MainActor
    func reopenNoTrainingOutcomeCleansReflectionIntegrity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            modelContext: container.mainContext
        )
        let athleteId = AthleteId()
        for status: ActivityStatus in [.missed, .cancelled] {
            let plannedActivityId = PlannedActivityId()
            let result = try coordinator.logActivity(
                athleteId: athleteId,
                plannedActivityId: plannedActivityId,
                activityType: .individualTraining,
                title: "No-training outcome",
                startedAt: Date(timeIntervalSince1970: 1_767_000_000),
                durationMinutes: 1,
                status: status,
                authorId: ActorId(),
                sessionForm: 3
            )
            let loggedActivityId = result.loggedActivity.loggedActivityId
            #expect(
                try reflectionService.fetchActivityReflection(
                    forLoggedActivity: loggedActivityId
                ) != nil
            )

            try coordinator.reopenNoTrainingOutcome(
                loggedActivityId,
                athleteId: athleteId
            )

            #expect(try trainingService.fetchLoggedActivities(forPlannedActivity: plannedActivityId).isEmpty)
            #expect(
                try reflectionService.fetchActivityReflection(
                    forLoggedActivity: loggedActivityId
                ) == nil
            )
        }
    }

    @Test("A reflection-stage failure leaves both canonical records unchanged")
    @MainActor
    func reopenReflectionFailureRollsBackEverything() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            modelContext: container.mainContext
        )
        let athleteId = AthleteId()
        let logged = try trainingService.logActivity(
            athleteId: athleteId,
            activityType: .other,
            title: "Rest day",
            startedAt: .now,
            durationMinutes: 1,
            status: .missed,
            loggedByActorId: ActorId()
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId,
            loggedActivityId: logged.loggedActivityId,
            authorId: ActorId(),
            visibility: .privateToAthlete,
            bodyFeeling: 2
        )

        #expect(throws: TrainingReflectionCoordinationService.SimulatedReopenFailure.self) {
            try coordinator.reopenNoTrainingOutcome(
                logged.loggedActivityId,
                athleteId: athleteId,
                failAt: .beforeReflectionDeletion
            )
        }

        #expect(try trainingService.fetchLoggedActivity(byId: logged.loggedActivityId, athleteId: athleteId).loggedActivityId == logged.loggedActivityId)
        #expect(try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivityId) != nil)
    }

    @Test("A downstream Training failure restores the exact original reflection")
    @MainActor
    func reopenTrainingFailureRollsBackExactReflection() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            modelContext: container.mainContext
        )
        let athleteId = AthleteId()
        let authorId = ActorId()
        let logged = try trainingService.logActivity(
            athleteId: athleteId,
            activityType: .other,
            title: "Mistaken cancellation",
            startedAt: .now,
            durationMinutes: 1,
            status: .cancelled,
            loggedByActorId: ActorId()
        )
        let original = try reflectionService.recordActivityReflection(
            athleteId: athleteId,
            loggedActivityId: logged.loggedActivityId,
            authorId: authorId,
            visibility: .sharedWithGuardians,
            bodyFeeling: 2,
            energy: 3,
            satisfaction: 4,
            perceivedExertion: 5,
            mostSatisfiedWith: "Exact strength",
            learningNote: "Exact learning",
            nextTimeNote: "Exact next step"
        )
        let originalId = original.reflectionId
        let originalCreatedAt = original.createdAt
        let originalUpdatedAt = original.updatedAt
        let originalSchemaVersion = original.schemaVersion

        #expect(throws: TrainingReflectionCoordinationService.SimulatedReopenFailure.self) {
            try coordinator.reopenNoTrainingOutcome(
                logged.loggedActivityId,
                athleteId: athleteId,
                failAt: nil,
                saveOverride: { throw TrainingReflectionCoordinationService.SimulatedReopenFailure() }
            )
        }

        let fetchedReflection = try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivityId)
        let restored = try #require(fetchedReflection)
        #expect(try trainingService.fetchLoggedActivity(byId: logged.loggedActivityId, athleteId: athleteId).loggedActivityId == logged.loggedActivityId)
        #expect(restored.reflectionId == originalId)
        #expect(restored.athleteId == athleteId.rawValue)
        #expect(restored.loggedActivityId == logged.loggedActivityId.rawValue)
        #expect(restored.authorId == authorId.rawValue)
        #expect(restored.visibility == .sharedWithGuardians)
        #expect(restored.bodyFeeling == 2)
        #expect(restored.energy == 3)
        #expect(restored.satisfaction == 4)
        #expect(restored.perceivedExertion == 5)
        #expect(restored.mostSatisfiedWith == "Exact strength")
        #expect(restored.learningNote == "Exact learning")
        #expect(restored.nextTimeNote == "Exact next step")
        #expect(restored.createdAt == originalCreatedAt)
        #expect(restored.updatedAt == originalUpdatedAt)
        #expect(restored.schemaVersion == originalSchemaVersion)
    }

    @Test("A no-reflection Missed or Cancelled outcome reopens successfully")
    @MainActor
    func reopenWithoutReflectionSucceeds() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            modelContext: container.mainContext
        )
        let athleteId = AthleteId()

        for status: ActivityStatus in [.missed, .cancelled] {
            let logged = try trainingService.logActivity(
                athleteId: athleteId,
                activityType: .other,
                title: "No reflection",
                startedAt: .now,
                durationMinutes: 1,
                status: status,
                loggedByActorId: ActorId()
            )
            try coordinator.reopenNoTrainingOutcome(logged.loggedActivityId, athleteId: athleteId)
            #expect(throws: TrainingServiceError.loggedActivityNotFound) {
                try trainingService.fetchLoggedActivity(byId: logged.loggedActivityId, athleteId: athleteId)
            }
        }
    }
}
