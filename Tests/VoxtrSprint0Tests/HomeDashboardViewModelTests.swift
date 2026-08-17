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
            )
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
            )
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
            athleteId: athleteA, weekStart: weekStart, todayActivityComposer: makeComposer()
        )
        let homeDashboardViewModelB = HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: RecordingCoachingPresentationProvider(
                presentationToReturn: CoachingPresentation(athleteId: athleteB, weekStart: weekStart, sections: [])
            ),
            athleteId: athleteB, weekStart: weekStart, todayActivityComposer: makeComposer()
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
            )
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
            )
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

    // MARK: - Recurring reopen stale-Athlete-Home fix

    /// Reproduces the exact TestFlight-reported gap: a recurring
    /// occurrence materialized+cancelled, then reopened, through
    /// `FamilyHomeContentView`'s OWN `.recurringOccurrence`/`.activity`
    /// destinations (mirrored here via direct service calls, since
    /// those destinations aren't independently unit-testable) — never
    /// through Athlete Home's own navigation. Proves the root cause
    /// first (a cached `HomeDashboardViewModel` untouched by that
    /// mutation stays stale), then proves `HomeDashboardViewModelCache.reloadIfCached`
    /// closes exactly that gap: same materialized `PlannedActivity`
    /// identity, no linked `LoggedActivity`, recurring provenance
    /// (`externalSourceType`) unchanged, exactly one row, unresolved,
    /// no duplicate `.recurringOccurrence` suggestion.
    @Test("HomeDashboardViewModelCache.reloadIfCached refreshes an already-mounted Athlete Home after a recurring occurrence is reopened via Family Home's own row")
    @MainActor
    func reloadIfCachedRefreshesAfterRecurringReopenViaFamilyHome() throws {
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
        let recurringActivity = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: Self.oslo,
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )
        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let suggestion = try #require(suggestions.first)

        // "Cancel this occurrence" (RecurringOccurrencePreviewView.cancelOccurrence()):
        // materialize, then link a .cancelled LoggedActivity.
        let materialized = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
        let cancelResult = try trainingReflectionCoordinationService.logActivity(
            athleteId: athleteId, plannedActivityId: materialized.plannedActivityId,
            activityType: materialized.activityType, title: materialized.title, startedAt: .now,
            durationMinutes: 1, status: .cancelled, authorId: ActorId(), sessionForm: nil
        )

        // Athlete Home was visited earlier this session — its
        // HomeDashboardViewModel is cached (HomeDashboardViewModelCache
        // hands back the SAME instance on every subsequent .athlete
        // push, exactly as FamilyHomeContentView.athleteOverview(for:)
        // does), loaded once, and then left mounted.
        let cache = HomeDashboardViewModelCache()
        let cachedViewModel = cache.viewModel(for: athleteId) {
            HomeDashboardViewModel(
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                coachingPresentationProvider: RecordingCoachingPresentationProvider(
                    presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
                ),
                athleteId: athleteId, weekStart: weekStart,
                todayActivityComposer: TodayActivityComposer(
                    planningService: planningService, trainingService: trainingService,
                    trainingPlanningCoordinationService: trainingPlanningCoordinationService
                )
            )
        }
        cachedViewModel.loadTodayActivityRows()

        guard case .loaded(let rowsAfterCancel) = cachedViewModel.todayActivityState,
              case .planned(let cancelledRow) = rowsAfterCancel.first(where: { $0.id == materialized.plannedActivityId.rawValue.uuidString }) else {
            Issue.record("Expected a .planned cancelled row on the cached Athlete Home ViewModel")
            return
        }
        #expect(cancelledRow.outcomeStatus == .cancelled)

        // Reopen — via the SAME canonical path ActivityDetailViewModel.reopenActivity()
        // uses — but reached through Family Home's OWN `.activity` row,
        // never through this cached Athlete Home instance's own
        // navigation. Mirrors FamilyHomeContentView.activityDetail(for:)'s
        // onActivityLogged BEFORE this fix: only the (unrelated, not
        // constructed here) FamilyHomeViewModel would have reloaded.
        try trainingReflectionCoordinationService.reopenCancelledActivity(
            cancelResult.loggedActivity.loggedActivityId, athleteId: athleteId
        )

        // Root cause, proven: the cached Athlete Home ViewModel was
        // never told about that mutation, so its own canonical read is
        // still the pre-reopen snapshot.
        guard case .loaded(let staleRows) = cachedViewModel.todayActivityState,
              case .planned(let staleRow) = staleRows.first(where: { $0.id == materialized.plannedActivityId.rawValue.uuidString }) else {
            Issue.record("Expected the stale .planned row to still be present before reloadIfCached")
            return
        }
        #expect(staleRow.outcomeStatus == .cancelled)

        // The fix: FamilyHomeContentView's .activity/.recurringOccurrence
        // onActivityLogged closures also call this.
        cache.reloadIfCached(for: athleteId)

        guard case .loaded(let freshRows) = cachedViewModel.todayActivityState,
              case .planned(let freshRow) = freshRows.first(where: { $0.id == materialized.plannedActivityId.rawValue.uuidString }) else {
            Issue.record("Expected the fresh .planned row after reloadIfCached")
            return
        }
        // Same materialized PlannedActivity identity throughout.
        #expect(freshRow.plannedActivity.plannedActivityId == materialized.plannedActivityId)
        // No linked LoggedActivity — genuinely unresolved again.
        #expect(freshRow.outcomeStatus == nil)
        #expect(freshRow.isCompleted == false)
        // Recurring series/provenance untouched.
        #expect(freshRow.isFromRecurring == true)
        #expect(freshRow.plannedActivity.externalSourceType == RecurringPlannedActivity.externalSourceType)
        let stillEnabled = try planningService.fetchRecurringPlannedActivity(byId: recurringActivity.recurringPlannedActivityId)
        #expect(stillEnabled?.isEnabled == true)
        // Exactly one visible canonical row for this occurrence — never
        // re-appears as a duplicate .recurringOccurrence suggestion
        // alongside the materialized .planned row.
        #expect(freshRows.filter { $0.id == materialized.plannedActivityId.rawValue.uuidString }.count == 1)
        #expect(freshRows.contains { row in
            if case .recurringOccurrence(_, _, let s) = row { return s.id == suggestion.id }
            return false
        } == false)
    }

    /// `reloadIfCached` must never create an entry merely by being
    /// called — it is a pure "refresh if already present" operation, not
    /// a second way to populate the cache. Proven indirectly: after
    /// calling it for an athlete this cache has never seen,
    /// `viewModel(for:make:)` still invokes `make()` — i.e. no cached
    /// instance was silently created.
    @Test("HomeDashboardViewModelCache.reloadIfCached is a no-op for an athlete with no cached instance")
    @MainActor
    func reloadIfCachedNoOpsForUncachedAthlete() throws {
        let athleteId = AthleteId()
        let cache = HomeDashboardViewModelCache()

        cache.reloadIfCached(for: athleteId)

        var makeCallCount = 0
        _ = cache.viewModel(for: athleteId) {
            makeCallCount += 1
            return HomeDashboardViewModel(
                trainingPlanningCoordinationService: RecordingTodaysTrainingProvider(activitiesToReturn: []),
                coachingPresentationProvider: RecordingCoachingPresentationProvider(
                    presentationToReturn: CoachingPresentation(athleteId: athleteId, weekStart: Self.weekStart, sections: [])
                ),
                athleteId: athleteId, weekStart: Self.weekStart
            )
        }
        #expect(makeCallCount == 1)
    }
}
