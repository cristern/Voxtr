import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrNotificationsDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Activity Edit -> Split Activity: covers the ViewModel/UI-facing layer
// specifically — eligibility (`canSplit`), the local split draft
// (`beginSplit`/`addSplitChild`/`removeSplitChild`), and
// `splitActivity()`'s wiring into `PlanningService.splitPlannedActivity`.
// Domain-level split behavior (field inheritance, validation reuse,
// rollback, provenance) is covered directly in
// `PlanningServiceTests.swift`'s own "Activity Edit -> Split Activity"
// section — not duplicated here.
//
// Following `ActivityDetailReminderUITests`'s own already-accepted
// deviation from the S1.1 "no shared helpers" lesson: small inline
// fixture-assembly helpers are fine here since they only assemble
// already-constructed services, never share mutable state across tests.

/// A no-op `ActivityReminderScheduling` double — Split never touches
/// reminders, so nothing here needs to record/verify calls, unlike
/// `ActivityDetailReminderUITests`'s own recording fake.
private final class NoOpActivityReminderScheduler: ActivityReminderScheduling, @unchecked Sendable {
    func scheduleReminder(id: ActivityReminderId, fireDate: Date, content: ActivityReminderContent) {}
    func cancelReminder(id: ActivityReminderId) {}
    func authorizationStatus(completion: @escaping @MainActor @Sendable (ActivityReminderAuthorizationStatus) -> Void) {
        MainActor.assumeIsolated { completion(.authorized) }
    }
    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        MainActor.assumeIsolated { completion(true) }
    }
}

private struct FixedDateProvider: DateProvider {
    let now: Date
}

@Suite("ActivityDetailViewModel Split Activity (Activity Edit -> Split Activity)", .serialized)
struct ActivityDetailSplitActivityTests {

    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @MainActor
    private func makeFixture(container: ModelContainer) -> (
        planningService: PlanningService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService
    ) {
        let eventBus = EventBus()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext), eventBus: eventBus)
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext), eventBus: eventBus),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let activityReminderService = ActivityReminderService(
            repository: ActivityReminderRepository(modelContext: container.mainContext),
            scheduler: NoOpActivityReminderScheduler()
        )
        let notificationsPlanningCoordinationService = NotificationsPlanningCoordinationService(
            activityReminderService: activityReminderService,
            planningService: planningService,
            dateProvider: FixedDateProvider(now: Date(timeIntervalSince1970: 1_767_225_600))
        )
        notificationsPlanningCoordinationService.subscribeToEvents(eventBus)
        return (planningService, trainingReflectionCoordinationService, notificationsPlanningCoordinationService)
    }

    @MainActor
    private func makeActivity(planningService: PlanningService, athleteId: AthleteId) throws -> (weekPlan: WeekPlan, activity: PlannedActivity) {
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Hockey block", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 17, minute: 0), plannedDurationMinutes: 90
        )
        return (weekPlan, activity)
    }

    @MainActor
    private func makeViewModel(
        fixture: (
            planningService: PlanningService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService
        ),
        athleteId: AthleteId,
        weekPlan: WeekPlan,
        activity: PlannedActivity,
        isCompleted: Bool = false,
        loggedActivity: LoggedActivity? = nil,
        onActivityLogged: @escaping () -> Void = {}
    ) -> ActivityDetailViewModel {
        ActivityDetailViewModel(
            activity: activity, isCompleted: isCompleted, loggedActivity: loggedActivity,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: fixture.planningService,
            trainingReflectionCoordinationService: fixture.trainingReflectionCoordinationService,
            notificationsPlanningCoordinationService: fixture.notificationsPlanningCoordinationService,
            onActivityLogged: onActivityLogged
        )
    }

    @Test("Split eligibility (canSplit) is true for a draft-week, not-yet-logged activity")
    @MainActor
    func canSplitTrueForEligibleActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        #expect(viewModel.canSplit == true)
    }

    @Test("Split is not eligible once a LoggedActivity exists, and splitActivity() refuses to run even if called directly")
    @MainActor
    func canSplitFalseAndSplitActivityRefusesOnceLogged() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let logResult = try fixture.trainingReflectionCoordinationService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, sportId: nil, categoryIds: [],
            activityType: .individualTraining, title: activity.title, startedAt: Date(), durationMinutes: 90,
            status: .completed, authorId: ActorId(), sessionForm: nil
        )
        let viewModel = makeViewModel(
            fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity,
            isCompleted: true, loggedActivity: logResult.loggedActivity
        )

        #expect(viewModel.canSplit == false)

        // Simulates a stale/reused draft reaching splitActivity() some
        // other way than through the (hidden) "Split Activity" button —
        // the application-boundary guard this task requires, not only
        // the button's own conditional visibility.
        viewModel.splitChildren = [
            SplitChildDraft(activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 60),
            SplitChildDraft(activityType: .strength, startOffsetMinutes: 60, durationMinutes: 30)
        ]
        let succeeded = viewModel.splitActivity()

        #expect(succeeded == false)
        #expect(viewModel.errorMessage == PlanningStrings.splitNotEligible)
        #expect(try fixture.planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).count == 1)
    }

    @Test("beginSplit() initializes two default children from the CURRENTLY PERSISTED activity, never from an unsaved Edit draft")
    @MainActor
    func beginSplitReadsPersistedActivityNotUnsavedEditDraft() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        // An in-progress, UNSAVED Edit Planned Activity draft change —
        // must have no bearing on the split draft below.
        viewModel.editDurationMinutes = 15
        viewModel.editHasDuration = true

        viewModel.beginSplit()

        #expect(viewModel.splitChildren.count == 2)
        #expect(viewModel.splitChildren[0].activityType == .individualTraining)
        #expect(viewModel.splitChildren[0].startOffsetMinutes == 0)
        // 90 (the PERSISTED duration), never 15 (the unsaved edit draft).
        #expect(viewModel.splitChildren[0].durationMinutes == 90)
        #expect(viewModel.splitChildren[1].startOffsetMinutes == 90)
    }

    @Test("addSplitChild() and removeSplitChild() mutate only the local split draft")
    @MainActor
    func addAndRemoveSplitChildMutateDraft() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        viewModel.beginSplit()
        #expect(viewModel.splitChildren.count == 2)

        viewModel.addSplitChild()
        #expect(viewModel.splitChildren.count == 3)

        let middleId = viewModel.splitChildren[1].id
        viewModel.removeSplitChild(middleId)
        #expect(viewModel.splitChildren.count == 2)
        #expect(!viewModel.splitChildren.contains { $0.id == middleId })
    }

    @Test("splitActivity() with fewer than two children is rejected and canConfirmSplit reflects that")
    @MainActor
    func splitActivityRequiresTwoChildren() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        viewModel.beginSplit()
        viewModel.removeSplitChild(viewModel.splitChildren[1].id)
        #expect(viewModel.splitChildren.count == 1)
        #expect(viewModel.canConfirmSplit == false)

        let succeeded = viewModel.splitActivity()

        #expect(succeeded == false)
        #expect(viewModel.errorMessage == PlanningStrings.splitRequiresTwoChildren)
    }

    @Test("A successful split updates the ViewModel's activity, sets didSplitSuccessfully, and fires onActivityLogged")
    @MainActor
    func successfulSplitUpdatesViewModelAndFiresCallback() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        var loggedCount = 0
        let viewModel = makeViewModel(
            fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity,
            onActivityLogged: { loggedCount += 1 }
        )
        viewModel.beginSplit()
        #expect(viewModel.didSplitSuccessfully == false)

        let succeeded = viewModel.splitActivity()

        #expect(succeeded == true)
        #expect(viewModel.didSplitSuccessfully == true)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.activity.plannedActivityId == activity.plannedActivityId)
        #expect(viewModel.activity.plannedDurationMinutes == 90)
        #expect(loggedCount == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).count == 2)
    }

    @Test("No regression: saveEdit() still works normally on a ViewModel that also carries split draft state")
    @MainActor
    func saveEditStillWorksAlongsideSplitState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        viewModel.beginSplit()
        viewModel.addSplitChild()

        viewModel.editTitle = "Renamed block"
        let succeeded = viewModel.saveEdit()

        #expect(succeeded == true)
        #expect(viewModel.activity.title == "Renamed block")
        // The untouched split draft never leaked into the ordinary edit.
        #expect(try fixture.planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).count == 1)
    }
}
