import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
@testable import VoxtrCoachingDomain
import VoxtrAthleteDomain
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

    @Test("Planning edit and delete make a live Athlete Home refetch canonical truth")
    @MainActor
    func planningMutationsRefreshLiveAthleteHomeFromRepository() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let broadcaster = AthleteActivityChangeBroadcaster()
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let original = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Original", localDate: today, timeZoneId: Self.oslo
        )
        let home = HomeDashboardViewModel(
            trainingPlanningCoordinationService: coordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteId, weekStart: weekStart,
            activityChangeBroadcaster: broadcaster
        )
        let planning = WeeklyPlanningViewModel(
            service: planningService, athleteId: athleteId, committedByActorId: ActorId(),
            weekStart: weekStart, activityChangeBroadcaster: broadcaster
        )
        planning.loadOrCreateWeekPlan()
        home.loadTodaysTraining()

        planning.editActivity(original, title: "Updated", localDate: today, activityType: .teamTraining)

        guard case .loaded(let editedRows) = home.todaysTrainingState else {
            Issue.record("Expected Athlete Home to reload after Planning edit")
            return
        }
        #expect(editedRows.count == 1)
        #expect(editedRows.first?.plannedActivity.plannedActivityId == original.plannedActivityId)
        #expect(editedRows.first?.plannedActivity.title == Optional("Updated"))

        let fetched = try planningRepository.fetchPlannedActivity(byId: original.plannedActivityId)
        let updated = try #require(fetched)
        planning.deleteActivity(updated)

        guard case .loaded(let deletedRows) = home.todaysTrainingState else {
            Issue.record("Expected Athlete Home to reload after Planning delete")
            return
        }
        #expect(deletedRows.isEmpty)
        #expect(try planningRepository.fetchPlannedActivity(byId: original.plannedActivityId) == nil)
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
            athleteId: athleteId, weekStart: weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
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

    // MARK: - Athlete Home stale-state fix (post-mutation navigation)

    /// Reproduces the exact TestFlight-reported gap end to end, using
    /// the same production construction `HomeDashboardView.todayActivityRow`
    /// itself uses: `ActivityDetailViewModel` (the same type
    /// `ActivityDetailViewLoader` constructs) wired with
    /// `onActivityLogged` calling `HomeDashboardViewModel`'s own
    /// `loadTodaysTraining()`/`loadTodayActivityRows()` — exactly what
    /// `HomeDashboardView`'s row does. A real `LogActivityViewModel.save()`
    /// through the canonical `TrainingReflectionCoordinationService`
    /// path must cause `HomeDashboardViewModel`'s OWN read/composition
    /// to reflect the fresh canonical `LoggedActivity` relationship —
    /// never a stale "not yet logged" presentation.
    @Test("A successful planned-activity log causes HomeDashboardViewModel's canonical read to reflect logged state")
    @MainActor
    func successfulLogReflectsInHomeDashboardCanonicalState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: today, timeZoneId: Self.oslo
        )

        let homeDashboardViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteId, weekStart: weekStart,
            todayActivityComposer: TodayActivityComposer(
                planningService: planningService, trainingService: trainingService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService
            ),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
        homeDashboardViewModel.loadTodaysTraining()
        homeDashboardViewModel.loadTodayActivityRows()

        guard case .loaded(let rowsBefore) = homeDashboardViewModel.todayActivityState,
              case .planned(let plannedRowBefore) = rowsBefore.first(where: { $0.id == activity.id.uuidString }) else {
            Issue.record("Expected a .planned row for the activity before logging")
            return
        }
        #expect(plannedRowBefore.isCompleted == false)
        #expect(plannedRowBefore.outcomeStatus == nil)

        // Mirrors HomeDashboardView.todayActivityRow's own
        // onActivityLogged wiring exactly.
        let detailViewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: trainingReflectionCoordinationService,
            onActivityLogged: {
                homeDashboardViewModel.loadTodaysTraining()
                homeDashboardViewModel.loadTodayActivityRows()
            }
        )
        let logViewModel = detailViewModel.makeLogActivityViewModel()
        // Planned/Logged Activity lifecycle consistency cleanup: actual
        // duration is required for a completed log; `activity` itself
        // has no planned duration, so it must be entered explicitly.
        logViewModel.durationMinutes = 45
        logViewModel.sessionForm = 3

        #expect(logViewModel.save())

        guard case .loaded(let rowsAfter) = homeDashboardViewModel.todayActivityState,
              case .planned(let plannedRowAfter) = rowsAfter.first(where: { $0.id == activity.id.uuidString }) else {
            Issue.record("Expected a .planned row for the activity after logging")
            return
        }
        #expect(plannedRowAfter.isCompleted == true)
        #expect(plannedRowAfter.outcomeStatus == .completed)

        guard case .loaded(let trainingAfter) = homeDashboardViewModel.todaysTrainingState else {
            Issue.record("Expected .loaded after logging")
            return
        }
        #expect(trainingAfter.first { $0.plannedActivity.plannedActivityId == activity.plannedActivityId }?.isCompleted == true)
    }

    /// Activity outcome consistency closeout (item B): Athlete Home
    /// (`HomeDashboardView`) used the same loose `familyHomeRow.isCompleted`
    /// binary to choose between `TrainingStrings.completedLabel`/
    /// `notCompletedLabel` — a Cancelled activity displayed as
    /// Completed. `outcomeStatus` (backed by the real `LoggedActivity`)
    /// is the fix.
    @Test("A Cancelled planned activity is exposed with outcomeStatus == .cancelled on HomeDashboardViewModel's canonical read — never .completed")
    @MainActor
    func cancelledActivityExposesCancelledOutcomeOnHomeDashboard() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: today, timeZoneId: Self.oslo
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: "Evening swim", startedAt: .now,
            durationMinutes: 1, status: .cancelled
        )

        let homeDashboardViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteId, weekStart: weekStart,
            todayActivityComposer: TodayActivityComposer(
                planningService: planningService, trainingService: trainingService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService
            ),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
        homeDashboardViewModel.loadTodayActivityRows()

        guard case .loaded(let rows) = homeDashboardViewModel.todayActivityState,
              case .planned(let row) = rows.first(where: { $0.id == activity.id.uuidString }) else {
            Issue.record("Expected a .planned row for the cancelled activity")
            return
        }
        // Still "resolved" (an outcome exists — never offered as Log
        // Activity again)...
        #expect(row.isCompleted == true)
        // ...but the REAL outcome is Cancelled, never Completed.
        #expect(row.outcomeStatus == .cancelled)
        #expect(TrainingStrings.outcomeLabel(for: row.outcomeStatus) == TrainingStrings.cancelledLabel)
    }

    /// Athlete isolation: two athletes, each with their own planned
    /// activity today. Logging one athlete's activity, through the
    /// exact same `onActivityLogged`-driven reload, must never mark a
    /// DIFFERENT athlete's own planned activity as completed — the
    /// canonical read is always scoped by the exact `AthleteId`, never
    /// inferred from title/date or shared across athletes.
    @Test("Logging one athlete's planned activity never marks a different athlete's own planned activity as completed")
    @MainActor
    func loggingOneAthleteNeverAffectsAnother() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteA = AthleteId()
        let athleteB = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlanA = try planningService.getOrCreateWeekPlan(athleteId: athleteA, weekStart: weekStart)
        let weekPlanB = try planningService.getOrCreateWeekPlan(athleteId: athleteB, weekStart: weekStart)
        let activityA = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanA.weekPlanId, athleteId: athleteA, activityType: .individualTraining,
            title: "Athlete A run", localDate: today, timeZoneId: Self.oslo
        )
        let activityB = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanB.weekPlanId, athleteId: athleteB, activityType: .individualTraining,
            title: "Athlete B run", localDate: today, timeZoneId: Self.oslo
        )

        func makeComposer() -> TodayActivityComposer {
            TodayActivityComposer(
                planningService: planningService, trainingService: trainingService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService
            )
        }
        let homeDashboardViewModelA = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteA, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteA, weekStart: weekStart, todayActivityComposer: makeComposer(),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
        let homeDashboardViewModelB = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteB, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteB, weekStart: weekStart, todayActivityComposer: makeComposer(),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
        homeDashboardViewModelA.loadTodayActivityRows()
        homeDashboardViewModelB.loadTodayActivityRows()

        let detailViewModelA = ActivityDetailViewModel(
            activity: activityA, isCompleted: false, weekPlanId: weekPlanA.weekPlanId,
            athleteId: athleteA, athleteDisplayName: "Athlete A", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: trainingReflectionCoordinationService,
            onActivityLogged: { homeDashboardViewModelA.loadTodayActivityRows() }
        )
        let logA = detailViewModelA.makeLogActivityViewModel()
        // Planned/Logged Activity lifecycle consistency cleanup: actual
        // duration is required for a completed log; `activityA` has no
        // planned duration, so it must be entered explicitly.
        logA.durationMinutes = 45
        logA.sessionForm = 3
        #expect(logA.save())

        guard case .loaded(let rowsA) = homeDashboardViewModelA.todayActivityState,
              case .planned(let rowA) = rowsA.first(where: { $0.id == activityA.id.uuidString }) else {
            Issue.record("Expected a .planned row for athlete A's activity")
            return
        }
        #expect(rowA.isCompleted == true)

        // Reloaded fresh for athlete B — never touched by athlete A's
        // log or reload.
        homeDashboardViewModelB.loadTodayActivityRows()
        guard case .loaded(let rowsB) = homeDashboardViewModelB.todayActivityState,
              case .planned(let rowB) = rowsB.first(where: { $0.id == activityB.id.uuidString }) else {
            Issue.record("Expected a .planned row for athlete B's activity")
            return
        }
        #expect(rowB.isCompleted == false)
    }

    /// Failure must not trigger a success refresh/navigation path: when
    /// `save()` fails (Form required but missing for a completed log),
    /// `onActivityLogged` must never fire, and HomeDashboardViewModel's
    /// own canonical state must still show the activity as not
    /// completed — never a false "logged" presentation.
    @Test("A failed planned-activity log does not produce a false completed presentation and does not trigger a reload")
    @MainActor
    func failedLogDoesNotProduceFalseCompletedPresentation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: today, timeZoneId: Self.oslo
        )

        let homeDashboardViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteId, weekStart: weekStart,
            todayActivityComposer: TodayActivityComposer(
                planningService: planningService, trainingService: trainingService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService
            ),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
        homeDashboardViewModel.loadTodayActivityRows()

        var reloadCallCount = 0
        let detailViewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: trainingReflectionCoordinationService,
            onActivityLogged: {
                reloadCallCount += 1
                homeDashboardViewModel.loadTodayActivityRows()
            }
        )
        let logViewModel = detailViewModel.makeLogActivityViewModel()
        // sessionForm left nil — Form is required for a completed log.

        #expect(logViewModel.save() == false)
        #expect(reloadCallCount == 0)

        guard case .loaded(let rows) = homeDashboardViewModel.todayActivityState,
              case .planned(let row) = rows.first(where: { $0.id == activity.id.uuidString }) else {
            Issue.record("Expected a .planned row for the activity")
            return
        }
        #expect(row.isCompleted == false)
    }

    // MARK: - TestFlight regression: stale mounted Athlete Home after Log/Cancel

    /// The prior test (`successfulLogReflectsInHomeDashboardCanonicalState`)
    /// already proved the reload callback fires and `HomeDashboardViewModel`'s
    /// OWN canonical state comes back fresh — and TestFlight still showed
    /// a stale row. The actual defect was in `HomeDashboardView`'s row
    /// navigation: `NavigationLink(destination: ActivityDetailViewLoader(...))`
    /// (the legacy, eager-destination form) captured `FamilyHomeRow` at
    /// row-render time as part of ONE `NavigationLink` value tied to a
    /// single push identity, instead of resolving it fresh each time.
    /// The fix extracts that resolution into `HomeDashboardRowResolver`
    /// — a plain function of whatever `TodayActivityLoadState` is passed
    /// to it, called by `.navigationDestination(for:)` on every
    /// invocation. This test proves exactly that: the SAME row id,
    /// resolved against a state captured BEFORE a mutation and again
    /// against a state loaded AFTER one, returns the CORRECT, DIFFERENT
    /// outcome each time — not a value frozen at the first resolution.
    @Test("HomeDashboardRowResolver.plannedRow resolves the fresh outcome from a newly-loaded state, never a value frozen from an earlier state")
    @MainActor
    func rowResolverReflectsFreshStateAfterMutation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: today, timeZoneId: Self.oslo
        )
        let rowId = activity.id.uuidString

        let homeDashboardViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteId, weekStart: weekStart,
            todayActivityComposer: TodayActivityComposer(
                planningService: planningService, trainingService: trainingService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService
            ),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
        homeDashboardViewModel.loadTodayActivityRows()
        // Captured once, exactly like a `NavigationLink(destination:)`
        // row builder would have captured it — this is the OLD state on
        // purpose, to prove resolving against it is genuinely different
        // from resolving against the fresh one below.
        let stateBeforeMutation = homeDashboardViewModel.todayActivityState

        guard let rowBefore = HomeDashboardRowResolver.plannedRow(forId: rowId, in: stateBeforeMutation) else {
            Issue.record("Expected a .planned row before the mutation")
            return
        }
        #expect(rowBefore.outcomeStatus == nil)

        // The mutation: Cancel Activity, through the exact same
        // canonical path ActivityDetailViewModel.cancelActivity() uses.
        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: activity.title, startedAt: .now,
            durationMinutes: 1, status: .cancelled
        )
        // Mirrors HomeDashboardView's onActivityLogged reload exactly.
        homeDashboardViewModel.loadTodaysTraining()
        homeDashboardViewModel.loadTodayActivityRows()
        let stateAfterMutation = homeDashboardViewModel.todayActivityState

        // Resolving the SAME rowId against the FRESH state must return
        // the new outcome...
        guard let rowAfter = HomeDashboardRowResolver.plannedRow(forId: rowId, in: stateAfterMutation) else {
            Issue.record("Expected a .planned row after the mutation")
            return
        }
        #expect(rowAfter.outcomeStatus == .cancelled)

        // ...while resolving against the OLD, already-captured state
        // (exactly what a stale `NavigationLink(destination:)` capture
        // would have done) still correctly reflects what THAT state
        // actually held — proving the resolver has no hidden memoization
        // of its own; the fix is that `.navigationDestination(for:)`
        // always passes the CURRENT `viewModel.todayActivityState`, never
        // a value captured once at row-render time.
        guard let rowStillBefore = HomeDashboardRowResolver.plannedRow(forId: rowId, in: stateBeforeMutation) else {
            Issue.record("Expected the old captured state to still resolve consistently")
            return
        }
        #expect(rowStillBefore.outcomeStatus == nil)
    }

    /// Same proof for the recurring-occurrence resolution path — the
    /// other case `HomeDashboardView`'s row navigation covers.
    @Test("HomeDashboardRowResolver.recurringSuggestion resolves against whatever TodayActivityLoadState it is given, never a fixed snapshot")
    func rowResolverForRecurringOccurrenceReadsGivenState() throws {
        let athleteId = AthleteId()
        let suggestion = RecurringActivitySuggestion(
            id: "recurring-1", recurringPlannedActivityId: RecurringPlannedActivityId(),
            athleteId: athleteId, occurrenceDate: LocalDate(year: 2026, month: 1, day: 5),
            title: "Saturday run", activityType: .individualTraining, sportId: nil, categoryIds: [],
            startLocalTime: nil, plannedDurationMinutes: nil, timeZoneId: Self.oslo, location: nil
        )
        let stateWithSuggestion: TodayActivityLoadState = .loaded([
            .recurringOccurrence(athleteId: athleteId, athleteName: "Oliver", suggestion: suggestion),
        ])
        let emptyState: TodayActivityLoadState = .loaded([])

        #expect(HomeDashboardRowResolver.recurringSuggestion(forId: suggestion.id, in: stateWithSuggestion)?.id == suggestion.id)
        // The identical id resolves to nothing once the occurrence is no
        // longer present in the state passed in (e.g. materialized into
        // a real PlannedActivity by a Log Activity elsewhere) — proving
        // resolution is driven entirely by the state argument, not by
        // anything remembered from a previous call.
        #expect(HomeDashboardRowResolver.recurringSuggestion(forId: suggestion.id, in: emptyState) == nil)
    }

    // MARK: - Recurring reopen stale-Athlete-Home fix (architecture round)

    /// Reproduces the exact TestFlight-reported shape end to end, and
    /// proves the shared-broadcaster redesign closes it regardless of
    /// origin: a recurring occurrence is materialized+cancelled, then
    /// reopened through a SEPARATE `TrainingReflectionCoordinationService`
    /// instance — never through this `HomeDashboardViewModel`'s own
    /// `onActivityLogged` wiring, standing in for "the mutation happened
    /// via Family Home's own row, Family Schedule, or Daily Training
    /// nested under this very screen" — the mutation origin never
    /// determines whether this ViewModel goes stale, since both
    /// coordinator instances share the SAME `AthleteActivityChangeBroadcaster`,
    /// exactly as `CompositionRoot` wires it in production. Also proves:
    /// same materialized `PlannedActivity` identity, no linked
    /// `LoggedActivity`, recurring series/provenance unchanged, and no
    /// duplicate recurring suggestion/materialization.
    @Test("A HomeDashboardViewModel already showing a cancelled recurring occurrence becomes canonical unresolved state after a reopen triggered outside its own navigation subtree")
    @MainActor
    func recurringReopenOutsideOwnSubtreeInvalidatesLiveViewModel() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))

        // The ONE shared broadcaster, exactly as CompositionRoot builds
        // it once and hands it to every TrainingReflectionCoordinationService
        // AND every HomeDashboardViewModel this app run constructs.
        let activityChangeBroadcaster = AthleteActivityChangeBroadcaster()

        // The coordinator this test's "Athlete Home" screen itself would
        // use for its OWN navigation (unused for the mutation below —
        // the reopen deliberately goes through a DIFFERENT instance).
        let athleteHomeCoordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService,
            activityChangeBroadcaster: activityChangeBroadcaster,
            modelContext: container.mainContext
        )
        // A SEPARATE coordinator instance, standing in for whichever
        // OTHER screen actually performs the mutation — sharing the same
        // TrainingService/ReflectionService (same canonical persistence)
        // and the same broadcaster, but never the same object identity
        // as athleteHomeCoordinator.
        let otherScreenCoordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService,
            activityChangeBroadcaster: activityChangeBroadcaster,
            modelContext: container.mainContext
        )

        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let recurringActivity = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: Self.oslo,
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )
        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let suggestion = try #require(suggestions.first)

        // "Cancel this occurrence" (RecurringOccurrencePreviewView.cancelOccurrence()):
        // materialize, then link a .cancelled LoggedActivity — through
        // whichever coordinator; persistence is canonical regardless.
        let materialized = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
        let cancelResult = try otherScreenCoordinator.logActivity(
            athleteId: athleteId, plannedActivityId: materialized.plannedActivityId,
            activityType: materialized.activityType, title: materialized.title, startedAt: .now,
            durationMinutes: 1, status: .cancelled, authorId: ActorId(), sessionForm: nil
        )

        // Athlete Home: constructed WITH the shared broadcaster, so its
        // HomeDashboardViewModel subscribes for this athleteId at
        // construction — matching production's
        // FamilyHomeContentView.athleteOverview(for:)/HomeDashboardView's
        // own "Manage Athletes" sheet/ParentTabShellView's Profile tab,
        // every one of which now passes activityChangeBroadcaster
        // through.
        let homeDashboardViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteId, weekStart: weekStart,
            todayActivityComposer: TodayActivityComposer(
                planningService: planningService, trainingService: trainingService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService
            ),
            activityChangeBroadcaster: activityChangeBroadcaster
        )
        homeDashboardViewModel.loadTodayActivityRows()

        guard case .loaded(let rowsAfterCancel) = homeDashboardViewModel.todayActivityState,
              case .planned(let cancelledRow) = rowsAfterCancel.first(where: { $0.id == materialized.plannedActivityId.rawValue.uuidString }) else {
            Issue.record("Expected a .planned cancelled row on HomeDashboardViewModel")
            return
        }
        #expect(cancelledRow.outcomeStatus == .cancelled)

        // The reopen: through otherScreenCoordinator — a DIFFERENT
        // TrainingReflectionCoordinationService instance than
        // athleteHomeCoordinator (which HomeDashboardViewModel's own
        // navigation would use) — never through
        // homeDashboardViewModel.loadTodaysTraining()/loadTodayActivityRows()
        // directly, and never through athleteHomeCoordinator at all.
        try otherScreenCoordinator.reopenNoTrainingOutcome(
            cancelResult.loggedActivity.loggedActivityId, athleteId: athleteId
        )
        // athleteHomeCoordinator exists only to prove it was never the
        // one that performed this mutation.
        _ = athleteHomeCoordinator

        // No explicit reload call on homeDashboardViewModel anywhere
        // above or below this line — the broadcaster already invalidated
        // it synchronously, inside the call to reopenNoTrainingOutcome.
        guard case .loaded(let freshRows) = homeDashboardViewModel.todayActivityState,
              case .planned(let freshRow) = freshRows.first(where: { $0.id == materialized.plannedActivityId.rawValue.uuidString }) else {
            Issue.record("Expected the fresh .planned row after the broadcaster's automatic reload")
            return
        }
        // 7: same materialized PlannedActivity identity throughout.
        #expect(freshRow.plannedActivity.plannedActivityId == materialized.plannedActivityId)
        // No linked LoggedActivity — genuinely unresolved again.
        #expect(freshRow.outcomeStatus == nil)
        #expect(freshRow.isCompleted == false)
        // Recurring series/provenance untouched.
        #expect(freshRow.isFromRecurring == true)
        #expect(freshRow.plannedActivity.externalSourceType == RecurringPlannedActivity.externalSourceType)
        let stillEnabled = try planningService.fetchRecurringPlannedActivity(byId: recurringActivity.recurringPlannedActivityId)
        #expect(stillEnabled?.isEnabled == true)
        // 8: exactly one visible canonical row for this occurrence —
        // never a duplicate recurring suggestion/materialization.
        #expect(freshRows.filter { $0.id == materialized.plannedActivityId.rawValue.uuidString }.count == 1)
        #expect(freshRows.contains { row in
            if case .recurringOccurrence(_, _, let s) = row { return s.id == suggestion.id }
            return false
        } == false)
    }

    // MARK: - Review follow-up: deterministic subscription cleanup

    /// Proves the ACTUAL lifecycle hook, not a manually-constructed test
    /// subscriber calling `unsubscribe` itself: a real
    /// `HomeDashboardViewModel` subscribes at construction, and its
    /// entry is verifiably GONE (not merely skipped as a dead weak
    /// reference at the next broadcast) once its subscription lifetime
    /// ends — proven via `AthleteActivityChangeBroadcaster.subscriberCount(for:)`,
    /// a `@testable`-only introspection seam, since `subscribersByAthlete`
    /// itself is private. Also proves "preserve multiple subscribers per
    /// athlete": a second, still-live `HomeDashboardViewModel` for the
    /// SAME athlete is completely unaffected by the first one's release
    /// — the count drops from 2 to 1, never to 0.
    @Test("A HomeDashboardViewModel's subscription is deterministically removed when its subscription lifetime ends, without affecting another live subscriber for the same athlete")
    @MainActor
    func homeDashboardViewModelSubscriptionRemovedWhenReleased() throws {
        let broadcaster = AthleteActivityChangeBroadcaster()
        let athleteId = AthleteId()

        func makeViewModel(trainingProvider: RecordingTodaysTrainingProvider) -> HomeDashboardViewModel {
            HomeDashboardViewModel(
                trainingPlanningCoordinationService: trainingProvider,
                coachingPresentationProvider: RecordingCoachingPresentationProvider(
                    presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: Self.weekStart, sections: [])
                ),
                athleteId: athleteId, weekStart: Self.weekStart,
                activityChangeBroadcaster: broadcaster
            )
        }

        // 1: two real HomeDashboardViewModels for the same athlete.
        let survivorTrainingProvider = RecordingTodaysTrainingProvider(activitiesToReturn: [])
        let survivor = makeViewModel(trainingProvider: survivorTrainingProvider)
        var shortLived: HomeDashboardViewModel? = makeViewModel(trainingProvider: RecordingTodaysTrainingProvider(activitiesToReturn: []))
        // 2: broadcaster subscriberCount == 2.
        #expect(broadcaster.subscriberCount(for: athleteId) == 2)

        // 3: release one ViewModel. Its own subscription-lifetime object
        // (`ActivityChangeSubscription`, held only by the released
        // HomeDashboardViewModel) is deallocated by ARC in the same,
        // uninterrupted step — no actor hop, no `Task`, no polling — and
        // its own ordinary `deinit` calls `unsubscribe` synchronously.
        shortLived = nil

        // 4: subscriberCount becomes exactly 1 — proves the released
        // instance's cleanup removed exactly ITS OWN token, never the
        // survivor's, concurrently-live, different token for the same
        // athlete.
        #expect(broadcaster.subscriberCount(for: athleteId) == 1)

        // 5: the remaining subscriber still receives future invalidation
        // — proves the survivor's own subscription is not merely present
        // in the count but genuinely still live/functional.
        #expect(survivorTrainingProvider.callCount == 0)
        broadcaster.activityChanged(for: athleteId)
        #expect(survivorTrainingProvider.callCount == 1)
    }

    // MARK: - P0 crash fix: delete no longer leaves stale/deleted-entity state

    /// Reproduces the shared layer both TestFlight repros (Family Home →
    /// Activity → Delete, Athlete Home → Activity → Delete) go through:
    /// `ActivityDetailViewModel.deleteActivity()`, now wired with the
    /// SAME `onActivityLogged` reload contract `cancelActivity()`/
    /// `reopenActivity()` already have. Proves: (1) a normal
    /// `PlannedActivity` deletes through the shared flow and is
    /// genuinely gone canonically, not merely locally flagged; (2) a
    /// fresh composition afterward no longer references it; (3) no
    /// duplicate/stale row remains, and a DIFFERENT activity for the
    /// same athlete is untouched.
    @Test("Deleting a normal PlannedActivity through ActivityDetailViewModel removes it from HomeDashboardViewModel's canonical composition, with no stale or duplicate row")
    @MainActor
    func deleteActivityRemovesItFromCanonicalComposition() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: today, timeZoneId: Self.oslo
        )
        let keptActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: today, timeZoneId: Self.oslo
        )

        let homeDashboardViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteId, weekStart: weekStart,
            todayActivityComposer: TodayActivityComposer(
                planningService: planningService, trainingService: trainingService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService
            ),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
        homeDashboardViewModel.loadTodayActivityRows()

        guard case .loaded(let rowsBeforeDelete) = homeDashboardViewModel.todayActivityState else {
            Issue.record("Expected .loaded before delete")
            return
        }
        #expect(rowsBeforeDelete.contains { $0.id == activity.id.uuidString })
        #expect(rowsBeforeDelete.contains { $0.id == keptActivity.id.uuidString })

        let detailViewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: trainingReflectionCoordinationService,
            onActivityLogged: {
                homeDashboardViewModel.loadTodaysTraining()
                homeDashboardViewModel.loadTodayActivityRows()
            }
        )

        #expect(detailViewModel.isDeleted == false)
        #expect(detailViewModel.deleteActivity() == true)
        // 1: genuinely gone canonically, not merely locally flagged.
        #expect(detailViewModel.isDeleted == true)
        let remainingActivities = try planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        #expect(remainingActivities.contains { $0.plannedActivityId == activity.plannedActivityId } == false)

        // 2/3: a fresh composition, reread via the SAME onActivityLogged
        // callback every other mutation on this screen already fires, no
        // longer references the deleted activity, no duplicate/stale
        // row, and the OTHER activity is untouched.
        guard case .loaded(let rowsAfterDelete) = homeDashboardViewModel.todayActivityState else {
            Issue.record("Expected .loaded after delete")
            return
        }
        #expect(rowsAfterDelete.contains { $0.id == activity.id.uuidString } == false)
        #expect(rowsAfterDelete.filter { $0.id == activity.id.uuidString }.isEmpty)
        #expect(rowsAfterDelete.contains { $0.id == keptActivity.id.uuidString })
    }

    /// Athlete isolation: deleting one athlete's activity, through the
    /// exact same flow above, must never remove or otherwise affect a
    /// DIFFERENT athlete's own canonical composition.
    @Test("Deleting one athlete's activity never affects a different athlete's own canonical composition")
    @MainActor
    func deleteActivityNeverAffectsAnotherAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteA = AthleteId()
        let athleteB = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlanA = try planningService.getOrCreateWeekPlan(athleteId: athleteA, weekStart: weekStart)
        let weekPlanB = try planningService.getOrCreateWeekPlan(athleteId: athleteB, weekStart: weekStart)
        let activityA = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanA.weekPlanId, athleteId: athleteA, activityType: .individualTraining,
            title: "Athlete A run", localDate: today, timeZoneId: Self.oslo
        )
        let activityB = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanB.weekPlanId, athleteId: athleteB, activityType: .individualTraining,
            title: "Athlete B run", localDate: today, timeZoneId: Self.oslo
        )

        func makeComposer() -> TodayActivityComposer {
            TodayActivityComposer(
                planningService: planningService, trainingService: trainingService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService
            )
        }
        let homeDashboardViewModelB = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteB, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteB, weekStart: weekStart, todayActivityComposer: makeComposer(),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
        homeDashboardViewModelB.loadTodayActivityRows()
        guard case .loaded(let rowsBBefore) = homeDashboardViewModelB.todayActivityState else {
            Issue.record("Expected .loaded for athlete B before athlete A's delete")
            return
        }
        #expect(rowsBBefore.contains { $0.id == activityB.id.uuidString })

        let detailViewModelA = ActivityDetailViewModel(
            activity: activityA, isCompleted: false, weekPlanId: weekPlanA.weekPlanId,
            athleteId: athleteA, athleteDisplayName: "Athlete A", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: trainingReflectionCoordinationService
        )
        #expect(detailViewModelA.deleteActivity() == true)

        // Athlete B's own canonical composition, reread fresh, still
        // shows their own activity — completely untouched by athlete A's
        // delete.
        homeDashboardViewModelB.loadTodayActivityRows()
        guard case .loaded(let rowsBAfter) = homeDashboardViewModelB.todayActivityState else {
            Issue.record("Expected .loaded for athlete B after athlete A's delete")
            return
        }
        #expect(rowsBAfter.contains { $0.id == activityB.id.uuidString })
    }

    /// Recurring/source semantics: deleting a recurring-MATERIALIZED
    /// `PlannedActivity` (`ActivityDetailViewModel.deleteActivity()`
    /// treats it identically to any other planned activity — it never
    /// inspects `externalSourceId`/`externalSourceType`) must remove
    /// only that ONE materialized occurrence, never the
    /// `RecurringPlannedActivity` series itself, and must make the
    /// occurrence available to materialize again — `deriveSuggestions`'s
    /// exclusion of already-materialized occurrences is existence-based
    /// (is there a `PlannedActivity` with this `externalSourceId`),
    /// so once the materialized instance is gone, the occurrence is
    /// correctly, not accidentally, re-offered.
    @Test("Deleting a recurring-materialized PlannedActivity removes only that occurrence, leaves the recurring series untouched, and re-offers the occurrence as a suggestion")
    @MainActor
    func deleteRecurringMaterializedActivityPreservesSeriesAndReoffersOccurrence() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let recurringActivity = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: Self.oslo,
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )
        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let suggestion = try #require(suggestions.first)
        let materialized = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
        #expect(materialized.externalSourceType == RecurringPlannedActivity.externalSourceType)

        // Once materialized, deriveSuggestions correctly excludes it.
        #expect(try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId).isEmpty)

        let detailViewModel = ActivityDetailViewModel(
            activity: materialized, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
                reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
            )
        )
        #expect(detailViewModel.deleteActivity() == true)

        // The materialized occurrence is gone...
        let remaining = try planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        #expect(remaining.contains { $0.plannedActivityId == materialized.plannedActivityId } == false)

        // ...the recurring SERIES itself is completely untouched...
        let stillEnabled = try planningService.fetchRecurringPlannedActivity(byId: recurringActivity.recurringPlannedActivityId)
        #expect(stillEnabled?.isEnabled == true)

        // ...and the occurrence is correctly available to materialize
        // again — never permanently lost, never a duplicate series.
        let suggestionsAfterDelete = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        #expect(suggestionsAfterDelete.contains { $0.id == suggestion.id })
    }

    /// Athlete Home "Now" restructure round (Part B): backs the new
    /// "No training today" empty state — proves the canonical
    /// composition genuinely represents "nothing today" as
    /// `.loaded([])`, not `.failed` or some other state, for an athlete
    /// with no planned activity, no applicable recurring occurrence,
    /// and no unplanned logged activity today. `TodayActivityLoadState`
    /// has no separate "empty" case by design (see its own doc
    /// comment) — an empty array already means this; this test is the
    /// smallest proof that the real composition actually produces one
    /// when there is truly nothing to show, which the View's new empty
    /// state (`todaySection` in `HomeDashboardView`) depends on.
    @Test("Today activity state for an athlete with nothing planned, recurring, or logged today is .loaded([]) — 'no training today'")
    @MainActor
    func todayActivityStateEmptyWhenNothingScheduledToday() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        // Deliberately no planned activity, no recurring definition, no
        // logged activity created for this athlete at all.

        let homeDashboardViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteId, weekStart: weekStart,
            todayActivityComposer: TodayActivityComposer(
                planningService: planningService, trainingService: trainingService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService
            ),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )

        homeDashboardViewModel.loadTodayActivityRows()

        guard case .loaded(let rows) = homeDashboardViewModel.todayActivityState else {
            Issue.record("Expected .loaded([]), not .failed or .loading")
            return
        }
        #expect(rows.isEmpty)
    }
}

/// VX-023 (Sleep V1): Athlete Home Sleep card + morning in-app prompt.
/// Appended as an extension (not new members inside the struct body)
/// purely for a smaller diff against an already very large file — same
/// type, same file, same `.serialized` suite; `private` helpers/statics
/// declared above remain visible here since Swift's `private` allows use
/// from any extension of the same type in the same file.
extension HomeDashboardViewModelTests {
    @MainActor
    private static func makeSleepCoordinationService(container: ModelContainer) -> SleepCoordinationService {
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        return SleepCoordinationService(reflectionService: reflectionService, athleteRepository: athleteRepository)
    }

    @MainActor
    private func makeHomeDashboardViewModel(
        athleteId: AthleteId,
        sleepStatusProvider: any SleepStatusProviding
    ) -> HomeDashboardViewModel {
        HomeDashboardViewModel(
            trainingPlanningCoordinationService: RecordingTodaysTrainingProvider(activitiesToReturn: []),
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: Self.weekStart, sections: [])
            ),
            athleteId: athleteId, weekStart: Self.weekStart,
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster(),
            sleepStatusProvider: sleepStatusProvider
        )
    }

    @Test("16: Athlete Home Sleep card — tracking enabled and today's Sleep missing loads as sleepQuality nil")
    @MainActor
    func sleepCardEnabledAndMissing() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athleteId = AthleteId()
        let viewModel = makeHomeDashboardViewModel(athleteId: athleteId, sleepStatusProvider: service)

        viewModel.loadSleepState(referenceDate: Self.morningReferenceDate, calendar: .current)

        #expect(viewModel.sleepState == .loaded(sleepQuality: nil))
    }

    @Test("17: Athlete Home Sleep card — tracking enabled and today's Sleep recorded loads the correct x/5 value")
    @MainActor
    func sleepCardEnabledAndRecorded() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athleteId = AthleteId()
        let today = SleepCoordinationService.today(referenceDate: Self.morningReferenceDate, calendar: .current)
        _ = try service.recordSleep(athleteId: athleteId, localDate: today, sleepQuality: 4, today: today)
        let viewModel = makeHomeDashboardViewModel(athleteId: athleteId, sleepStatusProvider: service)

        viewModel.loadSleepState(referenceDate: Self.morningReferenceDate, calendar: .current)

        #expect(viewModel.sleepState == .loaded(sleepQuality: 4))
    }

    @Test("18: Athlete Home Sleep card — tracking disabled loads .trackingDisabled (no card)")
    @MainActor
    func sleepCardDisabled() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athleteId = AthleteId()
        try service.setSleepTrackingEnabled(athleteId: athleteId, enabled: false)
        let viewModel = makeHomeDashboardViewModel(athleteId: athleteId, sleepStatusProvider: service)

        viewModel.loadSleepState(referenceDate: Self.morningReferenceDate, calendar: .current)

        #expect(viewModel.sleepState == .trackingDisabled)
    }

    /// A fixed morning instant (08:00) for deterministic before-noon
    /// prompt-eligibility tests — never `Date.now`.
    private static var morningReferenceDate: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 17
        components.hour = 8; components.minute = 0
        return Calendar.current.date(from: components) ?? .now
    }

    /// Same date, but after 12:00 — for the "not eligible after noon" case.
    private static var afternoonReferenceDate: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 17
        components.hour = 14; components.minute = 0
        return Calendar.current.date(from: components) ?? .now
    }

    @Test("22: morning prompt is eligible when before 12:00, tracking enabled, and today's Sleep is missing")
    @MainActor
    func morningPromptEligibleBeforeNoonWhenMissing() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athleteId = AthleteId()
        let viewModel = makeHomeDashboardViewModel(athleteId: athleteId, sleepStatusProvider: service)
        viewModel.loadSleepState(referenceDate: Self.morningReferenceDate, calendar: .current)

        #expect(viewModel.isSleepPromptEligible(referenceDate: Self.morningReferenceDate, calendar: .current) == true)
    }

    @Test("23: morning prompt is not eligible once today's Sleep is already recorded")
    @MainActor
    func morningPromptNotEligibleWhenRecorded() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athleteId = AthleteId()
        let today = SleepCoordinationService.today(referenceDate: Self.morningReferenceDate, calendar: .current)
        _ = try service.recordSleep(athleteId: athleteId, localDate: today, sleepQuality: 3, today: today)
        let viewModel = makeHomeDashboardViewModel(athleteId: athleteId, sleepStatusProvider: service)
        viewModel.loadSleepState(referenceDate: Self.morningReferenceDate, calendar: .current)

        #expect(viewModel.isSleepPromptEligible(referenceDate: Self.morningReferenceDate, calendar: .current) == false)
    }

    @Test("24: morning prompt is not eligible when Sleep tracking is disabled")
    @MainActor
    func morningPromptNotEligibleWhenDisabled() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athleteId = AthleteId()
        try service.setSleepTrackingEnabled(athleteId: athleteId, enabled: false)
        let viewModel = makeHomeDashboardViewModel(athleteId: athleteId, sleepStatusProvider: service)
        viewModel.loadSleepState(referenceDate: Self.morningReferenceDate, calendar: .current)

        #expect(viewModel.isSleepPromptEligible(referenceDate: Self.morningReferenceDate, calendar: .current) == false)
    }

    @Test("25: morning prompt is not eligible after 12:00, even when Sleep is missing and tracking is enabled")
    @MainActor
    func morningPromptNotEligibleAfterNoon() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athleteId = AthleteId()
        let viewModel = makeHomeDashboardViewModel(athleteId: athleteId, sleepStatusProvider: service)
        viewModel.loadSleepState(referenceDate: Self.afternoonReferenceDate, calendar: .current)

        #expect(viewModel.isSleepPromptEligible(referenceDate: Self.afternoonReferenceDate, calendar: .current) == false)
    }

    @Test("26: a dismissed prompt does not reappear again the same morning, but is unaffected on a later day")
    @MainActor
    func dismissedPromptDoesNotReappearSameMorning() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athleteId = AthleteId()
        let viewModel = makeHomeDashboardViewModel(athleteId: athleteId, sleepStatusProvider: service)
        viewModel.loadSleepState(referenceDate: Self.morningReferenceDate, calendar: .current)
        #expect(viewModel.isSleepPromptEligible(referenceDate: Self.morningReferenceDate, calendar: .current) == true)

        viewModel.dismissSleepPrompt(referenceDate: Self.morningReferenceDate, calendar: .current)

        // Later the SAME morning — still dismissed.
        let laterSameMorning = Self.morningReferenceDate.addingTimeInterval(3600)
        #expect(viewModel.isSleepPromptEligible(referenceDate: laterSameMorning, calendar: .current) == false)

        // The NEXT day, before noon — dismissal does not carry forward
        // ("do not persist 'dismissed forever'").
        var nextDayComponents = DateComponents()
        nextDayComponents.year = 2026; nextDayComponents.month = 8; nextDayComponents.day = 18
        nextDayComponents.hour = 8; nextDayComponents.minute = 0
        let nextMorning = Calendar.current.date(from: nextDayComponents) ?? Self.morningReferenceDate
        #expect(viewModel.isSleepPromptEligible(referenceDate: nextMorning, calendar: .current) == true)
    }

    // MARK: - Athlete Home Sleep inline round

    /// Backs the inline 1-5 control's "missing" case: tapping a value
    /// calls `recordSleep(quality:)` directly, no separate capture
    /// screen. Proves the canonical write actually happens (through the
    /// real `SleepCoordinationService`, not a double) and that
    /// `sleepState` reflects it afterward via the existing
    /// `loadSleepState()` reload — the same invalidation path this
    /// ViewModel already used for every other Sleep mutation.
    @Test("recordSleep(quality:) for a missing current-day value writes the canonical DailyStatus and sleepState reflects the saved value")
    @MainActor
    func recordSleepForMissingValueWritesCanonicalValue() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athleteId = AthleteId()
        let viewModel = makeHomeDashboardViewModel(athleteId: athleteId, sleepStatusProvider: service)
        viewModel.loadSleepState(referenceDate: Self.morningReferenceDate, calendar: .current)
        #expect(viewModel.sleepState == .loaded(sleepQuality: nil))

        viewModel.recordSleep(quality: 4, referenceDate: Self.morningReferenceDate, calendar: .current)

        #expect(viewModel.sleepState == .loaded(sleepQuality: 4))
        #expect(viewModel.sleepErrorMessage == nil)
        let today = SleepCoordinationService.today(referenceDate: Self.morningReferenceDate, calendar: .current)
        let persisted = try service.fetchDailyStatus(forAthlete: athleteId, localDate: today)
        #expect(persisted?.sleepQuality == 4)
    }

    /// Backs the inline control's "already recorded" case: tapping a
    /// DIFFERENT value later corrects today's value. Proves this
    /// happens through the same canonical upsert `recordSleep(quality:)`
    /// now uses — the same `DailyStatus` row is updated, never a
    /// second one created — and that `sleepState` reflects the
    /// corrected value, never the original one, afterward.
    @Test("recordSleep(quality:) for an already-recorded current-day value updates the same canonical DailyStatus, never duplicates it, and sleepState reflects the corrected value")
    @MainActor
    func recordSleepCorrectsAlreadyRecordedValue() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athleteId = AthleteId()
        let today = SleepCoordinationService.today(referenceDate: Self.morningReferenceDate, calendar: .current)
        let first = try service.recordSleep(athleteId: athleteId, localDate: today, sleepQuality: 2, today: today)
        let viewModel = makeHomeDashboardViewModel(athleteId: athleteId, sleepStatusProvider: service)
        viewModel.loadSleepState(referenceDate: Self.morningReferenceDate, calendar: .current)
        #expect(viewModel.sleepState == .loaded(sleepQuality: 2))

        viewModel.recordSleep(quality: 5, referenceDate: Self.morningReferenceDate, calendar: .current)

        #expect(viewModel.sleepState == .loaded(sleepQuality: 5))
        let second = try service.fetchDailyStatus(forAthlete: athleteId, localDate: today)
        #expect(second?.sleepQuality == 5)
        #expect(second?.id == first.id)
        #expect(try container.mainContext.fetch(FetchDescriptor<DailyStatus>()).count == 1)
    }
}
