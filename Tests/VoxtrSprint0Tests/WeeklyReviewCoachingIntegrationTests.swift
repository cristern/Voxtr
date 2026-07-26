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
//
// Sprint 11: this file used to test the full coaching pipeline's
// correctness (context assembly → engine → mapper) by driving it
// through `WeeklyReviewViewModel`. That orchestration now lives only in
// `CoachingApplicationService` — its correctness (findings, ordering,
// determinism, failure propagation) is tested directly in
// `CoachingApplicationServiceTests.swift`, closer to where the logic
// actually lives. What belongs here now is narrower and different:
// does `WeeklyReviewViewModel` correctly DELEGATE to whatever
// `CoachingPresentationProviding` it was given, without re-deriving or
// altering anything itself. Testing both at the ViewModel level would
// have meant testing the same orchestration logic twice.

@Suite("WeeklyReviewViewModel coaching delegation (Sprint 11)", .serialized)
struct WeeklyReviewCoachingDelegationTests {

    private static let athleteId = AthleteId()
    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)

    /// Not used by any test in this file (delegation tests don't need
    /// the main Weekly Review data at all), only present to satisfy
    /// `WeeklyReviewViewModel.init`'s other required parameter.
    @MainActor
    private struct ThrowingWeeklyReviewProvider: WeeklyReviewProviding {
        struct TestError: Error {}
        func weeklyReview(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyReviewResult {
            throw TestError()
        }
    }

    /// Records exactly what it was called with and returns a
    /// pre-built `CoachingPresentation` unchanged — lets these tests
    /// assert pure delegation without needing any real pipeline stage.
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

    @Test("coachingPresentationState carries exactly the CoachingPresentation the provider returned — no transformation")
    @MainActor
    func viewModelDelegatesResultUnchanged() throws {
        let expected = CoachingPresentation(
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            sections: [CoachingPresentationSection(title: "Weekly Reflection", items: [
                CoachingPresentationItem(insight: .noWeeklyReflection, text: "No weekly reflection was recorded.", emphasis: .attention, action: .startWeeklyReflection),
            ])]
        )
        let provider = RecordingCoachingPresentationProvider(presentationToReturn: expected)
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingWeeklyReviewProvider(),
            coachingPresentationProvider: provider,
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingPresentation()

        guard case .loaded(let presentation) = viewModel.coachingPresentationState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(presentation == expected)
    }

    @Test("athleteId and weekStart are forwarded to the provider unchanged")
    @MainActor
    func viewModelForwardsAthleteIdAndWeekStartUnchanged() throws {
        let provider = RecordingCoachingPresentationProvider(
            presentationToReturn: CoachingPresentation(athleteId: Self.athleteId, weekStart: Self.weekStart, sections: [])
        )
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingWeeklyReviewProvider(),
            coachingPresentationProvider: provider,
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingPresentation()

        #expect(provider.receivedAthleteId == Self.athleteId)
        #expect(provider.receivedWeekStart == Self.weekStart)
    }

    @Test("Each call to loadCoachingPresentation delegates exactly once — orchestration is not duplicated in the ViewModel")
    @MainActor
    func loadCoachingPresentationDelegatesExactlyOnce() throws {
        let provider = RecordingCoachingPresentationProvider(
            presentationToReturn: CoachingPresentation(athleteId: Self.athleteId, weekStart: Self.weekStart, sections: [])
        )
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingWeeklyReviewProvider(),
            coachingPresentationProvider: provider,
            athleteId: Self.athleteId, weekStart: Self.weekStart
        )

        viewModel.loadCoachingPresentation()
        viewModel.loadCoachingPresentation()

        #expect(provider.callCount == 2)
    }

    @Test("A genuine technical failure from the provider is represented as .failed, never as a successful empty presentation")
    @MainActor
    func providerFailureNotConflatedWithEmptySuccess() throws {
        let viewModel = WeeklyReviewViewModel(
            coordinationService: ThrowingWeeklyReviewProvider(),
            coachingPresentationProvider: ThrowingCoachingPresentationProvider(),
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
            coachingPresentationProvider: ThrowingCoachingPresentationProvider(),
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
