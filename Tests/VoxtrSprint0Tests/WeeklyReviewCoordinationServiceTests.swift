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

@Suite("WeeklyReviewCoordinationService (Sprint 5.1)", .serialized)
struct WeeklyReviewCoordinationServiceTests {

    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)
    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @Test("A week with a plan, logged activities, and a reflection is assembled correctly")
    @MainActor
    func fullWeekAssembledCorrectly() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let planning = PlanningService(repository: planningRepository)
        let training = TrainingService(repository: trainingRepository)
        let reflection = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Easy jog",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 6)) ?? .now
        )
        _ = try reflection.recordWeeklyReflection(
            athleteId: athleteId, weekStart: Self.weekStart, authorId: ActorId(),
            overallSatisfaction: 4, visibility: .privateToAthlete
        )

        let result = try coordinator.weeklyReview(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(result.athleteId == athleteId)
        #expect(result.weekStart == Self.weekStart)
        #expect(result.weekPlan?.id == weekPlan.id)
        #expect(result.plannedActivities.count == 1)
        #expect(result.loggedActivities.count == 1)
        #expect(result.weeklyReflection?.overallSatisfaction == 4)
    }

    @Test("A planned activity with no matching log is returned as incomplete")
    @MainActor
    func plannedActivityWithoutLogIsIncomplete() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: Self.weekStart, timeZoneId: Self.oslo
        )

        let result = try coordinator.weeklyReview(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(result.plannedActivities.count == 1)
        #expect(result.plannedActivities.first?.isCompleted == false)
    }

    @Test("A logged activity linked to a planned activity is returned as completed")
    @MainActor
    func linkedLoggedActivityMarksCompletion() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let planning = PlanningService(repository: planningRepository)
        let training = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)
        let plannedActivity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: plannedActivity.plannedActivityId,
            activityType: .individualTraining, title: "Endurance run",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now
        )

        let result = try coordinator.weeklyReview(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(result.plannedActivities.count == 1)
        #expect(result.plannedActivities.first?.isCompleted == true)
    }

    @Test("An unplanned logged activity is included without inventing a planned activity")
    @MainActor
    func unplannedLoggedActivityIncludedWithoutInventingPlan() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let planning = PlanningService(repository: planningRepository)
        let training = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        _ = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)
        _ = try training.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Spontaneous run",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 7)) ?? .now
        )

        let result = try coordinator.weeklyReview(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(result.plannedActivities.isEmpty)
        #expect(result.loggedActivities.count == 1)
        #expect(result.loggedActivities.first?.title == "Spontaneous run")
    }

    @Test("Another athlete's data is excluded")
    @MainActor
    func anotherAthletesDataExcluded() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let planning = PlanningService(repository: planningRepository)
        let training = TrainingService(repository: trainingRepository)
        let reflection = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let otherWeekPlan = try planning.getOrCreateWeekPlan(athleteId: otherAthleteId, weekStart: Self.weekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: otherWeekPlan.weekPlanId, athleteId: otherAthleteId, activityType: .individualTraining,
            title: "Other athlete's plan", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: otherAthleteId, activityType: .individualTraining, title: "Other athlete's log",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 6)) ?? .now
        )
        _ = try reflection.recordWeeklyReflection(
            athleteId: otherAthleteId, weekStart: Self.weekStart, authorId: ActorId(), visibility: .privateToAthlete
        )

        let result = try coordinator.weeklyReview(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(result.weekPlan == nil)
        #expect(result.plannedActivities.isEmpty)
        #expect(result.loggedActivities.isEmpty)
        #expect(result.weeklyReflection == nil)
    }

    @Test("Another week's data is excluded")
    @MainActor
    func anotherWeeksDataExcluded() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let planning = PlanningService(repository: planningRepository)
        let training = TrainingService(repository: trainingRepository)
        let reflection = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let athleteId = AthleteId()
        let otherWeekStart = LocalDate(year: 2026, month: 1, day: 12)
        let otherWeekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: otherWeekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: otherWeekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Next week's plan", localDate: otherWeekStart, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Next week's log",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 13)) ?? .now
        )
        _ = try reflection.recordWeeklyReflection(
            athleteId: athleteId, weekStart: otherWeekStart, authorId: ActorId(), visibility: .privateToAthlete
        )

        let result = try coordinator.weeklyReview(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(result.weekPlan == nil)
        #expect(result.plannedActivities.isEmpty)
        #expect(result.loggedActivities.isEmpty)
        #expect(result.weeklyReflection == nil)
    }

    @Test("A missing plan is handled without error")
    @MainActor
    func missingPlanHandledWithoutError() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let athleteId = AthleteId()

        let result = try coordinator.weeklyReview(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(result.weekPlan == nil)
        #expect(result.plannedActivities.isEmpty)
    }

    @Test("A missing reflection is handled without error")
    @MainActor
    func missingReflectionHandledWithoutError() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        _ = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)

        let result = try coordinator.weeklyReview(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(result.weeklyReflection == nil)
    }

    @Test("Assembled activities are ordered deterministically across repeated calls")
    @MainActor
    func orderingIsDeterministic() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let planning = PlanningService(repository: planningRepository)
        let training = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)

        // Inserted out of chronological order deliberately.
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Thursday plan", localDate: LocalDate(year: 2026, month: 1, day: 8), timeZoneId: Self.oslo
        )
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Monday plan", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Wednesday log",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 7)) ?? .now
        )
        _ = try training.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Monday log",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now
        )

        let first = try coordinator.weeklyReview(forAthlete: athleteId, weekStart: Self.weekStart)
        let second = try coordinator.weeklyReview(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(first.plannedActivities.map(\.plannedActivity.title) == ["Monday plan", "Thursday plan"])
        #expect(first.loggedActivities.map(\.title) == ["Monday log", "Wednesday log"])
        #expect(first.plannedActivities.map(\.plannedActivity.id) == second.plannedActivities.map(\.plannedActivity.id))
        #expect(first.loggedActivities.map(\.id) == second.loggedActivities.map(\.id))
    }
}
