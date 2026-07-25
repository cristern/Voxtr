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

@Suite("WeeklyReviewViewModel coaching integration (Sprint 9)", .serialized)
struct WeeklyReviewCoachingIntegrationTests {

    private static let athleteId = AthleteId()
    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)
    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    /// Deterministic throwing double — a genuine technical failure,
    /// distinct from "nothing found."
    @MainActor
    private struct ThrowingCoachingContextProvider: WeeklyCoachingContextProviding {
        struct TestError: Error {}
        func weeklyCoachingContext(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyCoachingContext {
            throw TestError()
        }
    }

    /// A minimal, hand-built context — no persistence involved. Used
    /// for tests that only care about how the ViewModel handles the
    /// pipeline's output, not about assembling real data.
    @MainActor
    private struct StubCoachingContextProvider: WeeklyCoachingContextProviding {
        let context: WeeklyCoachingContext
        func weeklyCoachingContext(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyCoachingContext {
            context
        }
    }

    /// Not used by `loadCoachingPresentation` (which doesn't need
    /// `WeeklyReviewProviding` at all), only present to satisfy
    /// `WeeklyReviewViewModel.init`'s other required parameter.
    @MainActor
    private struct ThrowingProvider: WeeklyReviewProviding {
        struct TestError: Error {}
        func weeklyReview(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyReviewResult {
            throw TestError()
        }
    }

    @Test("coachingPresentationState carries CoachingPresentation, not CoachingInsight, at the type level")
    @MainActor
    func stateCarriesPresentationNotInsight() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: nil, plannedActivityCount: 0, completedPlannedActivityCount: 0,
            uncompletedPlannedActivityCount: 0, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 0,
            weeklyReflection: nil, parentObservations: []
        )
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingProvider(),
            coachingContextService: StubCoachingContextProvider(context: context),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingPresentation()

        // The type system already enforces this — .loaded's associated
        // value is CoachingPresentation, never CoachingInsight — this
        // assertion exercises that the state is actually reachable and
        // holds the type it's declared to hold.
        guard case .loaded(let presentation) = viewModel.coachingPresentationState else {
            Issue.record("Expected .loaded")
            return
        }
        let _: CoachingPresentation = presentation
    }

    @Test("Existing weekly data flows through the complete deterministic pipeline end to end")
    @MainActor
    func completeDataFlowsThroughFullPipeline() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let weeklyReviewCoordinationService = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coachingContextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: reflectionService
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

        let viewModel = WeeklyReviewViewModel(
            coordinationService: weeklyReviewCoordinationService,
            coachingContextService: coachingContextService,
            athleteId: athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingPresentation()

        guard case .loaded(let presentation) = viewModel.coachingPresentationState else {
            Issue.record("Expected .loaded")
            return
        }
        let plannedSection = presentation.sections.first { $0.title == "Planned Activities" }
        #expect(plannedSection?.items.first?.insight == .allPlannedActivitiesCompleted)
    }

    @Test("A result with findings produces the expected presentation state")
    @MainActor
    func findingsProduceExpectedPresentationState() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: .draft, plannedActivityCount: 3, completedPlannedActivityCount: 1,
            uncompletedPlannedActivityCount: 2, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 1,
            weeklyReflection: nil, parentObservations: []
        )
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingProvider(),
            coachingContextService: StubCoachingContextProvider(context: context),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingPresentation()

        guard case .loaded(let presentation) = viewModel.coachingPresentationState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(presentation.sections.map(\.title) == ["Planned Activities", "Weekly Reflection", "Parent Observations"])
        #expect(presentation.sections[0].items.first?.insight == .somePlannedActivitiesMissed)
        #expect(presentation.sections[1].items.first?.insight == .noWeeklyReflection)
        #expect(presentation.sections[2].items.first?.insight == .noParentObservations)
    }

    @Test("A minimal context (nothing planned) still produces a valid, non-empty presentation — a literally empty CoachingResult is not reachable through the real CoachingEngine by design; see CoachingPresentationMapperTests for that case tested directly against the mapper")
    @MainActor
    func minimalContextProducesSparsePresentationNotAnInventedMessage() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: nil, plannedActivityCount: 0, completedPlannedActivityCount: 0,
            uncompletedPlannedActivityCount: 0, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 0,
            weeklyReflection: nil, parentObservations: []
        )
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingProvider(),
            coachingContextService: StubCoachingContextProvider(context: context),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingPresentation()

        guard case .loaded(let presentation) = viewModel.coachingPresentationState else {
            Issue.record("Expected .loaded")
            return
        }
        // No "Planned Activities" section at all — that category
        // genuinely has nothing to report, and nothing was invented for
        // it.
        #expect(!presentation.sections.contains { $0.title == "Planned Activities" })
        // No item anywhere contains invented success language.
        let allText = presentation.sections.flatMap { $0.items.map(\.text) }
        #expect(!allText.contains { $0.lowercased().contains("everything looks good") })
        #expect(!allText.contains { $0.lowercased().contains("great job") })
    }

    @Test("Stable section ordering is preserved in the state consumed by the UI")
    @MainActor
    func stableOrderingPreservedInState() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: .committed, plannedActivityCount: 2, completedPlannedActivityCount: 2,
            uncompletedPlannedActivityCount: 0, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 2,
            weeklyReflection: WeeklyReflectionSummary(
                overallSatisfaction: 4, loadFelt: nil, whatWorked: nil,
                whatWasDifficult: nil, learning: nil, nextWeekConsideration: nil
            ),
            parentObservations: [ParentObservationSummary(localDate: Self.weekStart, text: "Note")]
        )
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingProvider(),
            coachingContextService: StubCoachingContextProvider(context: context),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingPresentation()
        guard case .loaded(let first) = viewModel.coachingPresentationState else {
            Issue.record("Expected .loaded")
            return
        }

        viewModel.loadCoachingPresentation()
        guard case .loaded(let second) = viewModel.coachingPresentationState else {
            Issue.record("Expected .loaded")
            return
        }

        #expect(first.sections.map(\.title) == ["Planned Activities", "Weekly Reflection", "Parent Observations"])
        #expect(first.sections.map(\.title) == second.sections.map(\.title))
    }

    @Test("Repeated processing of equivalent input produces equal presentation state")
    @MainActor
    func repeatedProcessingProducesEqualState() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: .draft, plannedActivityCount: 1, completedPlannedActivityCount: 0,
            uncompletedPlannedActivityCount: 1, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 0,
            weeklyReflection: nil, parentObservations: []
        )
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingProvider(),
            coachingContextService: StubCoachingContextProvider(context: context),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingPresentation()
        guard case .loaded(let first) = viewModel.coachingPresentationState else {
            Issue.record("Expected .loaded")
            return
        }
        viewModel.loadCoachingPresentation()
        guard case .loaded(let second) = viewModel.coachingPresentationState else {
            Issue.record("Expected .loaded")
            return
        }

        #expect(first == second)
    }

    @Test("A genuine technical failure is represented as .failed, never as a successful empty presentation")
    @MainActor
    func technicalFailureNotConflatedWithEmptySuccess() throws {
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingProvider(),
            coachingContextService: ThrowingCoachingContextProvider(),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingPresentation()

        guard case .failed = viewModel.coachingPresentationState else {
            Issue.record("Expected .failed, not a successfully-loaded empty presentation")
            return
        }
    }

    @Test("A coaching pipeline failure does not block the rest of Weekly Review from loading")
    @MainActor
    func coachingFailureDoesNotBlockMainReview() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let weeklyReviewCoordinationService = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let viewModel = WeeklyReviewViewModel(
            coordinationService: weeklyReviewCoordinationService,
            coachingContextService: ThrowingCoachingContextProvider(),
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.load()
        viewModel.loadCoachingPresentation()

        guard case .loaded = viewModel.loadState else {
            Issue.record("Main Weekly Review load must succeed independently of the coaching pipeline")
            return
        }
        guard case .failed = viewModel.coachingPresentationState else {
            Issue.record("Expected coaching state to be .failed")
            return
        }
    }
}
