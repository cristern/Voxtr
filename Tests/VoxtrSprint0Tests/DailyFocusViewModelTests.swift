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

@Suite("DailyFocusViewModel (Sprint 13)", .serialized)
struct DailyFocusViewModelTests {

    private static let athleteId = AthleteId()
    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)
    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @MainActor
    private struct StubCoachingPresentationProvider: CoachingPresentationProviding {
        let presentation: CoachingPresentation
        func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
            presentation
        }
    }

    @MainActor
    private struct ThrowingCoachingPresentationProvider: CoachingPresentationProviding {
        struct TestError: Error {}
        func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
            throw TestError()
        }
    }

    private static let actionableCoaching = CoachingPresentation(
        athleteId: athleteId, weekStart: weekStart,
        sections: [CoachingPresentationSection(title: "Weekly Reflection", items: [
            CoachingPresentationItem(insight: .noWeeklyReflection, text: "No weekly reflection was recorded.", emphasis: .attention, action: .startWeeklyReflection),
        ])]
    )

    private static let noActionCoaching = CoachingPresentation(
        athleteId: athleteId, weekStart: weekStart,
        sections: [CoachingPresentationSection(title: "Weekly Reflection", items: [
            CoachingPresentationItem(insight: .weeklyReflectionCompleted, text: "A weekly reflection was recorded.", emphasis: .positive, action: .none),
        ])]
    )

    @Test("An incomplete planned activity today becomes the Daily Focus")
    @MainActor
    func incompleteTrainingBecomesFocus() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let today = LocalDate(
            year: Calendar.current.component(.year, from: .now),
            month: Calendar.current.component(.month, from: .now),
            day: Calendar.current.component(.day, from: .now)
        )
        let weekStart = WeeklyPlanningViewModel.currentWeekStart()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: today, timeZoneId: Self.oslo
        )
        let viewModel = DailyFocusViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: StubCoachingPresentationProvider(presentation: Self.actionableCoaching),
            athleteId: athleteId, weekStart: weekStart
        )

        viewModel.load()

        guard case .loaded(let focus) = viewModel.loadState, let focus else {
            Issue.record("Expected .loaded with a non-nil focus")
            return
        }
        #expect(focus.source == .todaysTraining)
        #expect(focus.title == "Endurance run")
    }

    @Test("An actionable coaching item becomes the Daily Focus when nothing incomplete is planned today")
    @MainActor
    func actionableCoachingBecomesFocusWhenNoIncompleteTraining() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let viewModel = DailyFocusViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: StubCoachingPresentationProvider(presentation: Self.actionableCoaching),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.load()

        guard case .loaded(let focus) = viewModel.loadState, let focus else {
            Issue.record("Expected .loaded with a non-nil focus")
            return
        }
        #expect(focus.source == .coaching)
        #expect(focus.title == "No weekly reflection was recorded.")
        #expect(focus.action == .startWeeklyReflection)
    }

    @Test("Today's training takes priority over an actionable coaching item when both are present")
    @MainActor
    func todaysTrainingHasPriorityOverCoaching() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let today = LocalDate(
            year: Calendar.current.component(.year, from: .now),
            month: Calendar.current.component(.month, from: .now),
            day: Calendar.current.component(.day, from: .now)
        )
        let weekStart = WeeklyPlanningViewModel.currentWeekStart()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: today, timeZoneId: Self.oslo
        )
        let viewModel = DailyFocusViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: StubCoachingPresentationProvider(presentation: Self.actionableCoaching),
            athleteId: athleteId, weekStart: weekStart
        )

        viewModel.load()

        guard case .loaded(let focus) = viewModel.loadState, let focus else {
            Issue.record("Expected .loaded with a non-nil focus")
            return
        }
        #expect(focus.source == .todaysTraining)
    }

    @Test("Nothing incomplete and no actionable coaching produces the empty state, not a failure")
    @MainActor
    func emptyStateWhenNothingQualifies() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let viewModel = DailyFocusViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: StubCoachingPresentationProvider(presentation: Self.noActionCoaching),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.load()

        guard case .loaded(let focus) = viewModel.loadState else {
            Issue.record("Expected .loaded, not .failed")
            return
        }
        #expect(focus == nil)
    }

    @Test("A coaching failure does not prevent a training-based focus from being produced")
    @MainActor
    func coachingFailureDoesNotPreventTrainingFocus() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let today = LocalDate(
            year: Calendar.current.component(.year, from: .now),
            month: Calendar.current.component(.month, from: .now),
            day: Calendar.current.component(.day, from: .now)
        )
        let weekStart = WeeklyPlanningViewModel.currentWeekStart()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: today, timeZoneId: Self.oslo
        )
        let viewModel = DailyFocusViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: ThrowingCoachingPresentationProvider(),
            athleteId: athleteId, weekStart: weekStart
        )

        viewModel.load()

        guard case .loaded(let focus) = viewModel.loadState, let focus else {
            Issue.record("A coaching failure must not prevent a training-based focus from being produced")
            return
        }
        #expect(focus.source == .todaysTraining)
    }

    @Test("Repeated composition of equivalent input produces equal presentation state")
    @MainActor
    func deterministicCompositionAcrossRepeatedCalls() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let viewModel = DailyFocusViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: StubCoachingPresentationProvider(presentation: Self.actionableCoaching),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.load()
        guard case .loaded(let first) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        viewModel.load()
        guard case .loaded(let second) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }

        #expect(first == second)
    }

    @Test("The coaching-derived focus matches CoachingApplicationService's own output exactly — no reinterpretation")
    @MainActor
    func noCoachingOrchestrationDuplication() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let provider = StubCoachingPresentationProvider(presentation: Self.actionableCoaching)
        let directResult = try provider.coachingPresentation(forAthlete: Self.athleteId, weekStart: Self.weekStart)
        let expectedItem = try #require(directResult.sections.first?.items.first)

        let viewModel = DailyFocusViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: provider,
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )
        viewModel.load()

        guard case .loaded(let focus) = viewModel.loadState, let focus else {
            Issue.record("Expected .loaded with a non-nil focus")
            return
        }
        #expect(focus.title == expectedItem.text)
        #expect(focus.action == expectedItem.action)
    }

    @Test("The training-derived focus's completion state matches TrainingPlanningCoordinationService's own output exactly — no recomputation")
    @MainActor
    func noTrainingLogicDuplication() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let today = LocalDate(
            year: Calendar.current.component(.year, from: .now),
            month: Calendar.current.component(.month, from: .now),
            day: Calendar.current.component(.day, from: .now)
        )
        let weekStart = WeeklyPlanningViewModel.currentWeekStart()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: today, timeZoneId: Self.oslo
        )

        let directActivities = try trainingPlanningCoordinationService.todaysPlannedActivitiesWithCompletion(forAthlete: athleteId)
        let expected = try #require(directActivities.first(where: { !$0.isCompleted }))

        let viewModel = DailyFocusViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: StubCoachingPresentationProvider(presentation: Self.actionableCoaching),
            athleteId: athleteId, weekStart: weekStart
        )
        viewModel.load()

        guard case .loaded(let focus) = viewModel.loadState, let focus else {
            Issue.record("Expected .loaded with a non-nil focus")
            return
        }
        #expect(focus.title == expected.plannedActivity.title)
    }
}
