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

    var scheduleCalls: [ScheduleCall] {
        lock.lock(); defer { lock.unlock() }
        return _scheduleCalls
    }

    var cancelledIds: [ActivityReminderId] {
        lock.lock(); defer { lock.unlock() }
        return _cancelledIds
    }

    func scheduleReminder(id: ActivityReminderId, fireDate: Date, content: ActivityReminderContent) {
        lock.lock(); defer { lock.unlock() }
        _scheduleCalls.append(ScheduleCall(id: id, fireDate: fireDate, content: content))
    }

    func cancelReminder(id: ActivityReminderId) {
        lock.lock(); defer { lock.unlock() }
        _cancelledIds.append(id)
    }

    func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) {
        completion(true)
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

    @Test("Creating a second reminder for the same activity replaces the first rather than duplicating it")
    @MainActor
    func createReminderReplacesExistingOne() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let service = ActivityReminderService(repository: repository, scheduler: scheduler)
        let athleteId = AthleteId()
        let plannedActivityId = PlannedActivityId()

        let first = try service.createReminder(
            athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: 30,
            fireDate: Date(timeIntervalSince1970: 1_800_000_000),
            content: ActivityReminderContent(title: "A", body: "A")
        )
        let second = try service.createReminder(
            athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: 15,
            fireDate: Date(timeIntervalSince1970: 1_800_100_000),
            content: ActivityReminderContent(title: "B", body: "B")
        )

        #expect(first.activityReminderId != second.activityReminderId)
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReminder>()).count == 1)
        #expect(try repository.fetch(forPlannedActivity: plannedActivityId)?.leadTimeMinutes == 15)
        #expect(scheduler.cancelledIds == [first.activityReminderId])
        #expect(scheduler.scheduleCalls.map(\.id) == [first.activityReminderId, second.activityReminderId])
    }

    @Test("Cancelling a reminder removes its intent row and cancels the scheduled notification")
    @MainActor
    func cancelReminderRemovesAndCancels() throws {
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

        try service.cancelReminder(forPlannedActivity: plannedActivityId)

        #expect(try repository.fetch(forPlannedActivity: plannedActivityId) == nil)
        #expect(scheduler.cancelledIds == [reminder.activityReminderId])
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReminder>()).count == 0)
    }

    @Test("Cancelling when no reminder is active is a safe no-op")
    @MainActor
    func cancelReminderNoOpWhenNoneActive() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let service = ActivityReminderService(repository: repository, scheduler: scheduler)

        try service.cancelReminder(forPlannedActivity: PlannedActivityId())

        #expect(scheduler.cancelledIds.isEmpty)
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
        try service.rescheduleReminder(forPlannedActivity: plannedActivityId, fireDate: newFireDate, content: newContent)

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

    @Test("Rescheduling when no reminder exists is a safe no-op — never creates one")
    @MainActor
    func rescheduleReminderNoOpWhenNoneActive() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let scheduler = FakeActivityReminderScheduler()
        let service = ActivityReminderService(repository: repository, scheduler: scheduler)

        try service.rescheduleReminder(
            forPlannedActivity: PlannedActivityId(),
            fireDate: Date(timeIntervalSince1970: 1_800_000_000),
            content: ActivityReminderContent(title: "A", body: "A")
        )

        #expect(scheduler.scheduleCalls.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReminder>()).count == 0)
    }
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
            planningService: planningService
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
        #expect(try activityReminderRepository.fetch(forPlannedActivity: activity.plannedActivityId) == nil)
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
        #expect(try activityReminderRepository.fetch(forPlannedActivity: activity.plannedActivityId) == nil)
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
        #expect(try activityReminderRepository.fetch(forPlannedActivity: activityA.plannedActivityId) == nil)
        #expect(try activityReminderRepository.fetch(forPlannedActivity: activityB.plannedActivityId)?.activityReminderId == reminderB.activityReminderId)
        #expect(scheduler.scheduleCalls.count == 2) // no new schedule call was ever made for B
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

    @Test("Insert then fetch by PlannedActivityId returns the same reminder")
    @MainActor
    func insertThenFetchByPlannedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ActivityReminderRepository(modelContext: container.mainContext)
        let plannedActivityId = PlannedActivityId()

        let inserted = try repository.insert(athleteId: AthleteId(), plannedActivityId: plannedActivityId, leadTimeMinutes: 20)
        let fetched = try repository.fetch(forPlannedActivity: plannedActivityId)

        #expect(fetched?.id == inserted.id)
        #expect(fetched?.leadTimeMinutes == 20)
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

        #expect(try repository.fetch(forPlannedActivity: plannedActivityId) == nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReminder>()).isEmpty)
    }
}
