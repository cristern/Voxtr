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
// Activity Reminder What/When: rewritten from PR #37's single-reminder
// shape to the generalized `ActivityDetailViewModel.reminders:
// [ActivityReminderDraft]` list — see that property's own doc comment.
// Domain/service-level multi-reminder coverage (coexistence, sibling
// isolation, lifecycle reconciliation) lives in
// `ActivityReminderLifecycleTests.swift`; this file covers the
// ViewModel/UI-facing layer specifically: prefill mapping, add/edit/
// remove, and per-row permission/error state.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline (the
// `makeFixture`/`makeActivity`/`makeViewModel` helpers below only
// assemble already-constructed services/fixtures, matching the same,
// already-accepted deviation `ActivityReminderLifecycleTests.makeServices`
// establishes).

/// A recording, deterministic, configurable test double for
/// `ActivityReminderScheduling` — never `UNUserNotificationCenter`.
/// File-local, per this project's "every test file builds its own
/// inline" convention.
private final class FakeActivityReminderScheduler: ActivityReminderScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _scheduleCallCount = 0
    private var _lastScheduleFireDate: Date?
    private var _cancelledIds: [ActivityReminderId] = []
    private var _authorizationStatus: ActivityReminderAuthorizationStatus = .authorized
    private var _requestAuthorizationResult: Bool = true
    private var _requestAuthorizationCallCount = 0

    var scheduleCallCount: Int { lock.lock(); defer { lock.unlock() }; return _scheduleCallCount }
    var lastScheduleFireDate: Date? { lock.lock(); defer { lock.unlock() }; return _lastScheduleFireDate }
    var cancelledIds: [ActivityReminderId] { lock.lock(); defer { lock.unlock() }; return _cancelledIds }
    var requestAuthorizationCallCount: Int { lock.lock(); defer { lock.unlock() }; return _requestAuthorizationCallCount }

    var authorizationStatusValue: ActivityReminderAuthorizationStatus {
        get { lock.lock(); defer { lock.unlock() }; return _authorizationStatus }
        set { lock.lock(); defer { lock.unlock() }; _authorizationStatus = newValue }
    }

    var requestAuthorizationResult: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _requestAuthorizationResult }
        set { lock.lock(); defer { lock.unlock() }; _requestAuthorizationResult = newValue }
    }

    func scheduleReminder(id: ActivityReminderId, fireDate: Date, content: ActivityReminderContent) {
        lock.lock(); defer { lock.unlock() }
        _scheduleCallCount += 1
        _lastScheduleFireDate = fireDate
    }

    func cancelReminder(id: ActivityReminderId) {
        lock.lock(); defer { lock.unlock() }
        _cancelledIds.append(id)
    }

    func authorizationStatus(completion: @escaping @MainActor @Sendable (ActivityReminderAuthorizationStatus) -> Void) {
        let status = authorizationStatusValue
        MainActor.assumeIsolated { completion(status) }
    }

    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        lock.lock()
        _requestAuthorizationCallCount += 1
        let result = _requestAuthorizationResult
        lock.unlock()
        MainActor.assumeIsolated { completion(result) }
    }
}

private struct FixedDateProvider: DateProvider {
    let now: Date
}

private func activityDetailReminderTestsFixedNow() -> Date {
    var components = DateComponents()
    components.year = 2025
    components.month = 12
    components.day = 1
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 1_764_547_200)
}

@Suite("ActivityDetailViewModel Reminder list (Activity Reminder What/When)", .serialized)
struct ActivityDetailReminderUITests {

    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @MainActor
    private func makeFixture(container: ModelContainer) -> (
        planningService: PlanningService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        scheduler: FakeActivityReminderScheduler
    ) {
        let eventBus = EventBus()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext), eventBus: eventBus)
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext), eventBus: eventBus),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let scheduler = FakeActivityReminderScheduler()
        let activityReminderService = ActivityReminderService(
            repository: ActivityReminderRepository(modelContext: container.mainContext),
            scheduler: scheduler
        )
        let notificationsPlanningCoordinationService = NotificationsPlanningCoordinationService(
            activityReminderService: activityReminderService,
            planningService: planningService,
            dateProvider: FixedDateProvider(now: activityDetailReminderTestsFixedNow())
        )
        notificationsPlanningCoordinationService.subscribeToEvents(eventBus)
        return (planningService, trainingReflectionCoordinationService, notificationsPlanningCoordinationService, scheduler)
    }

    @MainActor
    private func makeActivity(
        planningService: PlanningService,
        athleteId: AthleteId,
        startLocalTime: LocalTime?
    ) throws -> (weekPlan: WeekPlan, activity: PlannedActivity) {
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: startLocalTime
        )
        return (weekPlan, activity)
    }

    @MainActor
    private func makeViewModel(
        fixture: (
            planningService: PlanningService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
            scheduler: FakeActivityReminderScheduler
        ),
        athleteId: AthleteId,
        weekPlan: WeekPlan,
        activity: PlannedActivity
    ) -> ActivityDetailViewModel {
        ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: fixture.planningService,
            trainingReflectionCoordinationService: fixture.trainingReflectionCoordinationService,
            notificationsPlanningCoordinationService: fixture.notificationsPlanningCoordinationService
        )
    }

    @Test("Reminder list loads empty when no reminders exist")
    @MainActor
    func loadsEmptyWhenNoRemindersExist() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))

        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        #expect(viewModel.reminders.isEmpty)
        #expect(viewModel.canSetReminder == true)
    }

    /// Item 16: multiple existing reminders load with their own correct
    /// text and lead time.
    @Test("Multiple existing reminders load with their own correct text and lead time")
    @MainActor
    func loadsMultipleExistingRemindersCorrectly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let eat = try fixture.notificationsPlanningCoordinationService.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 120, reminderText: "Eat"
        )
        let packBag = try fixture.notificationsPlanningCoordinationService.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 45, reminderText: "Pack bag"
        )

        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        #expect(viewModel.reminders.count == 2)
        #expect(viewModel.reminders.contains { $0.persistedId == eat.activityReminderId && $0.text == "Eat" && $0.leadTimeMinutes == 120 })
        #expect(viewModel.reminders.contains { $0.persistedId == packBag.activityReminderId && $0.text == "Pack bag" && $0.leadTimeMinutes == 45 })
    }

    /// Item 18: a pre-existing PR #37-era reminder (created before
    /// `reminderText` existed, persisted with `nil`) is still
    /// represented — as an empty-text draft, never a fabricated value —
    /// by the new generalized multi-reminder model.
    @Test("A legacy reminder with no user-authored text loads as an empty-text draft, not a fabricated value")
    @MainActor
    func loadsLegacyReminderWithNoTextAsEmptyDraft() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        // Directly through the repository, bypassing reminderText, to
        // simulate a row created before this field existed.
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let legacy = try repository.insert(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 30)
        #expect(legacy.reminderText == nil)

        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        #expect(viewModel.reminders.count == 1)
        #expect(viewModel.reminders.first?.text == "")
        #expect(viewModel.reminders.first?.leadTimeMinutes == 30)
        #expect(viewModel.reminders.first?.persistedId == legacy.activityReminderId)
    }

    @Test("Committing a new reminder with authorized notifications creates and schedules it")
    @MainActor
    func committingNewReminderWithAuthorizedNotificationsSchedules() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        fixture.scheduler.authorizationStatusValue = .authorized
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.addReminder()
        #expect(viewModel.reminders.count == 1)
        viewModel.reminders[0].text = "Pack bag"
        viewModel.commitReminder(viewModel.reminders[0])

        #expect(viewModel.reminders.first?.persistedId != nil)
        #expect(viewModel.reminders.first?.errorMessage == nil)
        #expect(viewModel.reminders.first?.authorizationDenied == false)
        #expect(fixture.scheduler.scheduleCallCount == 1)
        #expect(fixture.scheduler.requestAuthorizationCallCount == 0)
    }

    @Test("The first commit from notDetermined requests authorization exactly once, then creates the reminder when granted")
    @MainActor
    func firstCommitFromNotDeterminedRequestsAuthorization() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        fixture.scheduler.authorizationStatusValue = .notDetermined
        fixture.scheduler.requestAuthorizationResult = true
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.addReminder()
        viewModel.reminders[0].text = "Eat"
        viewModel.commitReminder(viewModel.reminders[0])

        #expect(fixture.scheduler.requestAuthorizationCallCount == 1)
        #expect(viewModel.reminders.first?.persistedId != nil)
        #expect(fixture.scheduler.scheduleCallCount == 1)
    }

    @Test("Denied authorization never creates the reminder and surfaces the denied state on that row")
    @MainActor
    func deniedAuthorizationDoesNotCreateReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        fixture.scheduler.authorizationStatusValue = .denied
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.addReminder()
        viewModel.reminders[0].text = "Eat"
        viewModel.commitReminder(viewModel.reminders[0])

        #expect(viewModel.reminders.first?.persistedId == nil)
        #expect(viewModel.reminders.first?.authorizationDenied == true)
        #expect(fixture.scheduler.scheduleCallCount == 0)
        #expect(try fixture.notificationsPlanningCoordinationService.fetchReminders(forPlannedActivity: activity.plannedActivityId).isEmpty)
    }

    /// Item 17 (edit direction): editing an already-persisted reminder's
    /// text/lead time updates the SAME reminder in place — never
    /// creates a second one.
    @Test("Editing an already-persisted reminder updates it in place under the same identity")
    @MainActor
    func editingPersistedReminderUpdatesInPlace() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let created = try fixture.notificationsPlanningCoordinationService.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 30, reminderText: "Eat"
        )
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        #expect(viewModel.reminders.count == 1)

        viewModel.reminders[0].text = "Eat breakfast"
        viewModel.reminders[0].leadTimeMinutes = 60
        viewModel.commitReminder(viewModel.reminders[0])

        #expect(viewModel.reminders.count == 1)
        #expect(viewModel.reminders.first?.persistedId == created.activityReminderId)
        let all = try fixture.notificationsPlanningCoordinationService.fetchReminders(forPlannedActivity: activity.plannedActivityId)
        #expect(all.count == 1)
        #expect(all.first?.activityReminderId == created.activityReminderId)
        #expect(all.first?.reminderText == "Eat breakfast")
        #expect(all.first?.leadTimeMinutes == 60)
    }

    /// Item 17 (remove direction): removing one reminder cancels/removes
    /// only that one, leaving a sibling reminder untouched.
    @Test("Removing one reminder cancels only that one, leaving a sibling reminder untouched")
    @MainActor
    func removingOneReminderLeavesSiblingUntouched() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let eat = try fixture.notificationsPlanningCoordinationService.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 120, reminderText: "Eat"
        )
        let packBag = try fixture.notificationsPlanningCoordinationService.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 45, reminderText: "Pack bag"
        )
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        #expect(viewModel.reminders.count == 2)

        let eatDraft = try #require(viewModel.reminders.first { $0.persistedId == eat.activityReminderId })
        viewModel.removeReminder(eatDraft)

        #expect(viewModel.reminders.count == 1)
        #expect(viewModel.reminders.first?.persistedId == packBag.activityReminderId)
        #expect(fixture.scheduler.cancelledIds == [eat.activityReminderId])
        let remaining = try fixture.notificationsPlanningCoordinationService.fetchReminders(forPlannedActivity: activity.plannedActivityId)
        #expect(remaining.count == 1)
        #expect(remaining.first?.activityReminderId == packBag.activityReminderId)
    }

    @Test("An activity with no start time cannot have a reminder committed")
    @MainActor
    func noStartTimePreventsCommit() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: nil)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        #expect(viewModel.canSetReminder == false)

        viewModel.addReminder()
        viewModel.reminders[0].text = "Eat"
        viewModel.commitReminder(viewModel.reminders[0])

        #expect(viewModel.reminders.first?.persistedId == nil)
        #expect(fixture.scheduler.scheduleCallCount == 0)
    }

    @Test("A lead time that would place the fire date in the past is handled safely — no reminder is left active")
    @MainActor
    func pastFireDateHandledSafely() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        // Fixed "now" is 2025-12-01 UTC; this activity's own date is
        // already before that, so any positive lead time resolves to a
        // fire date in the past — the same real-world case ("a reminder
        // set on an activity whose start time has already gone by")
        // this guard exists to catch.
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2025, month: 11, day: 3))
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2025, month: 11, day: 4), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.addReminder()
        viewModel.reminders[0].text = "Eat"
        viewModel.commitReminder(viewModel.reminders[0])

        #expect(viewModel.reminders.first?.persistedId == nil)
        #expect(viewModel.reminders.first?.errorMessage == PlanningStrings.reminderFireDateInPast)
        #expect(fixture.scheduler.scheduleCallCount == 0)
        #expect(try fixture.notificationsPlanningCoordinationService.fetchReminders(forPlannedActivity: activity.plannedActivityId).isEmpty)
    }

    @Test("Committing an empty-text draft is a no-op — nothing is persisted")
    @MainActor
    func committingEmptyTextDraftIsNoOp() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.addReminder()
        viewModel.commitReminder(viewModel.reminders[0])

        #expect(viewModel.reminders.first?.persistedId == nil)
        #expect(fixture.scheduler.scheduleCallCount == 0)
    }

    @Test("Saving an edit that removes the start time cancels every reminder and updates the displayed list")
    @MainActor
    func savingEditWithoutStartTimeCancelsAllReminders() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let eat = try fixture.notificationsPlanningCoordinationService.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 120, reminderText: "Eat"
        )
        let packBag = try fixture.notificationsPlanningCoordinationService.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 45, reminderText: "Pack bag"
        )
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        #expect(viewModel.reminders.count == 2)

        viewModel.editHasStartTime = false
        #expect(viewModel.saveEdit() == true)

        #expect(viewModel.canSetReminder == false)
        #expect(viewModel.reminders.isEmpty)
        #expect(Set(fixture.scheduler.cancelledIds) == Set([eat.activityReminderId, packBag.activityReminderId]))
    }
}
