import Testing
import Foundation
import SwiftData
@testable import VoxtrAppShell
import VoxtrCore
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrNotificationsDomain

// NOTE: like the other persistence-backed tests in this suite, the
// `ActivityDetailViewModel` cases here require the Xcode/macOS SwiftData
// runtime — written but not executed in this sandbox.
//
// Planned Activity Time Range Presentation: proves Family Home's
// `rowSubtitle`/`recurringRowSubtitle` and `ActivityDetailViewModel`'s
// `plannedTimeRangeLabel`/`plannedDurationLabel` actually consume
// `PlannedTimeRangeFormatter` correctly, rather than each reimplementing
// the contract independently. `PlannedTimeRangeFormatterTests` already
// covers the formatter's own arithmetic exhaustively — these tests only
// prove each surface wires it in correctly.

private struct NoopActivityReminderScheduler: ActivityReminderScheduling {
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

@Suite("Family Home / Activity Detail consume PlannedTimeRangeFormatter")
struct PlannedTimeRangeFormatterConsumerTests {

    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    // MARK: - FamilyHomeContentView (pure — no persistence needed)

    @Test("Family Home planned row shows a time range when start + planned duration exist")
    func familyHomeRowSubtitleShowsRangeWhenBothKnown() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: AthleteId(), activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 3, day: 3),
            startLocalTime: LocalTime(hour: 18, minute: 0), timeZoneId: Self.oslo, plannedDurationMinutes: 90
        )
        let row = FamilyHomeRow(id: "row-1", athleteId: AthleteId(), athleteName: "Oliver", plannedActivity: activity, isCompleted: false)
        #expect(FamilyHomeContentView.rowSubtitle(for: row).hasPrefix("18:00–19:30"))
    }

    @Test("Family Home planned row shows start time alone when no planned duration exists")
    func familyHomeRowSubtitleShowsStartAloneWhenNoDuration() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: AthleteId(), activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 3, day: 3),
            startLocalTime: LocalTime(hour: 18, minute: 0), timeZoneId: Self.oslo
        )
        let row = FamilyHomeRow(id: "row-2", athleteId: AthleteId(), athleteName: "Oliver", plannedActivity: activity, isCompleted: false)
        #expect(FamilyHomeContentView.rowSubtitle(for: row).hasPrefix("18:00"))
        #expect(!FamilyHomeContentView.rowSubtitle(for: row).contains("–"))
    }

    @Test("Family Home planned row with no start time still reads 'Ready to log', never a fabricated time")
    func familyHomeRowSubtitleFallsBackWhenNoStartTime() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: AthleteId(), activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: Self.oslo, plannedDurationMinutes: 90
        )
        let row = FamilyHomeRow(id: "row-3", athleteId: AthleteId(), athleteName: "Oliver", plannedActivity: activity, isCompleted: false)
        #expect(FamilyHomeContentView.rowSubtitle(for: row) == "Ready to log")
    }

    /// PR #57 follow-up: a `LoggedActivity` with the given outcome
    /// `status` — `durationMinutes` deliberately differs from the
    /// planned duration used in these tests (90) so a test can prove
    /// the logged value is never substituted for the planned one.
    private func loggedActivity(status: ActivityStatus, durationMinutes: Int = 45) -> LoggedActivity {
        LoggedActivity(
            athleteId: AthleteId(), activityType: .individualTraining, title: "Hockey practice",
            startedAt: .now, durationMinutes: durationMinutes, status: status, source: "manual"
        )
    }

    @Test("Family Home planned row retains the planned time range once completed")
    func familyHomeRowSubtitleRetainsRangeWhenCompleted() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: AthleteId(), activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 3, day: 3),
            startLocalTime: LocalTime(hour: 18, minute: 0), timeZoneId: Self.oslo, plannedDurationMinutes: 90
        )
        let row = FamilyHomeRow(
            id: "row-completed", athleteId: AthleteId(), athleteName: "Oliver", plannedActivity: activity,
            isCompleted: true, loggedActivity: loggedActivity(status: .completed)
        )
        #expect(FamilyHomeContentView.rowSubtitle(for: row).contains("18:00–19:30"))
    }

    @Test("Family Home planned row retains the planned time range when partially completed")
    func familyHomeRowSubtitleRetainsRangeWhenPartiallyCompleted() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: AthleteId(), activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 3, day: 3),
            startLocalTime: LocalTime(hour: 18, minute: 0), timeZoneId: Self.oslo, plannedDurationMinutes: 90
        )
        let row = FamilyHomeRow(
            id: "row-partial", athleteId: AthleteId(), athleteName: "Oliver", plannedActivity: activity,
            isCompleted: true, loggedActivity: loggedActivity(status: .partiallyCompleted)
        )
        #expect(FamilyHomeContentView.rowSubtitle(for: row).contains("18:00–19:30"))
    }

    @Test("Family Home planned row retains the planned time range when missed")
    func familyHomeRowSubtitleRetainsRangeWhenMissed() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: AthleteId(), activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 3, day: 3),
            startLocalTime: LocalTime(hour: 18, minute: 0), timeZoneId: Self.oslo, plannedDurationMinutes: 90
        )
        let row = FamilyHomeRow(
            id: "row-missed", athleteId: AthleteId(), athleteName: "Oliver", plannedActivity: activity,
            isCompleted: true, loggedActivity: loggedActivity(status: .missed)
        )
        #expect(FamilyHomeContentView.rowSubtitle(for: row).contains("18:00–19:30"))
    }

    @Test("Family Home planned row retains the planned time range when cancelled")
    func familyHomeRowSubtitleRetainsRangeWhenCancelled() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: AthleteId(), activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 3, day: 3),
            startLocalTime: LocalTime(hour: 18, minute: 0), timeZoneId: Self.oslo, plannedDurationMinutes: 90
        )
        let row = FamilyHomeRow(
            id: "row-cancelled", athleteId: AthleteId(), athleteName: "Oliver", plannedActivity: activity,
            isCompleted: true, loggedActivity: loggedActivity(status: .cancelled)
        )
        #expect(FamilyHomeContentView.rowSubtitle(for: row).contains("18:00–19:30"))
    }

    @Test("The same planned time range renders identically regardless of outcome status — outcome never feeds the range computation")
    func familyHomeRowSubtitlePlannedRangeIsIndependentOfOutcome() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: AthleteId(), activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 3, day: 3),
            startLocalTime: LocalTime(hour: 18, minute: 0), timeZoneId: Self.oslo, plannedDurationMinutes: 90
        )
        let statuses: [ActivityStatus] = [.completed, .partiallyCompleted, .missed, .cancelled]
        let labels = statuses.map { status -> String in
            let row = FamilyHomeRow(
                id: "row-\(status)", athleteId: AthleteId(), athleteName: "Oliver", plannedActivity: activity,
                isCompleted: true, loggedActivity: loggedActivity(status: status)
            )
            return FamilyHomeContentView.rowSubtitle(for: row)
        }
        #expect(labels.allSatisfy { $0.contains("18:00–19:30") })
    }

    @Test("The planned range is built from PlannedActivity's own duration, never LoggedActivity.durationMinutes")
    func familyHomeRowSubtitleNeverUsesLoggedDuration() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: AthleteId(), activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 3, day: 3),
            startLocalTime: LocalTime(hour: 18, minute: 0), timeZoneId: Self.oslo, plannedDurationMinutes: 90
        )
        // Logged duration (45) deliberately differs from planned (90) —
        // the rendered range must reflect the PLANNED interval only.
        let row = FamilyHomeRow(
            id: "row-logged-mismatch", athleteId: AthleteId(), athleteName: "Oliver", plannedActivity: activity,
            isCompleted: true, loggedActivity: loggedActivity(status: .completed, durationMinutes: 45)
        )
        let subtitle = FamilyHomeContentView.rowSubtitle(for: row)
        #expect(subtitle.contains("18:00–19:30"))
        #expect(!subtitle.contains("18:00–18:45"))
    }

    @Test("Family Home recurring-occurrence row shows a time range when start + planned duration exist")
    func familyHomeRecurringRowSubtitleShowsRange() {
        let suggestion = RecurringActivitySuggestion(
            id: "suggestion-1", recurringPlannedActivityId: RecurringPlannedActivityId(), athleteId: AthleteId(),
            occurrenceDate: LocalDate(year: 2026, month: 3, day: 3), title: "Hockey practice",
            activityType: .individualTraining, sportId: nil, categoryIds: [],
            startLocalTime: LocalTime(hour: 18, minute: 0), plannedDurationMinutes: 90, timeZoneId: Self.oslo
        )
        let subtitle = FamilyHomeContentView.recurringRowSubtitle(for: suggestion)
        #expect(subtitle.contains("18:00–19:30"))
        #expect(subtitle.hasSuffix("Recurring"))
    }

    // MARK: - ActivityDetailViewModel

    @MainActor
    private func makeViewModel(startLocalTime: LocalTime?, plannedDurationMinutes: Int?) throws -> ActivityDetailViewModel {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let eventBus = EventBus()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext), eventBus: eventBus)
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext), eventBus: eventBus),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let activityReminderService = ActivityReminderService(
            repository: ActivityReminderRepository(modelContext: container.mainContext),
            scheduler: NoopActivityReminderScheduler()
        )
        let notificationsPlanningCoordinationService = NotificationsPlanningCoordinationService(
            activityReminderService: activityReminderService,
            planningService: planningService,
            dateProvider: FixedDateProvider(now: Date(timeIntervalSince1970: 1_764_547_200))
        )

        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Hockey practice", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: startLocalTime, plannedDurationMinutes: plannedDurationMinutes
        )

        return ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: trainingReflectionCoordinationService,
            notificationsPlanningCoordinationService: notificationsPlanningCoordinationService
        )
    }

    @Test("Activity Detail shows a time range and an explicit planned Duration when both are known")
    @MainActor
    func activityDetailShowsRangeAndExplicitDuration() throws {
        let viewModel = try makeViewModel(startLocalTime: LocalTime(hour: 18, minute: 0), plannedDurationMinutes: 90)
        #expect(viewModel.plannedTimeRangeLabel == "18:00–19:30")
        #expect(viewModel.plannedDurationLabel == "90 min")
    }

    @Test("Activity Detail shows the start time alone when no planned duration exists")
    @MainActor
    func activityDetailShowsStartAloneWhenNoDuration() throws {
        let viewModel = try makeViewModel(startLocalTime: LocalTime(hour: 18, minute: 0), plannedDurationMinutes: nil)
        #expect(viewModel.plannedTimeRangeLabel == "18:00")
        #expect(viewModel.plannedDurationLabel == nil)
    }

    @Test("Activity Detail never derives a time range when there is no start time, even with a known duration")
    @MainActor
    func activityDetailNeverInventsRangeWithNoStartTime() throws {
        let viewModel = try makeViewModel(startLocalTime: nil, plannedDurationMinutes: 90)
        #expect(viewModel.plannedTimeRangeLabel == nil)
        #expect(viewModel.plannedDurationLabel == "90 min")
    }
}
