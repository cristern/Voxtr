import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrNotificationsDomain
@testable import VoxtrAppShell

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

/// A thin, deterministic, thread-safe recording test double for
/// `ActivityReminderScheduling` — the exact seam this task's "scheduling
/// boundary" requirement exists to make possible: every test below
/// exercises real domain/application logic (`ActivityReminderService`,
/// `NotificationsPlanningCoordinationService`) without ever touching
/// `UNUserNotificationCenter`. A plain, non-actor-isolated `final class`
/// guarded by `NSLock` — the same `@unchecked Sendable` pattern this
/// project's own `DIContainer` already establishes — so it can be called
/// synchronously from `@MainActor` test code with no actor-hop of its
/// own to reason about.
private final class FakeActivityReminderScheduler: ActivityReminderScheduling, @unchecked Sendable {
    struct ScheduleCall: Equatable {
        let id: ActivityReminderId
        let fireDate: Date
        let content: ActivityReminderContent
    }

    private let lock = NSLock()
    private var _scheduleCalls: [ScheduleCall] = []
    private var _cancelledIds: [ActivityReminderId] = []
    /// PR #36 follow-up: net pending state per id — the LAST operation
    /// recorded for a given `ActivityReminderId` (schedule vs. cancel),
    /// so a test can ask "is this reminder still pending right now" in
    /// one call instead of reasoning about call-order itself.
    private var _pendingIds: Set<ActivityReminderId> = []
    /// Notifications V1 Activity Reminder UI slice: configurable
    /// authorization state — defaults to `.authorized` so every existing
    /// test above (which never touches `enableReminder`/authorization at
    /// all) is unaffected; a UI-slice test overrides this before calling
    /// `NotificationsPlanningCoordinationService.enableReminder`.
    private var _authorizationStatus: ActivityReminderAuthorizationStatus = .authorized
    private var _requestAuthorizationResult: Bool = true
    private var _requestAuthorizationCallCount = 0

    var scheduleCalls: [ScheduleCall] {
        lock.lock(); defer { lock.unlock() }
        return _scheduleCalls
    }

    var cancelledIds: [ActivityReminderId] {
        lock.lock(); defer { lock.unlock() }
        return _cancelledIds
    }

    var authorizationStatusValue: ActivityReminderAuthorizationStatus {
        get { lock.lock(); defer { lock.unlock() }; return _authorizationStatus }
        set { lock.lock(); defer { lock.unlock() }; _authorizationStatus = newValue }
    }

    var requestAuthorizationResult: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _requestAuthorizationResult }
        set { lock.lock(); defer { lock.unlock() }; _requestAuthorizationResult = newValue }
    }

    var requestAuthorizationCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestAuthorizationCallCount
    }

    func isPending(_ id: ActivityReminderId) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _pendingIds.contains(id)
    }

    func scheduleReminder(id: ActivityReminderId, fireDate: Date, content: ActivityReminderContent) {
        lock.lock(); defer { lock.unlock() }
        _scheduleCalls.append(ScheduleCall(id: id, fireDate: fireDate, content: content))
        _pendingIds.insert(id)
    }

    func cancelReminder(id: ActivityReminderId) {
        lock.lock(); defer { lock.unlock() }
        _cancelledIds.append(id)
        _pendingIds.remove(id)
    }

    /// Every call site in this app (and in these tests) is already
    /// `@MainActor` — same guarantee the protocol's own doc comment
    /// describes for every real caller. `MainActor.assumeIsolated`
    /// asserts that at runtime rather than requiring this nonisolated
    /// (lock-guarded, `@unchecked Sendable`) test double to hop via
    /// `Task`, which would make these tests non-deterministic — the
    /// exact class of bug PR #36's own follow-up removed from production.
    func authorizationStatus(completion: @escaping @MainActor @Sendable (ActivityReminderAuthorizationStatus) -> Void) {
        let status = authorizationStatusValue
        MainActor.assumeIsolated {
            completion(status)
        }
    }

    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        lock.lock()
        _requestAuthorizationCallCount += 1
        let result = _requestAuthorizationResult
        lock.unlock()
        MainActor.assumeIsolated {
            completion(result)
        }
    }
}

// MARK: - ActivityReminderService (scheduling lifecycle + identity)

@Suite("ActivityReminderService (Notifications V1 Activity Reminder Foundation)", .serialized)
struct ActivityReminderServiceTests {

    @Test("Creating a reminder persists it and schedules the expected request")
    @MainActor
    func createReminderPersistsAndSchedules() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let service = ActivityReminderService(repository: repository, scheduler: scheduler)
        let athleteId = AthleteId()
        let plannedActivityId = PlannedActivityId()
        let fireDate = Date(timeIntervalSince1970: 1_800_000_000)
        let content = ActivityReminderContent(title: "Endurance run", body: "Starting soon")

        let reminder = try service.createReminder(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            leadTimeMinutes: 30,
            fireDate: fireDate,
            content: content
        )

        #expect(reminder.leadTimeMinutes == 30)
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReminder>()).count == 1)
        #expect(scheduler.scheduleCalls.count == 1)
        #expect(scheduler.scheduleCalls.first?.id == reminder.activityReminderId)
        #expect(scheduler.scheduleCalls.first?.fireDate == fireDate)
        #expect(scheduler.scheduleCalls.first?.content == content)
    }

    /// Activity Reminder What/When, item 1-3: a concrete `PlannedActivity`
    /// may have zero, one, or MULTIPLE independent reminders — creating
    /// a second one for the same activity must never replace or remove
    /// the first, and each retains its own text/lead time/schedule.
    @Test("Creating a second reminder for the same activity does not replace the first — both coexist independently")
    @MainActor
    func createReminderDoesNotReplaceExistingOne() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let service = ActivityReminderService(repository: repository, scheduler: scheduler)
        let athleteId = AthleteId()
        let plannedActivityId = PlannedActivityId()

        let first = try service.createReminder(
            athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: 30, reminderText: "Eat",
            fireDate: Date(timeIntervalSince1970: 1_800_000_000),
            content: ActivityReminderContent(title: "Eat", body: "A")
        )
        let second = try service.createReminder(
            athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: 15, reminderText: "Pack bag",
            fireDate: Date(timeIntervalSince1970: 1_800_100_000),
            content: ActivityReminderContent(title: "Pack bag", body: "B")
        )

        #expect(first.activityReminderId != second.activityReminderId)
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReminder>()).count == 2)
        let all = try repository.fetchAll(forPlannedActivity: plannedActivityId)
        #expect(all.count == 2)
        #expect(all.contains { $0.activityReminderId == first.activityReminderId && $0.leadTimeMinutes == 30 && $0.reminderText == "Eat" })
        #expect(all.contains { $0.activityReminderId == second.activityReminderId && $0.leadTimeMinutes == 15 && $0.reminderText == "Pack bag" })
        // Neither reminder was ever cancelled by the other's creation.
        #expect(scheduler.cancelledIds.isEmpty)
        #expect(scheduler.scheduleCalls.map(\.id) == [first.activityReminderId, second.activityReminderId])
    }

    /// Item 4: updating or removing one reminder must never affect a
    /// sibling reminder for the same activity.
    @Test("Updating one reminder's lead time/text does not affect a sibling reminder for the same activity")
    @MainActor
    func updateReminderDoesNotAffectSibling() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let service = ActivityReminderService(repository: repository, scheduler: scheduler)
        let athleteId = AthleteId()
        let plannedActivityId = PlannedActivityId()
        let first = try service.createReminder(
            athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: 30, reminderText: "Eat",
            fireDate: Date(timeIntervalSince1970: 1_800_000_000), content: ActivityReminderContent(title: "Eat", body: "A")
        )
        let second = try service.createReminder(
            athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: 15, reminderText: "Pack bag",
            fireDate: Date(timeIntervalSince1970: 1_800_100_000), content: ActivityReminderContent(title: "Pack bag", body: "B")
        )

        let updatedFireDate = Date(timeIntervalSince1970: 1_900_000_000)
        let updated = try service.updateReminder(
            first.activityReminderId, leadTimeMinutes: 60, reminderText: "Eat breakfast",
            fireDate: updatedFireDate, content: ActivityReminderContent(title: "Eat breakfast", body: "A")
        )

        #expect(updated.activityReminderId == first.activityReminderId)
        #expect(updated.leadTimeMinutes == 60)
        #expect(updated.reminderText == "Eat breakfast")
        let secondUnchanged = try repository.fetch(byId: second.activityReminderId)
        #expect(secondUnchanged?.leadTimeMinutes == 15)
        #expect(secondUnchanged?.reminderText == "Pack bag")
        #expect(scheduler.cancelledIds.isEmpty)
    }

    /// Item 4 (removal direction): cancelling ONE reminder by its own id
    /// never affects a sibling reminder for the same activity.
    @Test("Cancelling one reminder removes its intent row and cancels its notification, leaving a sibling reminder untouched")
    @MainActor
    func cancelReminderRemovesAndCancelsWithoutAffectingSibling() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let service = ActivityReminderService(repository: repository, scheduler: scheduler)
        let athleteId = AthleteId()
        let plannedActivityId = PlannedActivityId()
        let first = try service.createReminder(
            athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: 30, reminderText: "Eat",
            fireDate: Date(timeIntervalSince1970: 1_800_000_000), content: ActivityReminderContent(title: "Eat", body: "A")
        )
        let second = try service.createReminder(
            athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: 15, reminderText: "Pack bag",
            fireDate: Date(timeIntervalSince1970: 1_800_100_000), content: ActivityReminderContent(title: "Pack bag", body: "B")
        )

        try service.cancelReminder(first.activityReminderId)

        #expect(try repository.fetch(byId: first.activityReminderId) == nil)
        #expect(scheduler.cancelledIds == [first.activityReminderId])
        let remaining = try repository.fetchAll(forPlannedActivity: plannedActivityId)
        #expect(remaining.count == 1)
        #expect(remaining.first?.activityReminderId == second.activityReminderId)
    }

    @Test("Cancelling when no reminder with that id is active is a safe no-op")
    @MainActor
    func cancelReminderNoOpWhenNoneActive() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let service = ActivityReminderService(repository: repository, scheduler: scheduler)

        try service.cancelReminder(ActivityReminderId())

        #expect(scheduler.cancelledIds.isEmpty)
    }

    /// `cancelAllReminders(forPlannedActivity:)` — the lifecycle-handler
    /// primitive (activity deleted/logged/start-time-removed) — must
    /// cancel and remove EVERY reminder for one activity, never only
    /// the first.
    @Test("cancelAllReminders cancels and removes every reminder for one activity")
    @MainActor
    func cancelAllRemindersRemovesEveryReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let service = ActivityReminderService(repository: repository, scheduler: scheduler)
        let plannedActivityId = PlannedActivityId()
        let first = try service.createReminder(
            athleteId: AthleteId(), plannedActivityId: plannedActivityId, leadTimeMinutes: 30, reminderText: "Eat",
            fireDate: Date(timeIntervalSince1970: 1_800_000_000), content: ActivityReminderContent(title: "Eat", body: "A")
        )
        let second = try service.createReminder(
            athleteId: AthleteId(), plannedActivityId: plannedActivityId, leadTimeMinutes: 15, reminderText: "Pack bag",
            fireDate: Date(timeIntervalSince1970: 1_800_100_000), content: ActivityReminderContent(title: "Pack bag", body: "B")
        )

        try service.cancelAllReminders(forPlannedActivity: plannedActivityId)

        #expect(Set(scheduler.cancelledIds) == Set([first.activityReminderId, second.activityReminderId]))
        #expect(try repository.fetchAll(forPlannedActivity: plannedActivityId).isEmpty)
    }

    @Test("Rescheduling an existing reminder updates its fire date under the SAME stable identity — never a new id")
    @MainActor
    func rescheduleReminderUsesStableIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let service = ActivityReminderService(repository: repository, scheduler: scheduler)
        let plannedActivityId = PlannedActivityId()
        let reminder = try service.createReminder(
            athleteId: AthleteId(), plannedActivityId: plannedActivityId, leadTimeMinutes: 30,
            fireDate: Date(timeIntervalSince1970: 1_800_000_000),
            content: ActivityReminderContent(title: "A", body: "A")
        )

        let newFireDate = Date(timeIntervalSince1970: 1_900_000_000)
        let newContent = ActivityReminderContent(title: "A (moved)", body: "Starting soon")
        service.rescheduleReminder(reminder, fireDate: newFireDate, content: newContent)

        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReminder>()).count == 1)
        #expect(scheduler.scheduleCalls.count == 2)
        // Identity: both calls target the exact same ActivityReminderId,
        // proving rescheduling never creates a new underlying request
        // identity just because content/fire date changed.
        #expect(scheduler.scheduleCalls[0].id == reminder.activityReminderId)
        #expect(scheduler.scheduleCalls[1].id == reminder.activityReminderId)
        #expect(scheduler.scheduleCalls[1].fireDate == newFireDate)
        #expect(scheduler.scheduleCalls[1].content == newContent)
    }
}

/// Notifications V1 Activity Reminder UI slice: a deterministic,
/// fixed-`now` `DateProvider` — same pattern
/// `DailyQuoteProviderTests.FixedDateProvider` already establishes for
/// this exact purpose. `NotificationsPlanningCoordinationService.createReminder`
/// now rejects a fire date that has already passed relative to
/// `dateProvider.now`; every fixture below uses `LocalDate(year: 2026, ...)`
/// activity dates, so this fixed "now" is pinned safely BEFORE all of
/// them — decoupling these tests from the real wall-clock date (which,
/// left as the default `SystemDateProvider()`, would make every one of
/// these 2026 fixtures silently start failing the moment real time
/// passes 2026 — exactly the class of non-determinism CLAUDE.md's
/// testing rules forbid).
private struct FixedDateProvider: DateProvider {
    let now: Date
}

private func notificationsLifecycleTestsFixedNow() -> Date {
    var components = DateComponents()
    components.year = 2025
    components.month = 12
    components.day = 1
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 1_764_547_200)
}

// MARK: - NotificationsPlanningCoordinationService (cross-domain lifecycle)

@Suite("NotificationsPlanningCoordinationService (Notifications V1 Activity Reminder Foundation)", .serialized)
struct NotificationsPlanningCoordinationServiceTests {

    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @MainActor
    private func makeServices(container: ModelContainer) -> (
        planning: PlanningService,
        coordination: NotificationsPlanningCoordinationService,
        scheduler: FakeActivityReminderScheduler,
        activityReminderRepository: ActivityReminderRepository
    ) {
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let activityReminderRepository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let activityReminderService = ActivityReminderService(repository: activityReminderRepository, scheduler: scheduler)
        let coordination = NotificationsPlanningCoordinationService(
            activityReminderService: activityReminderService,
            planningService: planningService,
            dateProvider: FixedDateProvider(now: notificationsLifecycleTestsFixedNow())
        )
        return (planningService, coordination, scheduler, activityReminderRepository)
    }

    @Test("createReminder computes the fire instant from the canonical activity's date/time/timezone minus the lead time")
    @MainActor
    func createReminderComputesFireDateFromCanonicalTruth() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, _) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )

        let reminder = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 45)

        let expectedFireInstant = try LocalDate(year: 2026, month: 1, day: 6).absoluteDate(at: LocalTime(hour: 18, minute: 0), in: Self.oslo)
        let expectedFireDate = expectedFireInstant.addingTimeInterval(-45 * 60)
        #expect(scheduler.scheduleCalls.count == 1)
        #expect(scheduler.scheduleCalls.first?.id == reminder.activityReminderId)
        #expect(scheduler.scheduleCalls.first?.fireDate == expectedFireDate)
        #expect(scheduler.scheduleCalls.first?.content.title == "Endurance run")
    }

    @Test("createReminder applies a different lead time to a different fire date, with everything else held constant")
    @MainActor
    func createReminderAppliesLeadTimeCorrectly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, _) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )

        _ = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 10)

        let expectedFireInstant = try LocalDate(year: 2026, month: 1, day: 6).absoluteDate(at: LocalTime(hour: 18, minute: 0), in: Self.oslo)
        #expect(scheduler.scheduleCalls.first?.fireDate == expectedFireInstant.addingTimeInterval(-10 * 60))
    }

    /// PR #37 follow-up: the prior `0...10080` (7-day) ceiling on
    /// `ActivityReminder.leadTimeMinutes` was an unapproved product
    /// limit — Custom must support arbitrary lead time before the
    /// activity. 20 days (28,800 minutes) is comfortably beyond the old
    /// ceiling; this proves it is no longer enforced anywhere in the
    /// create path, not merely relaxed to a different, still-arbitrary
    /// number.
    @Test("createReminder accepts a lead time well beyond the old, unapproved 7-day (10080-minute) ceiling")
    @MainActor
    func createReminderAcceptsLeadTimeBeyondSevenDays() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, _) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Season opener", localDate: LocalDate(year: 2026, month: 3, day: 3), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let twentyDaysInMinutes = 20 * 24 * 60

        let reminder = try coordination.createReminder(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: twentyDaysInMinutes
        )

        let expectedFireInstant = try LocalDate(year: 2026, month: 3, day: 3).absoluteDate(at: LocalTime(hour: 18, minute: 0), in: Self.oslo)
        let expectedFireDate = expectedFireInstant.addingTimeInterval(-Double(twentyDaysInMinutes) * 60)
        #expect(reminder.leadTimeMinutes == twentyDaysInMinutes)
        #expect(scheduler.scheduleCalls.count == 1)
        #expect(scheduler.scheduleCalls.first?.fireDate == expectedFireDate)
    }

    @Test("createReminder rejects a PlannedActivity that belongs to a different athlete")
    @MainActor
    func createReminderRejectsCrossAthleteActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, _) = makeServices(container: container)
        let ownerAthleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: ownerAthleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: ownerAthleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )

        #expect(throws: NotificationsPlanningCoordinationService.CoordinationError.plannedActivityBelongsToDifferentAthlete) {
            try coordination.createReminder(athleteId: otherAthleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 10)
        }
        #expect(scheduler.scheduleCalls.isEmpty)
    }

    @Test("createReminder rejects a PlannedActivity with no concrete start time")
    @MainActor
    func createReminderRejectsActivityWithNoStartTime() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, _) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo
        )

        #expect(throws: NotificationsPlanningCoordinationService.CoordinationError.plannedActivityHasNoStartTime) {
            try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 10)
        }
        #expect(scheduler.scheduleCalls.isEmpty)
    }

    @Test("handlePlannedActivityChanged reschedules an active reminder from the CURRENT canonical date/time, not any cached value")
    @MainActor
    func handlePlannedActivityChangedReschedulesFromCurrentTruth() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, _) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        _ = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 30)
        #expect(scheduler.scheduleCalls.count == 1)

        // The activity moves to a new date/time — the authoritative
        // Planning mutation, exactly what PlanningService.editPlannedActivity
        // performs in production before publishing PlannedActivityChanged.
        _ = try planning.editPlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 8), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 7, minute: 0)
        )

        coordination.handlePlannedActivityChanged(
            PlannedActivityChanged(plannedActivityId: activity.plannedActivityId, athleteId: athleteId, weekPlanId: weekPlan.weekPlanId, changeType: "edited")
        )

        let expectedNewFireInstant = try LocalDate(year: 2026, month: 1, day: 8).absoluteDate(at: LocalTime(hour: 7, minute: 0), in: Self.oslo)
        #expect(scheduler.scheduleCalls.count == 2)
        #expect(scheduler.scheduleCalls[1].id == scheduler.scheduleCalls[0].id)
        #expect(scheduler.scheduleCalls[1].fireDate == expectedNewFireInstant.addingTimeInterval(-30 * 60))
    }

    @Test("handlePlannedActivityChanged reflects a timezone change in the recomputed fire instant")
    @MainActor
    func handlePlannedActivityChangedReflectsTimeZoneChange() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, _) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        _ = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 0)

        // Same local date/time, but the activity's OWN canonical time
        // zone changes — Auckland, not the reader's device.
        let auckland = TimeZoneId(rawValue: "Pacific/Auckland")
        _ = try planning.editPlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: auckland,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        coordination.handlePlannedActivityChanged(
            PlannedActivityChanged(plannedActivityId: activity.plannedActivityId, athleteId: athleteId, weekPlanId: weekPlan.weekPlanId, changeType: "edited")
        )

        let expectedOsloFireDate = try LocalDate(year: 2026, month: 1, day: 6).absoluteDate(at: LocalTime(hour: 18, minute: 0), in: Self.oslo)
        let expectedAucklandFireDate = try LocalDate(year: 2026, month: 1, day: 6).absoluteDate(at: LocalTime(hour: 18, minute: 0), in: auckland)
        #expect(expectedOsloFireDate != expectedAucklandFireDate)
        #expect(scheduler.scheduleCalls.last?.fireDate == expectedAucklandFireDate)
    }

    @Test("handlePlannedActivityChanged is a safe no-op when no reminder is active for that activity")
    @MainActor
    func handlePlannedActivityChangedNoOpWhenNoReminderActive() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, _) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )

        coordination.handlePlannedActivityChanged(
            PlannedActivityChanged(plannedActivityId: activity.plannedActivityId, athleteId: athleteId, weekPlanId: weekPlan.weekPlanId, changeType: "edited")
        )

        #expect(scheduler.scheduleCalls.isEmpty)
    }

    @Test("handlePlannedActivityDeleted cancels the pending reminder and removes its intent row — no orphan left behind")
    @MainActor
    func handlePlannedActivityDeletedCancelsReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, activityReminderRepository) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let reminder = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 30)

        try planning.deletePlannedActivity(activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, deletedBy: ActorId())
        coordination.handlePlannedActivityDeleted(PlannedActivityDeleted(plannedActivityId: activity.plannedActivityId, athleteId: athleteId))

        #expect(scheduler.cancelledIds == [reminder.activityReminderId])
        #expect(try activityReminderRepository.fetchAll(forPlannedActivity: activity.plannedActivityId).isEmpty)
    }

    /// Item 6 (multiple reminders): activity deletion must reconcile
    /// EVERY reminder belonging to that activity, never only the first
    /// one created.
    @Test("handlePlannedActivityDeleted cancels EVERY reminder for that activity, not only the first")
    @MainActor
    func handlePlannedActivityDeletedCancelsAllReminders() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, activityReminderRepository) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let eat = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 120, reminderText: "Eat")
        let packBag = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 45, reminderText: "Pack bag")

        try planning.deletePlannedActivity(activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, deletedBy: ActorId())
        coordination.handlePlannedActivityDeleted(PlannedActivityDeleted(plannedActivityId: activity.plannedActivityId, athleteId: athleteId))

        #expect(Set(scheduler.cancelledIds) == Set([eat.activityReminderId, packBag.activityReminderId]))
        #expect(try activityReminderRepository.fetchAll(forPlannedActivity: activity.plannedActivityId).isEmpty)
    }

    @Test("handleActivityLogged cancels a still-pending reminder for the linked planned activity")
    @MainActor
    func handleActivityLoggedCancelsReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, activityReminderRepository) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let reminder = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 30)

        coordination.handleActivityLogged(
            ActivityLogged(loggedActivityId: LoggedActivityId(), athleteId: athleteId, plannedActivityId: activity.plannedActivityId, durationMinutes: 45)
        )

        #expect(scheduler.cancelledIds == [reminder.activityReminderId])
        #expect(try activityReminderRepository.fetchAll(forPlannedActivity: activity.plannedActivityId).isEmpty)
    }

    /// Item 7 (multiple reminders): logging the linked activity must
    /// reconcile EVERY pending reminder, not only the first.
    @Test("handleActivityLogged cancels EVERY pending reminder for the linked activity, not only the first")
    @MainActor
    func handleActivityLoggedCancelsAllReminders() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, activityReminderRepository) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let eat = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 120, reminderText: "Eat")
        let packBag = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 45, reminderText: "Pack bag")

        coordination.handleActivityLogged(
            ActivityLogged(loggedActivityId: LoggedActivityId(), athleteId: athleteId, plannedActivityId: activity.plannedActivityId, durationMinutes: 45)
        )

        #expect(Set(scheduler.cancelledIds) == Set([eat.activityReminderId, packBag.activityReminderId]))
        #expect(try activityReminderRepository.fetchAll(forPlannedActivity: activity.plannedActivityId).isEmpty)
    }

    /// Item 8: removing the activity's start time leaves nothing to
    /// count down from for ANY reminder — every one must be cancelled.
    @Test("handlePlannedActivityChanged cancels EVERY reminder when the activity's start time is removed")
    @MainActor
    func handlePlannedActivityChangedCancelsAllRemindersWhenStartTimeRemoved() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, activityReminderRepository) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let eat = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 120, reminderText: "Eat")
        let packBag = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 45, reminderText: "Pack bag")

        _ = try planning.editPlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: nil
        )
        coordination.handlePlannedActivityChanged(
            PlannedActivityChanged(plannedActivityId: activity.plannedActivityId, athleteId: athleteId, weekPlanId: weekPlan.weekPlanId, changeType: "edited")
        )

        #expect(Set(scheduler.cancelledIds) == Set([eat.activityReminderId, packBag.activityReminderId]))
        #expect(try activityReminderRepository.fetchAll(forPlannedActivity: activity.plannedActivityId).isEmpty)
    }

    @Test("handleActivityLogged with no linked PlannedActivity is a safe no-op")
    @MainActor
    func handleActivityLoggedNoOpWhenUnlinked() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (_, coordination, scheduler, _) = makeServices(container: container)

        coordination.handleActivityLogged(
            ActivityLogged(loggedActivityId: LoggedActivityId(), athleteId: AthleteId(), plannedActivityId: nil, durationMinutes: 45)
        )

        #expect(scheduler.cancelledIds.isEmpty)
    }

    @Test("An unrelated activity's mutation does not affect another activity's own reminder")
    @MainActor
    func unrelatedActivityMutationDoesNotAffectOtherReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, activityReminderRepository) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activityA = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run A", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let activityB = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run B", localDate: LocalDate(year: 2026, month: 1, day: 7), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 8, minute: 0)
        )
        let reminderA = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activityA.plannedActivityId, leadTimeMinutes: 30)
        let reminderB = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activityB.plannedActivityId, leadTimeMinutes: 30)
        #expect(scheduler.scheduleCalls.count == 2)

        // Delete ONLY activity A.
        try planning.deletePlannedActivity(activityA.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, deletedBy: ActorId())
        coordination.handlePlannedActivityDeleted(PlannedActivityDeleted(plannedActivityId: activityA.plannedActivityId, athleteId: athleteId))

        // A's reminder is gone; B's is completely untouched.
        #expect(scheduler.cancelledIds == [reminderA.activityReminderId])
        #expect(try activityReminderRepository.fetchAll(forPlannedActivity: activityA.plannedActivityId).isEmpty)
        #expect(try activityReminderRepository.fetchAll(forPlannedActivity: activityB.plannedActivityId).first?.activityReminderId == reminderB.activityReminderId)
        #expect(scheduler.scheduleCalls.count == 2) // no new schedule call was ever made for B
    }

    // MARK: - PR #38 review follow-up: reminder identity/ownership boundary

    /// Blocker 1, required test 1: `updateReminder` used to validate
    /// only that the SUPPLIED `plannedActivityId` belongs to
    /// `athleteId`, then blindly fetch/update `activityReminderId`
    /// without ever proving THAT reminder belongs to the same activity.
    /// A caller could supply a genuine reminder id from a completely
    /// different (but same-athlete) activity, alongside an unrelated
    /// activity it does own, and retarget it. Must now be rejected
    /// before any mutation or reschedule happens.
    @Test("updateReminder rejects a reminder that belongs to a different PlannedActivity, even for the same athlete")
    @MainActor
    func updateReminderRejectsReminderFromDifferentActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, activityReminderRepository) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activityA = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run A", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let activityB = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run B", localDate: LocalDate(year: 2026, month: 1, day: 7), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 8, minute: 0)
        )
        let reminderA = try coordination.createReminder(
            athleteId: athleteId, plannedActivityId: activityA.plannedActivityId, leadTimeMinutes: 30, reminderText: "Eat"
        )

        #expect(throws: NotificationsPlanningCoordinationService.CoordinationError.reminderNotFound) {
            try coordination.updateReminder(
                activityReminderId: reminderA.activityReminderId, athleteId: athleteId, plannedActivityId: activityB.plannedActivityId,
                leadTimeMinutes: 99, reminderText: "Hijacked"
            )
        }

        let unchanged = try activityReminderRepository.fetch(byId: reminderA.activityReminderId)
        #expect(unchanged?.leadTimeMinutes == 30)
        #expect(unchanged?.reminderText == "Eat")
        #expect(scheduler.scheduleCalls.count == 1) // only the original create — no reschedule happened
    }

    /// Blocker 1, required test 2: the same boundary, across athletes —
    /// a reminder genuinely owned by one athlete must never be
    /// updatable by supplying a different athlete's own (otherwise
    /// valid) `athleteId`/`plannedActivityId`.
    @Test("updateReminder rejects a reminder that belongs to a different athlete")
    @MainActor
    func updateReminderRejectsReminderFromDifferentAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, activityReminderRepository) = makeServices(container: container)
        let ownerAthleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let ownerWeekPlan = try planning.getOrCreateWeekPlan(athleteId: ownerAthleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let ownerActivity = try planning.addPlannedActivity(
            toWeekPlan: ownerWeekPlan.weekPlanId, athleteId: ownerAthleteId, activityType: .individualTraining,
            title: "Run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let otherWeekPlan = try planning.getOrCreateWeekPlan(athleteId: otherAthleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let otherActivity = try planning.addPlannedActivity(
            toWeekPlan: otherWeekPlan.weekPlanId, athleteId: otherAthleteId, activityType: .individualTraining,
            title: "Other athlete's run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 9, minute: 0)
        )
        let ownerReminder = try coordination.createReminder(
            athleteId: ownerAthleteId, plannedActivityId: ownerActivity.plannedActivityId, leadTimeMinutes: 30, reminderText: "Eat"
        )

        #expect(throws: NotificationsPlanningCoordinationService.CoordinationError.reminderNotFound) {
            try coordination.updateReminder(
                activityReminderId: ownerReminder.activityReminderId, athleteId: otherAthleteId, plannedActivityId: otherActivity.plannedActivityId,
                leadTimeMinutes: 99, reminderText: "Hijacked"
            )
        }

        let unchanged = try activityReminderRepository.fetch(byId: ownerReminder.activityReminderId)
        #expect(unchanged?.leadTimeMinutes == 30)
        #expect(unchanged?.reminderText == "Eat")
        #expect(scheduler.scheduleCalls.count == 1)
    }

    /// Blocker 1's delete-path audit: `deleteReminder` enforces the SAME
    /// ownership boundary `updateReminder` does — never mutates anything
    /// when the supplied context doesn't genuinely own the reminder.
    @Test("deleteReminder rejects (never mutates) a reminder addressed through a mismatched PlannedActivityId")
    @MainActor
    func deleteReminderRejectsMismatchedActivityContext() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, activityReminderRepository) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activityA = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run A", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let activityB = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run B", localDate: LocalDate(year: 2026, month: 1, day: 7), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 8, minute: 0)
        )
        let reminderA = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activityA.plannedActivityId, leadTimeMinutes: 30)

        #expect(throws: NotificationsPlanningCoordinationService.CoordinationError.reminderNotFound) {
            try coordination.deleteReminder(reminderA.activityReminderId, athleteId: athleteId, plannedActivityId: activityB.plannedActivityId)
        }

        #expect(scheduler.cancelledIds.isEmpty)
        #expect(try activityReminderRepository.fetchAll(forPlannedActivity: activityA.plannedActivityId).count == 1)
    }

    /// A successful `deleteReminder`, at the coordination layer, still
    /// removes exactly the selected reminder — a sibling for the same
    /// activity, and an unrelated activity's own reminder, are both
    /// completely untouched.
    @Test("deleteReminder removes exactly the selected reminder, leaving a sibling and an unrelated activity's reminder untouched")
    @MainActor
    func deleteReminderRemovesOnlySelectedReminder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, activityReminderRepository) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let otherActivity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: LocalDate(year: 2026, month: 1, day: 7), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 8, minute: 0)
        )
        let eat = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 120, reminderText: "Eat")
        let packBag = try coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 45, reminderText: "Pack bag")
        let otherReminder = try coordination.createReminder(athleteId: athleteId, plannedActivityId: otherActivity.plannedActivityId, leadTimeMinutes: 30, reminderText: "Warm up")

        try coordination.deleteReminder(eat.activityReminderId, athleteId: athleteId, plannedActivityId: activity.plannedActivityId)

        #expect(scheduler.cancelledIds == [eat.activityReminderId])
        let remaining = try activityReminderRepository.fetchAll(forPlannedActivity: activity.plannedActivityId)
        #expect(remaining.map(\.activityReminderId) == [packBag.activityReminderId])
        #expect(try activityReminderRepository.fetchAll(forPlannedActivity: otherActivity.plannedActivityId).first?.activityReminderId == otherReminder.activityReminderId)
    }

    /// `deleteReminder` stays a safe, idempotent no-op when the id no
    /// longer exists AT ALL — deliberately distinct from the ownership-
    /// mismatch case above, which throws rather than silently no-op-ing.
    @Test("deleteReminder is a safe no-op for an ActivityReminderId that no longer exists")
    @MainActor
    func deleteReminderNoOpWhenAlreadyGone() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let (planning, coordination, scheduler, _) = makeServices(container: container)
        let athleteId = AthleteId()
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )

        try coordination.deleteReminder(ActivityReminderId(), athleteId: athleteId, plannedActivityId: activity.plannedActivityId)

        #expect(scheduler.cancelledIds.isEmpty)
    }
}

// MARK: - Deterministic notification request identity (production adapter)

@Suite("UNUserNotificationCenterActivityReminderScheduler request identity")
struct UNUserNotificationCenterActivityReminderSchedulerIdentityTests {

    @Test("The same ActivityReminderId always produces the same request identifier")
    func sameIdProducesSameIdentifier() {
        let id = ActivityReminderId()
        let first = UNUserNotificationCenterActivityReminderScheduler.requestIdentifier(for: id)
        let second = UNUserNotificationCenterActivityReminderScheduler.requestIdentifier(for: id)
        #expect(first == second)
    }

    @Test("Different ActivityReminderIds always produce different request identifiers")
    func differentIdsProduceDifferentIdentifiers() {
        let first = UNUserNotificationCenterActivityReminderScheduler.requestIdentifier(for: ActivityReminderId())
        let second = UNUserNotificationCenterActivityReminderScheduler.requestIdentifier(for: ActivityReminderId())
        #expect(first != second)
    }
}

// MARK: - ActivityReminderRepository persistence

@Suite("ActivityReminderRepository persistence", .serialized)
struct ActivityReminderRepositoryTests {

    @Test("ActivityReminder is part of the live AppSchema")
    func activityReminderIsRegisteredInAppSchema() {
        #expect(AppSchema.modelTypes.contains { ObjectIdentifier($0) == ObjectIdentifier(ActivityReminder.self) })
    }

    @Test("Insert then fetchAll by PlannedActivityId returns the same reminder")
    @MainActor
    func insertThenFetchByPlannedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let plannedActivityId = PlannedActivityId()

        let inserted = try repository.insert(athleteId: AthleteId(), plannedActivityId: plannedActivityId, leadTimeMinutes: 20)
        let fetched = try repository.fetchAll(forPlannedActivity: plannedActivityId)

        #expect(fetched.count == 1)
        #expect(fetched.first?.id == inserted.id)
        #expect(fetched.first?.leadTimeMinutes == 20)
    }

    /// Activity Reminder What/When, item 1: a concrete PlannedActivity
    /// may have MULTIPLE independent reminders — fetchAll returns every
    /// one, each retaining its own text/lead time.
    @Test("fetchAll returns every reminder for one activity, each retaining its own text and lead time")
    @MainActor
    func fetchAllReturnsEveryReminderForActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let plannedActivityId = PlannedActivityId()

        let eat = try repository.insert(athleteId: AthleteId(), plannedActivityId: plannedActivityId, leadTimeMinutes: 120, reminderText: "Eat")
        let packBag = try repository.insert(athleteId: AthleteId(), plannedActivityId: plannedActivityId, leadTimeMinutes: 45, reminderText: "Pack bag")

        let all = try repository.fetchAll(forPlannedActivity: plannedActivityId)

        #expect(all.count == 2)
        #expect(all.contains { $0.id == eat.id && $0.leadTimeMinutes == 120 && $0.reminderText == "Eat" })
        #expect(all.contains { $0.id == packBag.id && $0.leadTimeMinutes == 45 && $0.reminderText == "Pack bag" })
    }

    @Test("Deleting a reminder leaves no row behind")
    @MainActor
    func deleteRemovesRow() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let plannedActivityId = PlannedActivityId()
        let inserted = try repository.insert(athleteId: AthleteId(), plannedActivityId: plannedActivityId, leadTimeMinutes: 20)

        try repository.delete(inserted)

        #expect(try repository.fetchAll(forPlannedActivity: plannedActivityId).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReminder>()).isEmpty)
    }

    // MARK: - Recent-text suggestions (items 19-21)

    /// Item 19: prior user-authored reminder texts are returned as
    /// distinct, most-recently-used suggestions.
    @Test("Recent reminder texts are returned distinct, most-recently-used first")
    @MainActor
    func recentReminderTextsReturnsDistinctMostRecentFirst() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try repository.insert(athleteId: athleteId, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 120, reminderText: "Eat", createdAt: base)
        _ = try repository.insert(athleteId: athleteId, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 45, reminderText: "Pack bag", createdAt: base.addingTimeInterval(60))
        _ = try repository.insert(athleteId: athleteId, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 60, reminderText: "Drink water", createdAt: base.addingTimeInterval(120))

        let suggestions = try repository.fetchRecentDistinctReminderTexts(forAthlete: athleteId, limit: 5)

        // Explicit, distinct createdAt timestamps (never real wall-clock
        // ordering) drive the recency order — most recent first.
        #expect(suggestions == ["Drink water", "Pack bag", "Eat"])
    }

    /// Item 20: reusing the exact same text does not create a duplicate
    /// suggestion entry — it moves to the front (most recent) instead.
    @Test("Reusing the same reminder text does not create a duplicate suggestion entry")
    @MainActor
    func recentReminderTextsDeduplicatesReusedText() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try repository.insert(athleteId: athleteId, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 120, reminderText: "Eat", createdAt: base)
        _ = try repository.insert(athleteId: athleteId, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 45, reminderText: "Pack bag", createdAt: base.addingTimeInterval(60))
        _ = try repository.insert(athleteId: athleteId, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 90, reminderText: "Eat", createdAt: base.addingTimeInterval(120))

        let suggestions = try repository.fetchRecentDistinctReminderTexts(forAthlete: athleteId, limit: 5)

        #expect(suggestions.count == 2)
        #expect(suggestions == ["Eat", "Pack bag"])
    }

    /// Item 21: privacy/athlete scope matches this repository's own
    /// existing per-athlete isolation — a reminder text authored for
    /// one athlete is never suggested when composing a reminder for a
    /// DIFFERENT athlete, even within the same family/workspace.
    @Test("Recent reminder text suggestions never leak between athletes")
    @MainActor
    func recentReminderTextsAreScopedPerAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let athleteA = AthleteId()
        let athleteB = AthleteId()

        _ = try repository.insert(athleteId: athleteA, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 120, reminderText: "Eat")
        _ = try repository.insert(athleteId: athleteB, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 45, reminderText: "Pack bag")

        let suggestionsForA = try repository.fetchRecentDistinctReminderTexts(forAthlete: athleteA, limit: 5)
        let suggestionsForB = try repository.fetchRecentDistinctReminderTexts(forAthlete: athleteB, limit: 5)

        #expect(suggestionsForA == ["Eat"])
        #expect(suggestionsForB == ["Pack bag"])
    }

    /// Bounded limit — never shows more than the requested small,
    /// UI-appropriate count, even with many distinct texts available.
    @Test("Recent reminder text suggestions are bounded to the requested limit")
    @MainActor
    func recentReminderTextsRespectsLimit() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()

        for text in ["Eat", "Pack bag", "Drink water", "Bring jersey", "Warm up"] {
            _ = try repository.insert(athleteId: athleteId, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 30, reminderText: text)
        }

        let suggestions = try repository.fetchRecentDistinctReminderTexts(forAthlete: athleteId, limit: 3)

        #expect(suggestions.count == 3)
    }

    /// PR #38 review follow-up (recent-text note): "most recently used"
    /// must reflect an EDIT to an already-existing reminder, not only
    /// original insertion order — editing "Eat" (created FIRST) after
    /// "Pack bag" (created SECOND) must move "Eat" back in front, since
    /// that edit is itself a fresh use of that text. Chosen semantics:
    /// recency is keyed on `ActivityReminder.updatedAt` (bumped by both
    /// `insert`, which sets it equal to `createdAt`, and `update`, on
    /// every edit) — no new scoring or history model, reusing the one
    /// canonical timestamp the model already maintains for exactly this
    /// meaning.
    @Test("Editing an already-existing reminder's text counts as a fresh use for recency, even if it was created earlier")
    @MainActor
    func recentReminderTextsReflectEditsNotJustCreationOrder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let athleteId = AthleteId()

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let eat = try repository.insert(athleteId: athleteId, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 120, reminderText: "Eat", createdAt: base)
        _ = try repository.insert(athleteId: athleteId, plannedActivityId: PlannedActivityId(), leadTimeMinutes: 45, reminderText: "Pack bag", createdAt: base.addingTimeInterval(60))

        // Creation order alone would put "Pack bag" first — confirm that
        // baseline before the edit below changes it.
        #expect(try repository.fetchRecentDistinctReminderTexts(forAthlete: athleteId, limit: 5) == ["Pack bag", "Eat"])

        // Editing "Eat" (unrelated field, same text) at a LATER instant
        // than "Pack bag" was ever touched is itself a fresh "use."
        _ = try repository.update(eat, leadTimeMinutes: 90, reminderText: "Eat", updatedAt: base.addingTimeInterval(120))

        let suggestions = try repository.fetchRecentDistinctReminderTexts(forAthlete: athleteId, limit: 5)
        #expect(suggestions == ["Eat", "Pack bag"])
    }
}

// MARK: - Production pipeline determinism (PR #36 follow-up)

/// PR #36 follow-up — the correctness property the review flagged: with
/// two independent unstructured `Task` hops (service -> EventBus,
/// EventBus handler -> MainActor reaction), a rapid sequence of
/// mutations (edit-then-delete, edit-then-log, repeated edits) had no
/// guaranteed final ordering. `EventBus.publish` is now `@MainActor` and
/// dispatches synchronously; `PlanningService`/`TrainingService` call it
/// directly (no `Task`); `NotificationsPlanningCoordinationService`'s
/// subscription closures call their own `@MainActor` handlers directly
/// (no `Task`) — see each of those types' own doc comments.
///
/// These tests deliberately go through the REAL `EventBus` publish/
/// subscribe path — `coordination.subscribeToEvents(eventBus)`, the
/// exact call `CompositionRoot.build()` makes in production — and the
/// REAL `PlanningService`/`TrainingService` mutation methods, never
/// `handlePlannedActivityChanged`/`handlePlannedActivityDeleted`/
/// `handleActivityLogged` directly. The existing direct-handler unit
/// tests above remain, covering decision logic in isolation; these cover
/// the production wiring itself.
@Suite("Notifications V1 production event pipeline determinism (PR #36 follow-up)", .serialized)
struct NotificationsProductionEventPipelineTests {

    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    private struct Fixture {
        let planningService: PlanningService
        let trainingService: TrainingService
        let coordination: NotificationsPlanningCoordinationService
        let scheduler: FakeActivityReminderScheduler
        let activityReminderRepository: ActivityReminderRepository
    }

    @MainActor
    private func makeFixture(container: ModelContainer) -> Fixture {
        let eventBus = EventBus()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository, eventBus: eventBus)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository, eventBus: eventBus)
        let activityReminderRepository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let activityReminderService = ActivityReminderService(repository: activityReminderRepository, scheduler: scheduler)
        let coordination = NotificationsPlanningCoordinationService(
            activityReminderService: activityReminderService,
            planningService: planningService,
            dateProvider: FixedDateProvider(now: notificationsLifecycleTestsFixedNow())
        )
        // The real production wiring call — CompositionRoot.build() makes
        // this exact call, against this exact eventBus instance.
        coordination.subscribeToEvents(eventBus)
        return Fixture(
            planningService: planningService, trainingService: trainingService, coordination: coordination,
            scheduler: scheduler, activityReminderRepository: activityReminderRepository
        )
    }

    @Test("Rapid edit -> delete converges, through the real EventBus, to no persisted reminder and no pending scheduler entry")
    @MainActor
    func rapidEditThenDeleteConverges() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let reminder = try fixture.coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 30)
        #expect(fixture.scheduler.isPending(reminder.activityReminderId))

        // 1. Edit the planned activity's date/time.
        _ = try fixture.planningService.editPlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 8), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 7, minute: 0)
        )
        // 2. Immediately delete it — both mutations publish through the
        // same real EventBus; nothing here awaits, sleeps, or calls a
        // handler method directly.
        try fixture.planningService.deletePlannedActivity(activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, deletedBy: ActorId())
        // 3. "Allow the production lifecycle to complete": nothing to
        // wait for — publish/subscribe/react is synchronous end to end,
        // so both mutation calls above have already returned only once
        // their own event was fully processed.

        #expect(try fixture.activityReminderRepository.fetchAll(forPlannedActivity: activity.plannedActivityId).isEmpty)
        #expect(fixture.scheduler.isPending(reminder.activityReminderId) == false)
        #expect(fixture.scheduler.cancelledIds.last == reminder.activityReminderId)
    }

    @Test("Rapid edit -> completion (log) converges, through the real EventBus, to no active reminder intent and no pending scheduler entry")
    @MainActor
    func rapidEditThenCompletionConverges() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let reminder = try fixture.coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 30)

        // 1. Edit the planned activity.
        _ = try fixture.planningService.editPlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 19, minute: 0)
        )
        // 2. Immediately log the linked activity as completed — through
        // the real TrainingService, publishing ActivityLogged through the
        // same real EventBus.
        _ = try fixture.trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
            title: "Endurance run", startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            durationMinutes: 45, status: .completed, source: "manual",
            loggedByActorId: ActorId()
        )

        #expect(try fixture.activityReminderRepository.fetchAll(forPlannedActivity: activity.plannedActivityId).isEmpty)
        #expect(fixture.scheduler.isPending(reminder.activityReminderId) == false)
        #expect(fixture.scheduler.cancelledIds.last == reminder.activityReminderId)
    }

    @Test("Multiple rapid edits converge, through the real EventBus, to the LATEST canonical PlannedActivity — never an intermediate mutation")
    @MainActor
    func multipleRapidEditsConvergeToLatestState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let reminder = try fixture.coordination.createReminder(athleteId: athleteId, plannedActivityId: activity.plannedActivityId, leadTimeMinutes: 30)
        let scheduleCallsAfterCreate = fixture.scheduler.scheduleCalls.count

        // Three rapid, sequential date/time changes — an intermediate
        // mutation's own fire instant must never be what's left scheduled.
        _ = try fixture.planningService.editPlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 7), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 9, minute: 0)
        )
        _ = try fixture.planningService.editPlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 8), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 10, minute: 0)
        )
        _ = try fixture.planningService.editPlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 9), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 11, minute: 0)
        )

        let expectedFinalFireInstant = try LocalDate(year: 2026, month: 1, day: 9).absoluteDate(at: LocalTime(hour: 11, minute: 0), in: Self.oslo)
        let expectedFinalFireDate = expectedFinalFireInstant.addingTimeInterval(-30 * 60)

        // Exactly one reschedule call per edit — three edits, three new
        // schedule calls beyond the initial create — proving nothing was
        // coalesced/dropped/reordered.
        #expect(fixture.scheduler.scheduleCalls.count == scheduleCallsAfterCreate + 3)
        #expect(fixture.scheduler.scheduleCalls.last?.id == reminder.activityReminderId)
        #expect(fixture.scheduler.scheduleCalls.last?.fireDate == expectedFinalFireDate)
        // The still-persisted reminder's own next fire instant (were it
        // fetched again right now) also reflects the latest state, not
        // some earlier value baked in at creation.
        #expect(try fixture.activityReminderRepository.fetchAll(forPlannedActivity: activity.plannedActivityId).first?.activityReminderId == reminder.activityReminderId)
    }
}
