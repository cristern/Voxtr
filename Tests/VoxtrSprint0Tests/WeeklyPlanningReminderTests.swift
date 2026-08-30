import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrNotificationsDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Activity Reminder What/When (CREATE flow): covers the "Create Planned
// Activity -> date/start time -> optional Reminders -> add reminder(s):
// What + When -> Save -> canonical PlannedActivity is created -> reminder
// intents are persisted/scheduled against its stable PlannedActivityId"
// journey. Domain/service-level multi-reminder coverage lives in
// ActivityReminderLifecycleTests.swift; the EDIT flow's ViewModel-level
// coverage lives in ActivityDetailReminderUITests.swift. This file is
// specifically the CREATE flow's own draft-until-Save staging behavior.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/service construction — every test builds its own inline.

/// A recording, deterministic, configurable test double for
/// `ActivityReminderScheduling` — never `UNUserNotificationCenter`.
/// File-local, per this project's "every test file builds its own
/// inline" convention.
private final class FakeActivityReminderScheduler: ActivityReminderScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _scheduleCallCount = 0
    private var _authorizationStatus: ActivityReminderAuthorizationStatus = .authorized

    var scheduleCallCount: Int { lock.lock(); defer { lock.unlock() }; return _scheduleCallCount }

    var authorizationStatusValue: ActivityReminderAuthorizationStatus {
        get { lock.lock(); defer { lock.unlock() }; return _authorizationStatus }
        set { lock.lock(); defer { lock.unlock() }; _authorizationStatus = newValue }
    }

    func scheduleReminder(id: ActivityReminderId, fireDate: Date, content: ActivityReminderContent) {
        lock.lock(); defer { lock.unlock() }
        _scheduleCallCount += 1
    }

    func cancelReminder(id: ActivityReminderId) {}

    func authorizationStatus(completion: @escaping @MainActor @Sendable (ActivityReminderAuthorizationStatus) -> Void) {
        let status = authorizationStatusValue
        MainActor.assumeIsolated { completion(status) }
    }

    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        MainActor.assumeIsolated { completion(true) }
    }
}

private struct FixedDateProvider: DateProvider {
    let now: Date
}

private func weeklyPlanningReminderTestsFixedNow() -> Date {
    var components = DateComponents()
    components.year = 2025
    components.month = 12
    components.day = 1
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 1_764_547_200)
}

@Suite("WeeklyPlanningViewModel Reminders (Activity Reminder What/When, create flow)", .serialized)
struct WeeklyPlanningReminderTests {

    private static let fixedWeekStart = LocalDate(year: 2026, month: 1, day: 5)

    @MainActor
    private func makeFixture(container: ModelContainer) -> (
        planningService: PlanningService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        scheduler: FakeActivityReminderScheduler
    ) {
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let scheduler = FakeActivityReminderScheduler()
        let activityReminderService = ActivityReminderService(
            repository: ActivityReminderRepository(modelContext: container.mainContext),
            scheduler: scheduler
        )
        let notificationsPlanningCoordinationService = NotificationsPlanningCoordinationService(
            activityReminderService: activityReminderService,
            planningService: planningService,
            dateProvider: FixedDateProvider(now: weeklyPlanningReminderTestsFixedNow())
        )
        return (planningService, notificationsPlanningCoordinationService, scheduler)
    }

    @MainActor
    private func makeViewModel(
        fixture: (planningService: PlanningService, notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService, scheduler: FakeActivityReminderScheduler),
        athleteId: AthleteId
    ) -> WeeklyPlanningViewModel {
        WeeklyPlanningViewModel(
            service: fixture.planningService,
            notificationsPlanningCoordinationService: fixture.notificationsPlanningCoordinationService,
            athleteId: athleteId,
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
    }

    /// Item 9: a new activity's own draft reminders start empty.
    @Test("A new activity defaults to no draft reminders")
    @MainActor
    func newActivityDefaultsToNoReminders() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let viewModel = makeViewModel(fixture: fixture, athleteId: AthleteId())

        #expect(viewModel.newActivityReminders.isEmpty)
    }

    /// Item 10: reminder controls are unavailable while the draft has
    /// no start time.
    @Test("Reminder controls are unavailable while the draft activity has no start time")
    @MainActor
    func reminderUnavailableWithoutStartTime() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let viewModel = makeViewModel(fixture: fixture, athleteId: AthleteId())

        #expect(viewModel.newActivityHasStartTime == false)
        #expect(viewModel.isNewActivityReminderAvailable == false)

        viewModel.newActivityHasStartTime = true
        #expect(viewModel.isNewActivityReminderAvailable == true)
    }

    /// Item 11: staging draft reminders (What + When) before Save is
    /// purely local — nothing is scheduled/persisted against any
    /// PlannedActivityId yet, since none exists.
    @Test("Draft reminders store only local What + When state before the activity is saved — nothing is scheduled yet")
    @MainActor
    func draftRemindersAreLocalOnlyBeforeSave() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let viewModel = makeViewModel(fixture: fixture, athleteId: AthleteId())

        viewModel.newActivityHasStartTime = true
        viewModel.addNewActivityReminderDraft()
        #expect(viewModel.newActivityReminders.count == 1)
        viewModel.newActivityReminders[0].text = "Pack bag"
        viewModel.newActivityReminders[0].leadTimeMinutes = 45

        #expect(viewModel.newActivityReminders.first?.text == "Pack bag")
        #expect(viewModel.newActivityReminders.first?.leadTimeMinutes == 45)
        #expect(viewModel.newActivityReminders.first?.persistedId == nil)
        #expect(fixture.scheduler.scheduleCallCount == 0)
    }

    /// Items 12-13: Save creates the canonical PlannedActivity FIRST;
    /// staged reminders are then persisted/scheduled using its real,
    /// stable PlannedActivityId — never a temporary/draft identity.
    @Test("Save creates the canonical PlannedActivity first, then persists staged reminders against its real PlannedActivityId")
    @MainActor
    func saveCreatesActivityFirstThenPersistsReminders() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId)
        viewModel.loadOrCreateWeekPlan()

        viewModel.newActivityTitle = "Hockey practice"
        viewModel.newActivityHasStartTime = true
        viewModel.newActivityStartTime = Calendar.current.date(from: DateComponents(hour: 18, minute: 0)) ?? .now
        viewModel.addNewActivityReminderDraft()
        viewModel.newActivityReminders[0].text = "Eat"
        viewModel.newActivityReminders[0].leadTimeMinutes = 120

        viewModel.addActivity()

        #expect(viewModel.errorMessage == nil)
        let created = try #require(viewModel.activities.first { $0.title == "Hockey practice" })
        let persistedReminders = try fixture.notificationsPlanningCoordinationService.fetchReminders(forPlannedActivity: created.plannedActivityId)
        #expect(persistedReminders.count == 1)
        #expect(persistedReminders.first?.reminderText == "Eat")
        #expect(persistedReminders.first?.leadTimeMinutes == 120)
        #expect(fixture.scheduler.scheduleCallCount == 1)
        // The create form's own draft state is reset after a successful save.
        #expect(viewModel.newActivityReminders.isEmpty)
    }

    /// Item 14: if activity creation itself fails, no reminder is ever
    /// attempted — the draft reminder is simply left staged, never
    /// scheduled against nothing.
    @Test("Failed activity creation creates no reminders")
    @MainActor
    func failedActivityCreationCreatesNoReminders() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId)
        viewModel.loadOrCreateWeekPlan()

        // Neither a title nor a sportId is set — PlanningService rejects
        // this as "title or sportId is required."
        viewModel.newActivityTitle = ""
        viewModel.newActivitySportId = nil
        viewModel.newActivityHasStartTime = true
        viewModel.addNewActivityReminderDraft()
        viewModel.newActivityReminders[0].text = "Eat"

        viewModel.addActivity()

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.activities.isEmpty)
        #expect(fixture.scheduler.scheduleCallCount == 0)
        // The staged draft is preserved (never silently cleared) since
        // nothing was actually saved.
        #expect(viewModel.newActivityReminders.count == 1)
    }

    /// Item 15: a staged reminder that cannot be enabled (permission
    /// denied) must never invalidate the already-successfully-created
    /// PlannedActivity.
    @Test("Permission denied on a staged reminder does not invalidate the successfully-created activity")
    @MainActor
    func permissionDeniedDoesNotInvalidateSuccessfulActivityCreation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        fixture.scheduler.authorizationStatusValue = .denied
        let athleteId = AthleteId()
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId)
        viewModel.loadOrCreateWeekPlan()

        viewModel.newActivityTitle = "Hockey practice"
        viewModel.newActivityHasStartTime = true
        viewModel.newActivityStartTime = Calendar.current.date(from: DateComponents(hour: 18, minute: 0)) ?? .now
        viewModel.addNewActivityReminderDraft()
        viewModel.newActivityReminders[0].text = "Eat"

        viewModel.addActivity()

        #expect(viewModel.errorMessage == nil)
        let created = try #require(viewModel.activities.first { $0.title == "Hockey practice" })
        #expect(created.title == "Hockey practice")
        // The reminder itself was declined — never persisted/scheduled —
        // but that never rolls back or invalidates the activity above.
        let persistedReminders = try fixture.notificationsPlanningCoordinationService.fetchReminders(forPlannedActivity: created.plannedActivityId)
        #expect(persistedReminders.isEmpty)
        #expect(fixture.scheduler.scheduleCallCount == 0)
    }
}
