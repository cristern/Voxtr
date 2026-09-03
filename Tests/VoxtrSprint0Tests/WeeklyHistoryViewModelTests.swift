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
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now,
            loggedByActorId: ActorId()
        )
        // Genuinely unplanned — no plannedActivityId at all.
        _ = try training.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Unplanned jog",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 6)) ?? .now,
            loggedByActorId: ActorId()
        )

        let viewModel = WeeklyHistoryViewModel(coordinationService: coordinator, athleteId: athleteId, weekStart: Self.weekStart)
        viewModel.load()

        #expect(viewModel.plannedCount == 2)
        #expect(viewModel.completedFromPlanCount == 1)
        #expect(viewModel.additionalCount == 1)
        #expect(viewModel.additionalLoggedActivities.first?.title == "Unplanned jog")
    }

    /// Review follow-up (cancellation sanity check): a cancelled planned
    /// activity is still counted in `plannedCount` (the plan itself is
    /// preserved, never deleted) but must NEVER inflate `completedFromPlanCount` —
    /// `.cancelled` and `.missed` are both "resolved" (an outcome
    /// exists) but neither is "completed training."
    @Test("completedFromPlanCount excludes Cancelled and Missed planned activities — cancellation is never counted as completed training")
    @MainActor
    func completedFromPlanCountExcludesCancelledAndMissed() throws {
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
        let completed = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Completed run", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        let cancelled = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Cancelled swim", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        let missed = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Missed session", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: completed.plannedActivityId,
            activityType: .individualTraining, title: "Completed run",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now,
            durationMinutes: 40, status: .completed,
            loggedByActorId: ActorId()
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: cancelled.plannedActivityId,
            activityType: .individualTraining, title: "Cancelled swim",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now,
            durationMinutes: 1, status: .cancelled,
            loggedByActorId: ActorId()
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: missed.plannedActivityId,
            activityType: .individualTraining, title: "Missed session",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now,
            durationMinutes: 1, status: .missed,
            loggedByActorId: ActorId()
        )

        let viewModel = WeeklyHistoryViewModel(coordinationService: coordinator, athleteId: athleteId, weekStart: Self.weekStart)
        viewModel.load()

        // The plan is preserved for all three — never deleted.
        #expect(viewModel.plannedCount == 3)
        // Only the genuinely completed one counts.
        #expect(viewModel.completedFromPlanCount == 1)
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

@Suite("WeeklyHistoryListViewModel (Weekly History & Reflection UX closeout)", .serialized)
struct WeeklyHistoryListViewModelTests {

    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @Test("A completely empty week is excluded; weeks with planned-only, logged-only, or reflection-only data are included, newest first")
    @MainActor
    func filtersEmptyWeeksAndOrdersNewestFirst() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
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
        let currentWeekStart = LocalDate(year: 2026, month: 1, day: 12) // a Monday
        let plannedOnlyWeek = currentWeekStart.adding(days: -7)
        let loggedOnlyWeek = currentWeekStart.adding(days: -14)
        let emptyWeek = currentWeekStart.adding(days: -21)
        let reflectionOnlyWeek = currentWeekStart.adding(days: -28)

        let plannedWeekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: plannedOnlyWeek)
        _ = try planning.addPlannedActivity(
            toWeekPlan: plannedWeekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Planned only", localDate: plannedOnlyWeek, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Logged only",
            startedAt: Calendar.current.date(from: DateComponents(year: 2025, month: 12, day: 30)) ?? .now,
            loggedByActorId: ActorId()
        )
        // emptyWeek: deliberately nothing at all.
        _ = try reflection.recordWeeklyReflection(
            athleteId: athleteId, weekStart: reflectionOnlyWeek, authorId: ActorId(),
            overallSatisfaction: 3, visibility: .sharedWithGuardians
        )

        let listViewModel = WeeklyHistoryListViewModel(coordinationService: coordinator, athleteId: athleteId, currentWeekStart: currentWeekStart)
        listViewModel.loadInitial()

        let includedWeeks = Set(listViewModel.summaries.map(\.weekStart))
        #expect(includedWeeks.contains(plannedOnlyWeek))
        #expect(includedWeeks.contains(loggedOnlyWeek))
        #expect(includedWeeks.contains(reflectionOnlyWeek))
        #expect(!includedWeeks.contains(emptyWeek))

        // Newest qualifying week first.
        #expect(listViewModel.summaries.first?.weekStart == plannedOnlyWeek)
    }
}

@Suite("WeeklyHistoryViewModel.reflectionAccessState (final privacy gate for Weekly History Reflection actions)", .serialized)
struct WeeklyHistoryReflectionAccessStateTests {

    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)

    @MainActor
    private static func makeViewModel(container: ModelContainer, athleteId: AthleteId) -> (WeeklyHistoryViewModel, WeeklyReflectionRepository) {
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
        let viewModel = WeeklyHistoryViewModel(coordinationService: coordinator, athleteId: athleteId, weekStart: weekStart)
        return (viewModel, weeklyReflectionRepository)
    }

    @Test("Case B: a visible/shared historical Reflection is exposed for editing to an authorized actor")
    @MainActor
    func visibleReflectionIsEditable() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let athleteId = AthleteId()
        let (viewModel, reflectionRepository) = Self.makeViewModel(container: container, athleteId: athleteId)
        let reflectionService = WeeklyReflectionService(repository: reflectionRepository)
        _ = try reflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: Self.weekStart, authorId: ActorId(),
            whatWorked: "Consistent sleep", visibility: .sharedWithGuardians
        )

        viewModel.load()

        guard case .visible(let reflection) = viewModel.reflectionAccessState else {
            Issue.record("Expected .visible — got \(viewModel.reflectionAccessState)"); return
        }
        #expect(reflection.whatWorked == "Consistent sleep")
    }

    @Test("Case C: a privateToAthlete Reflection is never exposed as content to the Parent actor")
    @MainActor
    func privateReflectionContentNeverExposed() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let athleteId = AthleteId()
        let (viewModel, reflectionRepository) = Self.makeViewModel(container: container, athleteId: athleteId)
        let reflectionService = WeeklyReflectionService(repository: reflectionRepository)
        _ = try reflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: Self.weekStart, authorId: ActorId(),
            whatWorked: "Private athlete-only note", visibility: .privateToAthlete
        )

        viewModel.load()

        // Never .visible — content must not be reachable through this
        // state at all.
        guard case .hiddenForPrivacy = viewModel.reflectionAccessState else {
            Issue.record("Expected .hiddenForPrivacy — got \(viewModel.reflectionAccessState)"); return
        }
    }

    @Test("Case C: Parent does not receive an Edit path for a private athlete Reflection")
    @MainActor
    func privateReflectionOffersNoEditPath() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let athleteId = AthleteId()
        let (viewModel, reflectionRepository) = Self.makeViewModel(container: container, athleteId: athleteId)
        let reflectionService = WeeklyReflectionService(repository: reflectionRepository)
        _ = try reflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: Self.weekStart, authorId: ActorId(),
            visibility: .privateToAthlete
        )

        viewModel.load()

        // .hiddenForPrivacy carries no reflection payload at all — the
        // view has no reflection value to wire an Edit action to,
        // structurally, not merely by convention.
        if case .visible = viewModel.reflectionAccessState {
            Issue.record("A private reflection must never surface as .visible, which is the only case the view offers Edit for")
        }
    }

    @Test("Case C: a hidden private Reflection is never mistaken for missing — Add is never offered where a Reflection already exists")
    @MainActor
    func hiddenPrivateReflectionIsNotMistakenForMissing() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let athleteId = AthleteId()
        let (viewModel, reflectionRepository) = Self.makeViewModel(container: container, athleteId: athleteId)
        let reflectionService = WeeklyReflectionService(repository: reflectionRepository)
        _ = try reflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: Self.weekStart, authorId: ActorId(),
            visibility: .privateToAthlete
        )

        viewModel.load()

        // Must be .hiddenForPrivacy, never .none — .none is the only
        // case the view offers "Add Reflection" for, and offering it
        // here would risk creating a competing/duplicate Reflection
        // for an athlete/week that already has one.
        if case .none = viewModel.reflectionAccessState {
            Issue.record("A private (existing) reflection must never be reported as .none — that would offer Add and risk a duplicate")
        }

        // Confirms the underlying data genuinely distinguishes the two
        // states: the reflection really does exist in the repository.
        let persisted = try reflectionRepository.fetchWeeklyReflection(forAthlete: athleteId, weekStart: Self.weekStart)
        #expect(persisted != nil)
    }

    @Test("Case A: a genuinely missing Reflection exposes the Add path")
    @MainActor
    func genuinelyMissingReflectionExposesAddPath() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let athleteId = AthleteId()
        let (viewModel, _) = Self.makeViewModel(container: container, athleteId: athleteId)
        // No reflection recorded at all for this athlete/week.

        viewModel.load()

        guard case .none = viewModel.reflectionAccessState else {
            Issue.record("Expected .none — got \(viewModel.reflectionAccessState)"); return
        }
    }
}
