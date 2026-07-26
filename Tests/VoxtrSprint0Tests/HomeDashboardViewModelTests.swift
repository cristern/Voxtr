import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
@testable import VoxtrCoachingDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("HomeDashboardViewModel (Sprint 12)", .serialized)
struct HomeDashboardViewModelTests {

    private static let athleteId = AthleteId()
    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)
    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    /// Records exactly what it was called with and returns a
    /// pre-built `CoachingPresentation` unchanged — same pattern
    /// already established in `WeeklyReviewCoachingIntegrationTests`
    /// for verifying pure delegation.
    @MainActor
    private final class RecordingCoachingPresentationProvider: CoachingPresentationProviding {
        private(set) var receivedAthleteId: AthleteId?
        private(set) var receivedWeekStart: LocalDate?
        private(set) var callCount = 0
        let presentationToReturn: CoachingPresentation

        init(presentationToReturn: CoachingPresentation) {
            self.presentationToReturn = presentationToReturn
        }

        func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
            receivedAthleteId = athleteId
            receivedWeekStart = weekStart
            callCount += 1
            return presentationToReturn
        }
    }

    @MainActor
    private struct ThrowingCoachingPresentationProvider: CoachingPresentationProviding {
        struct TestError: Error {}
        func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
            throw TestError()
        }
    }

    /// Deterministic, no persistence — used only for
    /// `noOrchestrationDuplication`, which needs a real
    /// `CoachingApplicationService` (not a double for it) to prove the
    /// ViewModel isn't running a second, parallel orchestration.
    @MainActor
    private struct StubCoachingContextProvider: WeeklyCoachingContextProviding {
        let context: WeeklyCoachingContext
        func weeklyCoachingContext(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyCoachingContext {
            context
        }
    }

    /// Sprint 13 (architecture correction): `TrainingPlanningCoordinationService`
    /// is now protocol-injected (`TodaysTrainingProviding`) specifically
    /// so these two doubles can exist — deterministic call-count and
    /// independent-failure control were not possible against the
    /// concrete type.
    @MainActor
    private final class RecordingTodaysTrainingProvider: TodaysTrainingProviding {
        private(set) var callCount = 0
        let activitiesToReturn: [PlannedActivityCompletion]
        init(activitiesToReturn: [PlannedActivityCompletion]) {
            self.activitiesToReturn = activitiesToReturn
        }
        func todaysPlannedActivitiesWithCompletion(forAthlete athleteId: AthleteId) throws -> [PlannedActivityCompletion] {
            callCount += 1
            return activitiesToReturn
        }
    }

    @MainActor
    private struct ThrowingTodaysTrainingProvider: TodaysTrainingProviding {
        struct TestError: Error {}
        func todaysPlannedActivitiesWithCompletion(forAthlete athleteId: AthleteId) throws -> [PlannedActivityCompletion] {
            throw TestError()
        }
    }

    private static func makePlannedActivity(title: String) -> PlannedActivity {
        PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: athleteId, activityType: .individualTraining,
            title: title, localDate: weekStart, timeZoneId: oslo
        )
    }

    @Test("Today's training loads successfully from existing services, with completion already derived")
    @MainActor
    func todaysTrainingLoadsSuccessfully() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let planning = PlanningService(repository: planningRepository)
        let training = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let today = LocalDate(
            year: Calendar.current.component(.year, from: .now),
            month: Calendar.current.component(.month, from: .now),
            day: Calendar.current.component(.day, from: .now)
        )
        let weekStart = WeeklyPlanningViewModel.currentWeekStart()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let plannedActivity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: today, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: plannedActivity.plannedActivityId,
            activityType: .individualTraining, title: "Endurance run", startedAt: .now
        )
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteId, weekStart: weekStart
        )

        viewModel.loadTodaysTraining()

        guard case .loaded(let activities) = viewModel.todaysTrainingState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(activities.count == 1)
        #expect(activities.first?.isCompleted == true)
    }

    @Test("Coaching summary is delegated to the coaching application service, unchanged")
    @MainActor
    func coachingSummaryDelegatesToApplicationService() throws {
        let expected = CoachingPresentation(
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            sections: [CoachingPresentationSection(title: "Weekly Reflection", items: [
                CoachingPresentationItem(insight: .noWeeklyReflection, text: "No weekly reflection was recorded.", emphasis: .attention, action: .startWeeklyReflection),
            ])]
        )
        let provider = RecordingCoachingPresentationProvider(presentationToReturn: expected)
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: provider,
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingSummary()

        guard case .loaded(let presentation) = viewModel.coachingSummaryState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(presentation == expected)
        #expect(provider.receivedAthleteId == Self.athleteId)
        #expect(provider.receivedWeekStart == Self.weekStart)
        #expect(provider.callCount == 1)
    }

    @Test("Loading state transitions correctly: .loading before any load, .loaded after")
    @MainActor
    func loadingStateTransitionsCorrectly() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: Self.athleteId, weekStart: Self.weekStart, sections: [])
            ),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        guard case .loading = viewModel.todaysTrainingState else {
            Issue.record("Expected initial .loading")
            return
        }
        guard case .loading = viewModel.coachingSummaryState else {
            Issue.record("Expected initial .loading")
            return
        }

        viewModel.loadTodaysTraining()
        viewModel.loadCoachingSummary()

        guard case .loaded = viewModel.todaysTrainingState else {
            Issue.record("Expected .loaded after loadTodaysTraining()")
            return
        }
        guard case .loaded = viewModel.coachingSummaryState else {
            Issue.record("Expected .loaded after loadCoachingSummary()")
            return
        }
    }

    @Test("A genuine coaching failure becomes a controlled .failed state, never a successful empty presentation")
    @MainActor
    func coachingFailureBecomesControlledState() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: ThrowingCoachingPresentationProvider(),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingSummary()

        guard case .failed = viewModel.coachingSummaryState else {
            Issue.record("Expected .failed, not a successfully-loaded empty presentation")
            return
        }
    }

    @Test("A coaching failure does not block today's training from loading independently")
    @MainActor
    func coachingFailureDoesNotBlockTodaysTraining() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: ThrowingCoachingPresentationProvider(),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadTodaysTraining()
        viewModel.loadCoachingSummary()

        guard case .loaded = viewModel.todaysTrainingState else {
            Issue.record("Today's training must load independently of a coaching failure")
            return
        }
        guard case .failed = viewModel.coachingSummaryState else {
            Issue.record("Expected coaching state to be .failed")
            return
        }
    }

    @Test("The ViewModel's coaching output is identical to calling CoachingApplicationService directly — no second orchestration exists")
    @MainActor
    func noOrchestrationDuplication() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: .draft, plannedActivityCount: 2, completedPlannedActivityCount: 1,
            uncompletedPlannedActivityCount: 1, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 1,
            weeklyReflection: nil, parentObservations: []
        )
        let applicationService = CoachingApplicationService(
            coachingContextService: StubCoachingContextProvider(context: context)
        )
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: applicationService,
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        let directlyFromService = try applicationService.coachingPresentation(forAthlete: Self.athleteId, weekStart: Self.weekStart)
        viewModel.loadCoachingSummary()

        guard case .loaded(let fromViewModel) = viewModel.coachingSummaryState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(fromViewModel == directlyFromService)
    }

    // MARK: - Sprint 13 (architecture correction): dailyFocusState derivation

    @Test("Neither source finished loading yet — dailyFocusState is .loading")
    @MainActor
    func dailyFocusStateLoadingWhileNeitherSourceFinished() throws {
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: RecordingTodaysTrainingProvider(activitiesToReturn: []),
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: Self.athleteId, weekStart: Self.weekStart, sections: [])
            ),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        // Neither loadTodaysTraining() nor loadCoachingSummary() called yet.
        guard case .loading = viewModel.dailyFocusState else {
            Issue.record("Expected .loading before either source has settled")
            return
        }
    }

    @Test("Both sources loaded — Daily Focus is composed from both")
    @MainActor
    func dailyFocusStateBothLoadedComposesFromBoth() throws {
        let activities = [PlannedActivityCompletion(plannedActivity: Self.makePlannedActivity(title: "Endurance run"), isCompleted: false)]
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: RecordingTodaysTrainingProvider(activitiesToReturn: activities),
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: Self.athleteId, weekStart: Self.weekStart, sections: [])
            ),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadTodaysTraining()
        viewModel.loadCoachingSummary()

        guard case .loaded(let focus) = viewModel.dailyFocusState, let focus else {
            Issue.record("Expected .loaded with a non-nil focus")
            return
        }
        #expect(focus.source == .todaysTraining)
        #expect(focus.title == "Endurance run")
    }

    @Test("Training loaded, coaching failed — Daily Focus is still composed from training")
    @MainActor
    func dailyFocusStateTrainingLoadedCoachingFailed() throws {
        let activities = [PlannedActivityCompletion(plannedActivity: Self.makePlannedActivity(title: "Endurance run"), isCompleted: false)]
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: RecordingTodaysTrainingProvider(activitiesToReturn: activities),
            coachingPresentationProvider: ThrowingCoachingPresentationProvider(),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadTodaysTraining()
        viewModel.loadCoachingSummary()

        guard case .loaded(let focus) = viewModel.dailyFocusState, let focus else {
            Issue.record("A coaching failure must not prevent a training-based Daily Focus")
            return
        }
        #expect(focus.source == .todaysTraining)
    }

    @Test("Coaching loaded, training failed — Daily Focus is still composed from coaching")
    @MainActor
    func dailyFocusStateCoachingLoadedTrainingFailed() throws {
        let actionableCoaching = CoachingPresentation(
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            sections: [CoachingPresentationSection(title: "Weekly Reflection", items: [
                CoachingPresentationItem(insight: .noWeeklyReflection, text: "No weekly reflection was recorded.", emphasis: .attention, action: .startWeeklyReflection),
            ])]
        )
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: ThrowingTodaysTrainingProvider(),
            coachingPresentationProvider: RecordingCoachingPresentationProvider(presentationToReturn: actionableCoaching),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadTodaysTraining()
        viewModel.loadCoachingSummary()

        guard case .loaded(let focus) = viewModel.dailyFocusState, let focus else {
            Issue.record("A training failure must not prevent a coaching-based Daily Focus")
            return
        }
        #expect(focus.source == .coaching)
    }

    @Test("Both sources failed — dailyFocusState is .failed, hiding the card")
    @MainActor
    func dailyFocusStateBothFailedHidesCard() throws {
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: ThrowingTodaysTrainingProvider(),
            coachingPresentationProvider: ThrowingCoachingPresentationProvider(),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadTodaysTraining()
        viewModel.loadCoachingSummary()

        guard case .failed = viewModel.dailyFocusState else {
            Issue.record("Expected .failed when both sources fail")
            return
        }
    }

    @Test("Both loaded but nothing qualifies — dailyFocusState is .loaded(nil), not .failed")
    @MainActor
    func dailyFocusStateNoQualifyingFocus() throws {
        let completedActivity = [PlannedActivityCompletion(plannedActivity: Self.makePlannedActivity(title: "Endurance run"), isCompleted: true)]
        let noActionCoaching = CoachingPresentation(
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            sections: [CoachingPresentationSection(title: "Weekly Reflection", items: [
                CoachingPresentationItem(insight: .weeklyReflectionCompleted, text: "A weekly reflection was recorded.", emphasis: .positive, action: .none),
            ])]
        )
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: RecordingTodaysTrainingProvider(activitiesToReturn: completedActivity),
            coachingPresentationProvider: RecordingCoachingPresentationProvider(presentationToReturn: noActionCoaching),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadTodaysTraining()
        viewModel.loadCoachingSummary()

        guard case .loaded(let focus) = viewModel.dailyFocusState else {
            Issue.record("Expected .loaded, not .failed")
            return
        }
        #expect(focus == nil)
    }

    @Test("HomeDashboardViewModel performs exactly one training load and one coaching load per requested dashboard load — Daily Focus composition triggers zero additional service calls")
    @MainActor
    func singleLoadingOwnerNoDuplicateServiceCalls() throws {
        let activities = [PlannedActivityCompletion(plannedActivity: Self.makePlannedActivity(title: "Endurance run"), isCompleted: false)]
        let trainingProvider = RecordingTodaysTrainingProvider(activitiesToReturn: activities)
        let coachingProvider = RecordingCoachingPresentationProvider(
            presentationToReturn: CoachingPresentation(athleteId: Self.athleteId, weekStart: Self.weekStart, sections: [])
        )
        let viewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingProvider,
            coachingPresentationProvider: coachingProvider,
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadTodaysTraining()
        viewModel.loadCoachingSummary()

        #expect(trainingProvider.callCount == 1)
        #expect(coachingProvider.callCount == 1)

        // Reading dailyFocusState — including repeatedly — must not
        // call either service again. Composition is a pure derivation
        // over already-loaded state.
        _ = viewModel.dailyFocusState
        _ = viewModel.dailyFocusState
        _ = viewModel.dailyFocusState

        #expect(trainingProvider.callCount == 1)
        #expect(coachingProvider.callCount == 1)
    }
}
