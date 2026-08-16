import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrCoachingDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("WeeklyCoachingContextService (Sprint 6, revised)", .serialized)
struct WeeklyCoachingContextServiceTests {

    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)
    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    /// Deterministic throwing double for `WeeklyReviewProviding` —
    /// stateless, single-test-use, no SwiftData involvement.
    @MainActor
    private struct ThrowingWeeklyReviewProvider: WeeklyReviewProviding {
        struct TestError: Error {}
        func weeklyReview(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyReviewResult {
            throw TestError()
        }
    }

    /// Deterministic throwing double for `ParentObservationProviding`.
    @MainActor
    private struct ThrowingParentObservationProvider: ParentObservationProviding {
        struct TestError: Error {}
        func fetchParentObservations(forAthlete athleteId: AthleteId) throws -> [ParentObservation] {
            throw TestError()
        }
    }

    /// Always-empty double for `ParentObservationProviding`, used where
    /// a test only cares about the analysed-week assembly.
    @MainActor
    private struct EmptyParentObservationProvider: ParentObservationProviding {
        func fetchParentObservations(forAthlete athleteId: AthleteId) throws -> [ParentObservation] {
            []
        }
    }

    @Test("Assembles a flat context with correct counts, status, reflection, and previousWeekStart — no WeeklyReviewResult or @Model exposed")
    @MainActor
    func assemblesFlatContextFromRealData() throws {
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
        let contextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: reflectionService
        )
        let planning = PlanningService(repository: planningRepository)
        let training = TrainingService(repository: trainingRepository)
        let weeklyReflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let athleteId = AthleteId()

        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)
        let plannedActivity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Second session", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: plannedActivity.plannedActivityId,
            activityType: .individualTraining, title: "Endurance run",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now
        )
        _ = try training.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Unplanned jog",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 6)) ?? .now
        )
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: Self.weekStart, authorId: ActorId(),
            overallSatisfaction: 4, whatWorked: "Consistency", visibility: .privateToAthlete
        )
        _ = try reflectionService.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(), localDate: Self.weekStart, text: "Looked strong."
        )

        let context = try contextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(context.athleteId == athleteId)
        #expect(context.weekStart == Self.weekStart)
        #expect(context.previousWeekStart == LocalDate(year: 2025, month: 12, day: 29))
        #expect(context.weekPlanStatus == .draft)
        #expect(context.plannedActivityCount == 2)
        #expect(context.completedPlannedActivityCount == 1)
        #expect(context.uncompletedPlannedActivityCount == 1)
        #expect(context.totalLoggedActivityCount == 2)
        #expect(context.unplannedLoggedActivityCount == 1)
        #expect(context.weeklyReflection?.overallSatisfaction == 4)
        #expect(context.weeklyReflection?.whatWorked == "Consistency")
        #expect(context.parentObservations.count == 1)
        #expect(context.parentObservations.first?.text == "Looked strong.")
    }

    /// Review follow-up (cancellation sanity check, round 2): the exact
    /// same completion-semantics bug found in Weekly History also
    /// existed here — `completedPlannedActivityCount` used to count
    /// Cancelled/Missed as completed training, which would have fed
    /// `CoachingEngine` (via `CoachingAnalysisInputMapper`) a false
    /// "all planned activities completed" signal. This proves the fix
    /// across every outcome the engine's two-bucket completed/
    /// not-completed contract distinguishes.
    @Test("completedPlannedActivityCount/uncompletedPlannedActivityCount use genuine completion — Cancelled and Missed both count as not-completed, never as completed")
    @MainActor
    func completionCountsExcludeCancelledAndMissed() throws {
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
        let contextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: EmptyParentObservationProvider()
        )
        let planning = PlanningService(repository: planningRepository)
        let training = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)

        let completed = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Completed run", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        let partiallyCompleted = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Partially completed session", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        let cancelled = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Cancelled swim", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        let missed = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Missed session", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        // A fifth planned activity is left entirely unlogged —
        // "still unresolved/planned," the same bucket this contract
        // already put a never-logged activity in before Cancel existed.
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Not yet logged", localDate: Self.weekStart, timeZoneId: Self.oslo
        )

        let referenceStart = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: completed.plannedActivityId,
            activityType: .individualTraining, title: "Completed run", startedAt: referenceStart,
            durationMinutes: 40, status: .completed
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: partiallyCompleted.plannedActivityId,
            activityType: .individualTraining, title: "Partially completed session", startedAt: referenceStart,
            durationMinutes: 20, status: .partiallyCompleted
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: cancelled.plannedActivityId,
            activityType: .individualTraining, title: "Cancelled swim", startedAt: referenceStart,
            durationMinutes: 1, status: .cancelled
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: missed.plannedActivityId,
            activityType: .individualTraining, title: "Missed session", startedAt: referenceStart,
            durationMinutes: 1, status: .missed
        )

        let context = try contextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(context.plannedActivityCount == 5)
        // Completed + PartiallyCompleted only.
        #expect(context.completedPlannedActivityCount == 2)
        // Cancelled + Missed + never-logged.
        #expect(context.uncompletedPlannedActivityCount == 3)
        // The two counts fully partition the total — no activity is
        // silently dropped from both.
        #expect(context.completedPlannedActivityCount + context.uncompletedPlannedActivityCount == context.plannedActivityCount)

        // The exact boundary CoachingAnalysisInputMapper/CoachingEngine
        // actually consume — proves the fix reaches the real decision
        // input, not just the intermediate DTO.
        let analysisInput = CoachingAnalysisInputMapper().map(context)
        #expect(analysisInput.uncompletedPlannedActivityCount == 3)
        let result = CoachingEngine().analyse(analysisInput)
        #expect(result.insights.contains(.somePlannedActivitiesMissed))
        #expect(!result.insights.contains(.allPlannedActivitiesCompleted))
    }

    @Test("Parent observations outside the analysed week's date range are excluded")
    @MainActor
    func parentObservationsScopedToAnalysedWeek() throws {
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
        let contextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: reflectionService
        )
        let athleteId = AthleteId()
        _ = try reflectionService.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(), localDate: Self.weekStart, text: "In range"
        )
        _ = try reflectionService.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 2, day: 1), text: "Out of range"
        )

        let context = try contextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(context.parentObservations.count == 1)
        #expect(context.parentObservations.first?.text == "In range")
    }

    @Test("Missing plan, reflection, and observations are represented gracefully, not as an error")
    @MainActor
    func missingDataHandledGracefully() throws {
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
        let contextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: reflectionService
        )

        let context = try contextService.weeklyCoachingContext(forAthlete: AthleteId(), weekStart: Self.weekStart)

        #expect(context.weekPlanStatus == nil)
        #expect(context.plannedActivityCount == 0)
        #expect(context.completedPlannedActivityCount == 0)
        #expect(context.uncompletedPlannedActivityCount == 0)
        #expect(context.totalLoggedActivityCount == 0)
        #expect(context.weeklyReflection == nil)
        #expect(context.parentObservations.isEmpty)
    }

    @Test("A genuine WeeklyReviewProviding failure propagates, rather than being swallowed")
    @MainActor
    func weeklyReviewFailurePropagates() throws {
        let contextService = WeeklyCoachingContextService(
            weeklyReviewProvider: ThrowingWeeklyReviewProvider(),
            parentObservationProvider: EmptyParentObservationProvider()
        )

        #expect(throws: ThrowingWeeklyReviewProvider.TestError.self) {
            try contextService.weeklyCoachingContext(forAthlete: AthleteId(), weekStart: Self.weekStart)
        }
    }

    @Test("A genuine ParentObservationProviding failure propagates, rather than being swallowed")
    @MainActor
    func parentObservationFailurePropagates() throws {
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
        let contextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: ThrowingParentObservationProvider()
        )

        #expect(throws: ThrowingParentObservationProvider.TestError.self) {
            try contextService.weeklyCoachingContext(forAthlete: AthleteId(), weekStart: Self.weekStart)
        }
    }

    @Test("Repeated calls with the same athlete/week produce identical results")
    @MainActor
    func deterministicResultsAcrossRepeatedCalls() throws {
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
        let contextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: reflectionService
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try reflectionService.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(), localDate: Self.weekStart, text: "Note"
        )

        let first = try contextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: Self.weekStart)
        let second = try contextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(first.plannedActivityCount == second.plannedActivityCount)
        #expect(first.completedPlannedActivityCount == second.completedPlannedActivityCount)
        #expect(first.totalLoggedActivityCount == second.totalLoggedActivityCount)
        #expect(first.weekPlanStatus == second.weekPlanStatus)
        #expect(first.previousWeekStart == second.previousWeekStart)
        #expect(first.parentObservations.map(\.text) == second.parentObservations.map(\.text))
    }

    @Test("Assembling a context performs no writes — persisted entity counts are unchanged before and after")
    @MainActor
    func noWritesPerformed() throws {
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
        let contextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: reflectionService
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try reflectionService.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(), localDate: Self.weekStart, text: "Note"
        )

        let weekPlanCountBefore = try container.mainContext.fetch(FetchDescriptor<WeekPlan>()).count
        let plannedActivityCountBefore = try container.mainContext.fetch(FetchDescriptor<PlannedActivity>()).count
        let loggedActivityCountBefore = try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count
        let weeklyReflectionCountBefore = try container.mainContext.fetch(FetchDescriptor<WeeklyReflection>()).count
        let parentObservationCountBefore = try container.mainContext.fetch(FetchDescriptor<ParentObservation>()).count

        _ = try contextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: Self.weekStart)
        _ = try contextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(try container.mainContext.fetch(FetchDescriptor<WeekPlan>()).count == weekPlanCountBefore)
        #expect(try container.mainContext.fetch(FetchDescriptor<PlannedActivity>()).count == plannedActivityCountBefore)
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == loggedActivityCountBefore)
        #expect(try container.mainContext.fetch(FetchDescriptor<WeeklyReflection>()).count == weeklyReflectionCountBefore)
        #expect(try container.mainContext.fetch(FetchDescriptor<ParentObservation>()).count == parentObservationCountBefore)
    }

    @Test("The service itself excludes another athlete's data, not just the underlying coordination service")
    @MainActor
    func serviceLevelAnotherAthleteExcluded() throws {
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
        let contextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: reflectionService
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let otherWeekPlan = try planning.getOrCreateWeekPlan(athleteId: otherAthleteId, weekStart: Self.weekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: otherWeekPlan.weekPlanId, athleteId: otherAthleteId, activityType: .individualTraining,
            title: "Other athlete's plan", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try reflectionService.recordParentObservation(
            athleteId: otherAthleteId, authorId: ActorId(), localDate: Self.weekStart, text: "Other athlete's note"
        )

        let context = try contextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(context.athleteId == athleteId)
        #expect(context.weekPlanStatus == nil)
        #expect(context.plannedActivityCount == 0)
        #expect(context.parentObservations.isEmpty)
    }

    @Test("The service itself excludes another week's data, not just the underlying coordination service")
    @MainActor
    func serviceLevelAnotherWeekExcluded() throws {
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
        let contextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: reflectionService
        )
        let planning = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let otherWeekStart = LocalDate(year: 2026, month: 2, day: 2)
        let otherWeekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: otherWeekStart)
        _ = try planning.addPlannedActivity(
            toWeekPlan: otherWeekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Other week's plan", localDate: otherWeekStart, timeZoneId: Self.oslo
        )
        _ = try reflectionService.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(), localDate: otherWeekStart, text: "Other week's note"
        )

        let context = try contextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: Self.weekStart)

        #expect(context.weekPlanStatus == nil)
        #expect(context.plannedActivityCount == 0)
        #expect(context.parentObservations.isEmpty)
    }
}
