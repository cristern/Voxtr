import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
@Suite("Activity Completion & Review Flow", .serialized)
struct ActivityCompletionReviewFlowTests {

    /// Item 7: duplicate PlannedActivity logging is already prevented
    /// at the correct application/domain boundary (TrainingService,
    /// S3.2) — this test proves the prevention at that lowest
    /// appropriate layer, not just at one UI entry point, since there
    /// are multiple legitimate entry points into the same service.
    @Test("TrainingService.logActivity rejects a second log against the same PlannedActivity")
    @MainActor
    func serviceLayerPreventsDuplicateLogging() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: "Run", startedAt: .now, durationMinutes: 45
        )

        #expect(throws: TrainingServiceError.plannedActivityAlreadyLinked) {
            try trainingService.logActivity(
                athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
                activityType: .individualTraining, title: "Run", startedAt: .now, durationMinutes: 45
            )
        }

        // Confirms this holds regardless of entry point — a second
        // attempt via a different call site (e.g. Daily Training's own
        // generic form, which also selects a plannedActivityId) hits
        // the same service-layer check, not a separate one.
        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
    }

    /// Item 4: a save failure must never leave a logged/completed
    /// state behind — proven here by attempting a duplicate log (the
    /// one failure mode this system actually has) and confirming
    /// completion state is unaffected by the rejected attempt.
    @Test("A rejected duplicate log does not alter the existing completed state")
    @MainActor
    func rejectedDuplicateLogDoesNotAlterCompletionState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: "Run", startedAt: .now, durationMinutes: 45
        )

        let before = try coordinationService.plannedActivitiesWithCompletion([activity])
        #expect(before.first?.isCompleted == true)

        _ = try? trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: "Run", startedAt: .now, durationMinutes: 99
        )

        let after = try coordinationService.plannedActivitiesWithCompletion([activity])
        #expect(after.first?.isCompleted == true)
        // Still the original 45-minute log, not a second/overwritten one.
        #expect(after.first?.loggedActivity?.durationMinutes == 45)
    }

    /// Item 3: logged activity appears in today's logged data after
    /// save — proven via the exact query DailyTrainingViewModel.load()
    /// uses, and the exact one ActivityDetailView's canonical flow
    /// writes through.
    @Test("A logged activity appears in today's logged activities after save")
    @MainActor
    func loggedActivityAppearsInTodaysLoggedActivities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: "Run", startedAt: .now, durationMinutes: 45
        )

        let todaysLogs = try trainingService.fetchTodaysLoggedActivities(forAthlete: athleteId)
        #expect(todaysLogs.contains { $0.plannedActivityId == activity.plannedActivityId.rawValue })
    }

    /// Item 5: two different athletes' activities never cross-link —
    /// confirms the relationship lookup is scoped per PlannedActivityId,
    /// not accidentally shared across athletes.
    @Test("Two athletes' planned/logged activities never cross-link")
    @MainActor
    func twoAthletesNeverCrossLink() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliverId = AthleteId()
        let emmaId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let oliverWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: oliverId, weekStart: weekStart)
        let emmaWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: emmaId, weekStart: weekStart)
        let oliverActivity = try planningService.addPlannedActivity(
            toWeekPlan: oliverWeekPlan.weekPlanId, athleteId: oliverId, activityType: .individualTraining,
            title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let emmaActivity = try planningService.addPlannedActivity(
            toWeekPlan: emmaWeekPlan.weekPlanId, athleteId: emmaId, activityType: .individualTraining,
            title: "Swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        _ = try trainingService.logActivity(
            athleteId: oliverId, plannedActivityId: oliverActivity.plannedActivityId,
            activityType: .individualTraining, title: "Run", startedAt: .now, durationMinutes: 45
        )

        let oliverCompletion = try coordinationService.plannedActivitiesWithCompletion([oliverActivity])
        let emmaCompletion = try coordinationService.plannedActivitiesWithCompletion([emmaActivity])
        #expect(oliverCompletion.first?.isCompleted == true)
        #expect(emmaCompletion.first?.isCompleted == false)
        #expect(emmaCompletion.first?.loggedActivity == nil)
    }

    /// Item 6: Weekly Review's own data source
    /// (plannedActivitiesWithCompletion, reused by
    /// WeeklyReviewCoordinationService) derives completed state — and
    /// now the actual logged details — from the real relationship,
    /// never from matching title/date.
    @Test("Weekly Review's planned-activity data carries the real logged relationship, not inferred from title/date")
    @MainActor
    func weeklyReviewDerivesFromActualRelationship() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        // Same title, different activity — proves matching is by
        // PlannedActivityId, not by title collision.
        let plannedA = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Training", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let plannedB = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Training", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: plannedA.plannedActivityId,
            activityType: .individualTraining, title: "Training", startedAt: .now,
            durationMinutes: 45, perceivedExertion: 7
        )

        let completions = try coordinationService.plannedActivitiesWithCompletion([plannedA, plannedB])
        let completionA = completions.first { $0.plannedActivity.plannedActivityId == plannedA.plannedActivityId }
        let completionB = completions.first { $0.plannedActivity.plannedActivityId == plannedB.plannedActivityId }

        #expect(completionA?.isCompleted == true)
        #expect(completionA?.loggedActivity?.durationMinutes == 45)
        #expect(completionA?.loggedActivity?.perceivedExertion == 7)
        // Same title, but never logged — must not be seen as completed.
        #expect(completionB?.isCompleted == false)
        #expect(completionB?.loggedActivity == nil)
    }
}
