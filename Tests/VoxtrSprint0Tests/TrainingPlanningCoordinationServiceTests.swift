import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrTrainingDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("TrainingPlanningCoordinationService (S3.2)", .serialized)
struct TrainingPlanningCoordinationServiceTests {

    @Test("A PlannedActivity with no LoggedActivity linked is reported as not completed")
    @MainActor
    func plannedActivityWithNoLogIsNotCompleted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let referenceDate = Date(timeIntervalSince1970: 1_767_312_000)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: referenceDate)
        let today = TrainingPlanningCoordinationService.today(referenceDate: referenceDate)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let results = try coordinationService.todaysPlannedActivitiesWithCompletion(
            forAthlete: athleteId, referenceDate: referenceDate
        )

        #expect(results.count == 1)
        #expect(results.first?.isCompleted == false)
    }

    @Test("Logging an activity linked to a PlannedActivity marks it as completed")
    @MainActor
    func loggingLinkedActivityMarksCompletion() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let referenceDate = Date(timeIntervalSince1970: 1_767_312_000)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: referenceDate)
        let today = TrainingPlanningCoordinationService.today(referenceDate: referenceDate)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let plannedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        _ = try trainingService.logActivity(
            athleteId: athleteId,
            plannedActivityId: plannedActivity.plannedActivityId,
            activityType: .individualTraining,
            title: "Endurance run",
            startedAt: referenceDate,
            loggedByActorId: ActorId()
        )

        let results = try coordinationService.todaysPlannedActivitiesWithCompletion(
            forAthlete: athleteId, referenceDate: referenceDate
        )

        #expect(results.count == 1)
        #expect(results.first?.isCompleted == true)
    }

    @Test("Only today's planned activities are returned, in deterministic order, and no WeekPlan yields an empty result")
    @MainActor
    func onlyTodaysActivitiesReturnedDeterministically() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let noPlanAthleteId = AthleteId()
        let referenceDate = Date(timeIntervalSince1970: 1_767_312_000)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: referenceDate)
        let today = TrainingPlanningCoordinationService.today(referenceDate: referenceDate)
        let tomorrow = LocalDate(year: today.year, month: today.month, day: today.day + 1)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        // Out of alphabetical/insertion order deliberately.
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Zebra session", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Not today", localDate: tomorrow, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let results = try coordinationService.todaysPlannedActivitiesWithCompletion(
            forAthlete: athleteId, referenceDate: referenceDate
        )
        let noPlanResults = try coordinationService.todaysPlannedActivitiesWithCompletion(
            forAthlete: noPlanAthleteId, referenceDate: referenceDate
        )

        #expect(results.count == 1)
        #expect(results.first?.plannedActivity.title == "Zebra session")
        #expect(noPlanResults.isEmpty)
    }
}
