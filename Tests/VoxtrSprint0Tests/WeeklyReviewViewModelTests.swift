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

@Suite("WeeklyReviewViewModel (Sprint 5.2)", .serialized)
struct WeeklyReviewViewModelTests {

    /// Sprint 11: none of these tests exercise coaching behavior — they
    /// predate the coaching pipeline. A minimal stub satisfies
    /// `WeeklyReviewViewModel`'s required `coachingPresentationProvider:`
    /// parameter (previously `coachingContextService:`, before Sprint
    /// 11 extracted orchestration into `CoachingApplicationService`)
    /// without pulling coaching setup into tests that aren't about it.
    @MainActor
    private struct EmptyCoachingPresentationProvider: CoachingPresentationProviding {
        func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
            CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
        }
    }


    /// Deterministic throwing double for `WeeklyReviewProviding` — lets
    /// the failure-path test assert `WeeklyReviewViewModel`'s own
    /// contract (any thrown error becomes `.failed`) without depending
    /// on any particular SwiftData failure mode.
    @MainActor
    private struct ThrowingWeeklyReviewProvider: WeeklyReviewProviding {
        struct TestError: Error {}
        func weeklyReview(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyReviewResult {
            throw TestError()
        }
    }

    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)
    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @Test("Successful loading exposes the assembled review")
    @MainActor
    func successfulLoadingExposesAssembledReview() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinationService = WeeklyReviewCoordinationService(
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
        let viewModel = WeeklyReviewViewModel(
            coordinationService: coordinationService, coachingPresentationProvider: EmptyCoachingPresentationProvider(), athleteId: athleteId, weekStart: Self.weekStart
        )

        viewModel.load()

        guard case .loaded(let result) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(result.weekPlan?.id == weekPlan.id)
        #expect(result.plannedActivities.count == 1)
    }

    @Test("Loading state is set correctly through the lifecycle")
    @MainActor
    func loadingStateSetCorrectly() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinationService = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let viewModel = WeeklyReviewViewModel(
            coordinationService: coordinationService, coachingPresentationProvider: EmptyCoachingPresentationProvider(), athleteId: AthleteId(), weekStart: Self.weekStart
        )

        guard case .loading = viewModel.loadState else {
            Issue.record("Expected initial state to be .loading before load() is ever called")
            return
        }

        viewModel.load()

        guard case .loaded = viewModel.loadState else {
            Issue.record("Expected .loaded after load() completes")
            return
        }
    }

    @Test("A coordination failure produces a controlled error state")
    @MainActor
    func coordinationFailureProducesControlledErrorState() throws {
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingWeeklyReviewProvider(), coachingPresentationProvider: EmptyCoachingPresentationProvider(), athleteId: AthleteId(), weekStart: Self.weekStart
        )

        viewModel.load()

        guard case .failed = viewModel.loadState else {
            Issue.record("Expected .failed when the coordination service throws")
            return
        }
    }

    @Test("A missing plan is represented without failing the whole screen")
    @MainActor
    func missingPlanRepresentedWithoutFailure() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinationService = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let viewModel = WeeklyReviewViewModel(
            coordinationService: coordinationService, coachingPresentationProvider: EmptyCoachingPresentationProvider(), athleteId: AthleteId(), weekStart: Self.weekStart
        )

        viewModel.load()

        guard case .loaded(let result) = viewModel.loadState else {
            Issue.record("A missing plan must still produce .loaded, not .failed")
            return
        }
        #expect(result.weekPlan == nil)
        #expect(result.plannedActivities.isEmpty)
    }

    @Test("A missing reflection is represented without failing the whole screen")
    @MainActor
    func missingReflectionRepresentedWithoutFailure() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinationService = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        _ = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)
        let viewModel = WeeklyReviewViewModel(
            coordinationService: coordinationService, coachingPresentationProvider: EmptyCoachingPresentationProvider(), athleteId: athleteId, weekStart: Self.weekStart
        )

        viewModel.load()

        guard case .loaded(let result) = viewModel.loadState else {
            Issue.record("A missing reflection must still produce .loaded, not .failed")
            return
        }
        #expect(result.weeklyReflection == nil)
    }

    @Test("Reload replaces stale data with the current state")
    @MainActor
    func reloadReplacesStaleData() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinationService = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let planning = PlanningService(repository: planningRepository)
        let reflection = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let athleteId = AthleteId()
        _ = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)
        let viewModel = WeeklyReviewViewModel(
            coordinationService: coordinationService, coachingPresentationProvider: EmptyCoachingPresentationProvider(), athleteId: athleteId, weekStart: Self.weekStart
        )
        viewModel.load()
        guard case .loaded(let before) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(before.weeklyReflection == nil)

        // Something changes underneath — a reflection is recorded
        // (e.g. via the reflection form) after the first load.
        _ = try reflection.recordWeeklyReflection(
            athleteId: athleteId, weekStart: Self.weekStart, authorId: ActorId(),
            overallSatisfaction: 5, visibility: .privateToAthlete
        )

        viewModel.load()

        guard case .loaded(let after) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(after.weeklyReflection?.overallSatisfaction == 5)
    }

    @Test("athleteId and weekStart are forwarded unchanged to the coordination service")
    @MainActor
    func athleteIdAndWeekStartForwardedUnchanged() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinationService = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let athleteId = AthleteId()
        let viewModel = WeeklyReviewViewModel(
            coordinationService: coordinationService, coachingPresentationProvider: EmptyCoachingPresentationProvider(), athleteId: athleteId, weekStart: Self.weekStart
        )

        viewModel.load()

        guard case .loaded(let result) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(result.athleteId == athleteId)
        #expect(result.weekStart == Self.weekStart)
        #expect(viewModel.athleteId == athleteId)
        #expect(viewModel.weekStart == Self.weekStart)
    }

    /// Weekday-scan round: proves the exact mechanism the Logged
    /// activities section's weekday caption depends on —
    /// `WeeklyReviewView.localDate(for:)` converts a `LoggedActivity.startedAt`
    /// instant into the correct calendar day, whose `.weekday` then
    /// drives `WeeklyPlanningView.weekdayLabel(for:)`. Uses an explicit
    /// UTC calendar (not `.current`) so this is deterministic regardless
    /// of the machine/CI's local time zone — the same "no
    /// Calendar.current for exact-result assertions" rule this test
    /// suite's own persistence tests already follow. Jan 5, 2026 is a
    /// Monday, matching `WeeklyPlanningViewModelTests`'s own
    /// `fixedWeekStart` fixture; Jan 11, 2026 is that week's Sunday —
    /// together these cover both Vǫxtr week boundaries, not just an
    /// arbitrary midweek day.
    @Test("WeeklyReviewView.localDate(for:) derives the correct calendar day — and therefore the correct weekday — from a LoggedActivity's startedAt instant")
    func loggedActivityStartedAtDerivesCorrectWeekday() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let mondayNoon = utcCalendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 12))!
        let mondayDerived = WeeklyReviewView.localDate(for: mondayNoon, calendar: utcCalendar)
        #expect(mondayDerived == LocalDate(year: 2026, month: 1, day: 5))
        #expect(mondayDerived.weekday == .monday)
        #expect(WeeklyPlanningView.weekdayLabel(for: mondayDerived.weekday) == "Monday")

        let sundayNoon = utcCalendar.date(from: DateComponents(year: 2026, month: 1, day: 11, hour: 12))!
        let sundayDerived = WeeklyReviewView.localDate(for: sundayNoon, calendar: utcCalendar)
        #expect(sundayDerived == LocalDate(year: 2026, month: 1, day: 11))
        #expect(sundayDerived.weekday == .sunday)
        #expect(WeeklyPlanningView.weekdayLabel(for: sundayDerived.weekday) == "Sunday")
    }
}
