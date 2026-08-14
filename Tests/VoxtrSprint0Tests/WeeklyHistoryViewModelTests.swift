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
// Underlying assembly correctness (planned/logged dedup, unplanned
// inclusion, athlete/week isolation) is already proven by
// `WeeklyReviewCoordinationServiceTests` — `WeeklyHistoryViewModel`
// reuses that exact service, not a reimplementation, so these tests
// focus on this ViewModel's own thin presentation layer: counts,
// the privacy gate on Focus next week, and future-week blocking.

@Suite("WeeklyHistoryViewModel (Parent Time Navigation package)", .serialized)
struct WeeklyHistoryViewModelTests {

    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)
    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @Test("Planned, completed-from-plan, and additional counts are derived correctly from the canonical week assembly")
    @MainActor
    func countsAreDerivedCorrectly() throws {
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
        let planned = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Never logged", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: planned.plannedActivityId,
            activityType: .individualTraining, title: "Endurance run",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now
        )
        // Genuinely unplanned — no plannedActivityId at all.
        _ = try training.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Unplanned jog",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 6)) ?? .now
        )

        let viewModel = WeeklyHistoryViewModel(coordinationService: coordinator, athleteId: athleteId, weekStart: Self.weekStart)
        viewModel.load()

        #expect(viewModel.plannedCount == 2)
        #expect(viewModel.completedFromPlanCount == 1)
        #expect(viewModel.additionalCount == 1)
        #expect(viewModel.additionalLoggedActivities.first?.title == "Unplanned jog")
    }

    @Test("Focus next week is withheld when the reflection is marked privateToAthlete")
    @MainActor
    func focusWithheldWhenPrivate() throws {
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
        let reflection = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let athleteId = AthleteId()
        _ = try reflection.recordWeeklyReflection(
            athleteId: athleteId, weekStart: Self.weekStart, authorId: ActorId(),
            nextWeekConsideration: "Private content", visibility: .privateToAthlete
        )

        let viewModel = WeeklyHistoryViewModel(coordinationService: coordinator, athleteId: athleteId, weekStart: Self.weekStart)
        viewModel.load()

        #expect(viewModel.focusNextWeekIfPermitted == nil)
    }

    @Test("Focus next week is shown when the reflection is sharedWithGuardians")
    @MainActor
    func focusShownWhenShared() throws {
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
        let reflection = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let athleteId = AthleteId()
        _ = try reflection.recordWeeklyReflection(
            athleteId: athleteId, weekStart: Self.weekStart, authorId: ActorId(),
            nextWeekConsideration: "Shared content", visibility: .sharedWithGuardians
        )

        let viewModel = WeeklyHistoryViewModel(coordinationService: coordinator, athleteId: athleteId, weekStart: Self.weekStart)
        viewModel.load()

        #expect(viewModel.focusNextWeekIfPermitted == "Shared content")
    }

    @Test("switchToWeek never advances beyond the current Vǫxtr week")
    @MainActor
    func switchToWeekBlocksFutureWeek() throws {
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
        let currentWeekStart = TrainingPlanningCoordinationService.weekStart()
        let viewModel = WeeklyHistoryViewModel(coordinationService: coordinator, athleteId: athleteId, weekStart: currentWeekStart)

        viewModel.switchToWeek(currentWeekStart.adding(days: 7))

        // Rejected — weekStart is unchanged.
        #expect(viewModel.weekStart == currentWeekStart)
    }
}
