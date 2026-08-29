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
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline (the
// `makeFixture`/`makeActivity` helpers below only assemble already-
// constructed services/fixtures, matching the same, already-accepted
// deviation `ActivityReminderLifecycleTests.makeServices` establishes).

/// Notifications V1 Activity Reminder UI slice: a recording,
/// deterministic, configurable test double for `ActivityReminderScheduling` —
/// never `UNUserNotificationCenter` — per this task's explicit "do not
/// use real UNUserNotificationCenter in deterministic unit tests" rule.
/// File-local (not shared with `ActivityReminderLifecycleTests.swift`'s
/// own, differently-scoped `FakeActivityReminderScheduler`), per this
/// project's "every test file builds its own inline" convention.
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

    /// Every call site (this app's production code, and every test
    /// below) is already `@MainActor` — `MainActor.assumeIsolated`
    /// asserts that at runtime rather than forcing this nonisolated,
    /// lock-guarded double to hop via `Task`, which would make these
    /// tests non-deterministic.
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

/// Deterministic "now" — every activity fixture below is dated in
/// January 2026, safely after this fixed reference, so lead-time/
/// past-fire-date arithmetic never depends on the real wall-clock date.
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

@Suite("ActivityDetailViewModel Reminder control (Notifications V1 Activity Reminder UI slice)", .serialized)
struct ActivityDetailReminderUITests {

    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @MainActor
    private func makeFixture(container: ModelContainer) -> (
        planningService: PlanningService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        scheduler: FakeActivityReminderScheduler
    ) {
        // A shared, real `EventBus` — the same production wiring
        // `CompositionRoot.build()` performs (`PlanningService`/
        // `TrainingService` publish; `NotificationsPlanningCoordinationService
        // .subscribeToEvents` reacts) — so `saveEdit()`/cancel/log
        // lifecycle reconciliation behaves exactly as it does in the
        // running app, not a hand-simulated approximation of it.
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
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
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

    @Test("Reminder control loads Off when no reminder intent exists")
    @MainActor
    func loadsOffWhenNoIntentExists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))

        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        #expect(viewModel.reminderEnabled == false)
        #expect(viewModel.canSetReminder == true)
    }

    @Test("An existing reminder loads with its correct lead time")
    @MainActor
    func loadsExistingReminderWithCorrectLeadTime() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        _ = try fixture.notificationsPlanningCoordinationService.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 20
        )

        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        #expect(viewModel.reminderEnabled == true)
        #expect(viewModel.reminderLeadTimeMinutes == 20)
    }

    @Test("Enabling with notifications already authorized creates and schedules a reminder")
    @MainActor
    func enablingWithAuthorizedNotificationsSchedulesReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        fixture.scheduler.authorizationStatusValue = .authorized
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.setReminderEnabled(true)

        #expect(viewModel.reminderEnabled == true)
        #expect(viewModel.reminderErrorMessage == nil)
        #expect(viewModel.reminderAuthorizationDenied == false)
        #expect(fixture.scheduler.scheduleCallCount == 1)
        #expect(fixture.scheduler.requestAuthorizationCallCount == 0)
    }

    @Test("The first enable from notDetermined requests authorization exactly once, then creates the reminder when granted")
    @MainActor
    func firstEnableFromNotDeterminedRequestsAuthorization() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        fixture.scheduler.authorizationStatusValue = .notDetermined
        fixture.scheduler.requestAuthorizationResult = true
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.setReminderEnabled(true)

        #expect(fixture.scheduler.requestAuthorizationCallCount == 1)
        #expect(viewModel.reminderEnabled == true)
        #expect(fixture.scheduler.scheduleCallCount == 1)
    }

    @Test("Denied authorization never creates an active reminder and surfaces the denied UI state")
    @MainActor
    func deniedAuthorizationDoesNotCreateReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        fixture.scheduler.authorizationStatusValue = .denied
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.setReminderEnabled(true)

        #expect(viewModel.reminderEnabled == false)
        #expect(viewModel.reminderAuthorizationDenied == true)
        #expect(fixture.scheduler.scheduleCallCount == 0)
        #expect(try fixture.notificationsPlanningCoordinationService.fetchReminder(forPlannedActivity: activity.plannedActivityId) == nil)
    }

    @Test("Declining the first-enable authorization prompt (notDetermined -> denied) never creates a reminder")
    @MainActor
    func decliningFirstEnableRequestDoesNotCreateReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        fixture.scheduler.authorizationStatusValue = .notDetermined
        fixture.scheduler.requestAuthorizationResult = false
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.setReminderEnabled(true)

        #expect(fixture.scheduler.requestAuthorizationCallCount == 1)
        #expect(viewModel.reminderEnabled == false)
        #expect(viewModel.reminderAuthorizationDenied == true)
        #expect(fixture.scheduler.scheduleCallCount == 0)
    }

    @Test("Turning Reminder Off cancels the scheduled notification and removes the reminder intent")
    @MainActor
    func turningOffCancelsReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let reminder = try fixture.notificationsPlanningCoordinationService.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 30
        )
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        #expect(viewModel.reminderEnabled == true)

        viewModel.setReminderEnabled(false)

        #expect(viewModel.reminderEnabled == false)
        #expect(fixture.scheduler.cancelledIds == [reminder.activityReminderId])
        #expect(try fixture.notificationsPlanningCoordinationService.fetchReminder(forPlannedActivity: activity.plannedActivityId) == nil)
    }

    @Test("Changing the lead time reschedules the SAME reminder under a new fire date")
    @MainActor
    func changingLeadTimeReschedules() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        viewModel.setReminderEnabled(true)
        let fireDateAt30 = fixture.scheduler.lastScheduleFireDate

        viewModel.setReminderLeadTimeMinutes(60)

        #expect(viewModel.reminderEnabled == true)
        #expect(viewModel.reminderLeadTimeMinutes == 60)
        #expect(fixture.scheduler.scheduleCallCount == 2)
        #expect(fixture.scheduler.lastScheduleFireDate != fireDateAt30)
        #expect(try fixture.notificationsPlanningCoordinationService.fetchReminder(forPlannedActivity: activity.plannedActivityId)?.leadTimeMinutes == 60)
    }

    @Test("An activity with no start time cannot have its reminder enabled")
    @MainActor
    func noStartTimePreventsEnabling() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: nil)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        #expect(viewModel.canSetReminder == false)

        viewModel.setReminderEnabled(true)

        #expect(viewModel.reminderEnabled == false)
        #expect(fixture.scheduler.scheduleCallCount == 0)
    }

    @Test("A lead time that would place the fire date in the past is handled safely — no reminder is left active")
    @MainActor
    func pastFireDateHandledSafely() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        // The fixed "now" is 2025-12-01 UTC; this activity's own fire
        // instant (2026-01-06 18:00 Oslo) minus an extreme lead time (7
        // days, the domain's own upper bound) still lands after "now" —
        // so instead this test makes the ACTIVITY itself already in the
        // past relative to the fixed reference, the same real-world case
        // ("a reminder set on an activity whose start time has already
        // gone by") this guard exists to catch.
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2025, month: 11, day: 3))
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2025, month: 11, day: 4), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.setReminderEnabled(true)

        #expect(viewModel.reminderEnabled == false)
        #expect(viewModel.reminderErrorMessage == PlanningStrings.reminderFireDateInPast)
        #expect(fixture.scheduler.scheduleCallCount == 0)
        #expect(try fixture.notificationsPlanningCoordinationService.fetchReminder(forPlannedActivity: activity.plannedActivityId) == nil)
    }

    @Test("Saving an edit that removes the start time cancels an active reminder and updates the displayed control")
    @MainActor
    func savingEditWithoutStartTimeCancelsReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId, startLocalTime: LocalTime(hour: 18, minute: 0))
        let reminder = try fixture.notificationsPlanningCoordinationService.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 30
        )
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        #expect(viewModel.reminderEnabled == true)

        viewModel.editHasStartTime = false
        #expect(viewModel.saveEdit() == true)

        #expect(viewModel.canSetReminder == false)
        #expect(viewModel.reminderEnabled == false)
        #expect(fixture.scheduler.cancelledIds == [reminder.activityReminderId])
    }
}
