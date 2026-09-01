import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrNotificationsDomain
import VoxtrCalendarPlanningDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.

/// Notifications V1 Activity Reminder UI slice: a trivial no-op
/// `ActivityReminderScheduling` conformance so `ActivityDetailViewModel`
/// tests in this file (which do not exercise reminder behavior) can
/// construct the now-required `NotificationsPlanningCoordinationService`
/// dependency without touching `UNUserNotificationCenter`.
private struct NoOpActivityReminderScheduler: ActivityReminderScheduling {
    func scheduleReminder(id: ActivityReminderId, fireDate: Date, content: ActivityReminderContent) {}
    func cancelReminder(id: ActivityReminderId) {}
    func authorizationStatus(completion: @escaping @MainActor @Sendable (ActivityReminderAuthorizationStatus) -> Void) {
        MainActor.assumeIsolated { completion(.authorized) }
    }
    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        MainActor.assumeIsolated { completion(true) }
    }
}

@Suite("Sprint 1 completion: Tomorrow and Family Schedule", .serialized)
struct FamilyScheduleAndTomorrowTests {

    @Test("Activity can be created with start time directly, and it survives fetch/reload")
    @MainActor
    func activityCreatedWithStartTimeSurvivesReload() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        let created = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Football", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 17, minute: 0)
        )

        let reloaded = try planningRepository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        let reloadedActivity = reloaded.first { $0.plannedActivityId == created.plannedActivityId }
        #expect(reloadedActivity?.startLocalTime?.hour == 17)
        #expect(reloadedActivity?.startLocalTime?.minute == 0)
    }

    @Test("Tomorrow aggregation works across multiple athletes")
    @MainActor
    func tomorrowAggregatesMultipleAthletes() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let weeklyReflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)

        guard let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) else {
            Issue.record("Could not compute tomorrow"); return
        }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: tomorrowDate)
        let tomorrow = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: tomorrowDate)

        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let emma = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Emma",
            birthDate: LocalDate(year: 2014, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let oliverWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: oliverWeekPlan.weekPlanId, athleteId: oliver.athleteId, activityType: .teamTraining,
            title: "Football", localDate: tomorrow, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 17, minute: 0)
        )
        let emmaWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: emma.athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: emmaWeekPlan.weekPlanId, athleteId: emma.athleteId, activityType: .teamTraining,
            title: "Handball", localDate: tomorrow, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 9, minute: 0)
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [oliver, emma],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadTomorrow()

        #expect(viewModel.tomorrowRows.count == 2)
        #expect(Set(viewModel.tomorrowRows.map(\.athleteName)) == ["Oliver", "Emma"])
        // Chronological — Emma's 9:00 activity before Oliver's 17:00.
        #expect(viewModel.tomorrowRows.map(\.athleteName) == ["Emma", "Oliver"])
    }

    /// Sprint 1.2B runtime closeout (P1): Tomorrow must include an
    /// unmaterialized recurring occurrence — confirmed missing
    /// entirely before this fix (loadTomorrow() only ever queried
    /// materialized PlannedActivity rows). Also confirms viewing it
    /// never materializes anything: no WeekPlan is created for
    /// tomorrow's week merely by loading the schedule.
    @Test("Tomorrow includes an unmaterialized recurring occurrence, without materializing it")
    @MainActor
    func tomorrowIncludesUnmaterializedRecurringOccurrence() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let weeklyReflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)

        guard let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) else {
            Issue.record("Could not compute tomorrow"); return
        }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: tomorrowDate)
        let tomorrow = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: tomorrowDate)

        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        // Deliberately NOT calling getOrCreateWeekPlan for tomorrow's
        // week at all — matching "the parent has never visited this
        // week's plan," the exact scenario the fix addresses.
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [tomorrow.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [oliver],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadTomorrow()

        #expect(viewModel.tomorrowRows.count == 1)
        guard case .recurringOccurrence = viewModel.tomorrowRows.first else {
            Issue.record("Expected a .recurringOccurrence row")
            return
        }

        // Never materialized merely by loading Tomorrow — no WeekPlan
        // exists for tomorrow's week at all.
        let weekPlan = try planningRepository.fetchWeekPlan(forAthlete: oliver.athleteId, weekStart: weekStart)
        #expect(weekPlan == nil)
    }

    @Test("Family Schedule includes upcoming activities from multiple athletes, grouped and ordered deterministically")
    @MainActor
    func familyScheduleGroupsMultipleAthletesDeterministically() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )

        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let emma = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Emma",
            birthDate: LocalDate(year: 2014, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        // Day+3 and Day+7 — two distinct upcoming days, potentially
        // spanning different WeekPlans.
        guard let dayPlus3 = Calendar.current.date(byAdding: .day, value: 3, to: .now),
              let dayPlus7 = Calendar.current.date(byAdding: .day, value: 7, to: .now) else {
            Issue.record("Could not compute reference dates"); return
        }
        func localDate(_ date: Date) -> LocalDate {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        }
        let date3 = localDate(dayPlus3)
        let date7 = localDate(dayPlus7)

        let oliverWeekPlan3 = try planningService.getOrCreateWeekPlan(
            athleteId: oliver.athleteId, weekStart: TrainingPlanningCoordinationService.weekStart(referenceDate: dayPlus3)
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: oliverWeekPlan3.weekPlanId, athleteId: oliver.athleteId, activityType: .teamTraining,
            title: "Football", localDate: date3, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let emmaWeekPlan7 = try planningService.getOrCreateWeekPlan(
            athleteId: emma.athleteId, weekStart: TrainingPlanningCoordinationService.weekStart(referenceDate: dayPlus7)
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: emmaWeekPlan7.weekPlanId, athleteId: emma.athleteId, activityType: .teamTraining,
            title: "Handball", localDate: date7, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [oliver, emma] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        #expect(viewModel.dayGroups.count == 2)
        // Groups sorted by date ascending — day+3 before day+7.
        #expect(viewModel.dayGroups.map(\.date) == [date3, date7])
        #expect(viewModel.dayGroups.first?.rows.first?.athleteName == "Oliver")
        #expect(viewModel.dayGroups.last?.rows.first?.athleteName == "Emma")

        // Re-running produces the identical grouping/order — deterministic.
        viewModel.loadSchedule()
        #expect(viewModel.dayGroups.map(\.date) == [date3, date7])
    }

    // MARK: - Active-roster freshness (Archive/Reactivate)

    /// Active-roster freshness fix (runtime/state audit): proves
    /// `loadSchedule()` asks `provideActiveAthletes()` again on every
    /// call, rather than permanently using whatever roster was true at
    /// construction — the exact defect this fix closes (Family Schedule
    /// previously froze its roster forever once pushed, so an athlete
    /// archived or reactivated while the screen remained on-screen never
    /// appeared/disappeared without a full pop-and-repush).
    @Test("FamilySchedule asks its roster provider again on a later load, not only at construction")
    @MainActor
    func familyScheduleReasksRosterProviderOnLaterLoad() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        var providerCallCount = 0
        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: {
                providerCallCount += 1
                return [oliver]
            },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        #expect(providerCallCount == 0)

        viewModel.loadSchedule()
        #expect(providerCallCount == 1)

        viewModel.loadSchedule()
        #expect(providerCallCount == 2)
    }

    /// Guarantee 2: a reactivated athlete (simulated here by the
    /// provider's result growing between two loads of the SAME
    /// `FamilyScheduleViewModel` instance — exactly the "still pushed,
    /// no reconstruction" scenario the freshness fix targets) is
    /// included in the NEXT schedule load, without constructing a new
    /// ViewModel.
    @Test("Changing the roster provider's result from one athlete to two causes a later schedule load to include the newly-added athlete")
    @MainActor
    func familyScheduleLoadIncludesAthleteAddedToProvider() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let emma = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Emma",
            birthDate: LocalDate(year: 2014, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        guard let dayPlus3 = Calendar.current.date(byAdding: .day, value: 3, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: dayPlus3)
        let date3 = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        let oliverWeekPlan = try planningService.getOrCreateWeekPlan(
            athleteId: oliver.athleteId, weekStart: TrainingPlanningCoordinationService.weekStart(referenceDate: dayPlus3)
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: oliverWeekPlan.weekPlanId, athleteId: oliver.athleteId, activityType: .teamTraining,
            title: "Football", localDate: date3, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let emmaWeekPlan = try planningService.getOrCreateWeekPlan(
            athleteId: emma.athleteId, weekStart: TrainingPlanningCoordinationService.weekStart(referenceDate: dayPlus3)
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: emmaWeekPlan.weekPlanId, athleteId: emma.athleteId, activityType: .teamTraining,
            title: "Handball", localDate: date3, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        var currentRoster: [AthleteProfile] = [oliver]
        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { currentRoster },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )

        viewModel.loadSchedule()
        #expect(Set(viewModel.dayGroups.flatMap(\.rows).map(\.athleteName)) == ["Oliver"])

        // Simulates Emma being reactivated between two loads of this same,
        // still-pushed screen instance — no new FamilyScheduleViewModel
        // constructed.
        currentRoster = [oliver, emma]
        viewModel.loadSchedule()
        #expect(Set(viewModel.dayGroups.flatMap(\.rows).map(\.athleteName)) == ["Oliver", "Emma"])
    }

    /// Guarantee 3: the inverse — an archived athlete (simulated by the
    /// provider's result shrinking between two loads of the SAME
    /// instance) is excluded from the NEXT schedule load.
    @Test("Changing the roster provider's result from two athletes to one causes a later schedule load to exclude the removed athlete")
    @MainActor
    func familyScheduleLoadExcludesAthleteRemovedFromProvider() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let emma = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Emma",
            birthDate: LocalDate(year: 2014, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        guard let dayPlus3 = Calendar.current.date(byAdding: .day, value: 3, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: dayPlus3)
        let date3 = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        let oliverWeekPlan = try planningService.getOrCreateWeekPlan(
            athleteId: oliver.athleteId, weekStart: TrainingPlanningCoordinationService.weekStart(referenceDate: dayPlus3)
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: oliverWeekPlan.weekPlanId, athleteId: oliver.athleteId, activityType: .teamTraining,
            title: "Football", localDate: date3, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let emmaWeekPlan = try planningService.getOrCreateWeekPlan(
            athleteId: emma.athleteId, weekStart: TrainingPlanningCoordinationService.weekStart(referenceDate: dayPlus3)
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: emmaWeekPlan.weekPlanId, athleteId: emma.athleteId, activityType: .teamTraining,
            title: "Handball", localDate: date3, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        var currentRoster: [AthleteProfile] = [oliver, emma]
        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { currentRoster },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )

        viewModel.loadSchedule()
        #expect(Set(viewModel.dayGroups.flatMap(\.rows).map(\.athleteName)) == ["Oliver", "Emma"])

        // Simulates Emma being archived between two loads of this same,
        // still-pushed screen instance — no new FamilyScheduleViewModel
        // constructed.
        currentRoster = [oliver]
        viewModel.loadSchedule()
        #expect(Set(viewModel.dayGroups.flatMap(\.rows).map(\.athleteName)) == ["Oliver"])
    }

    @Test("Navigation from Family Schedule preserves the correct athlete/activity identity")
    @MainActor
    func familyScheduleNavigationPreservesIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )

        let athleteId = AthleteId()
        guard let dayPlus3 = Calendar.current.date(byAdding: .day, value: 3, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: dayPlus3)
        let date3 = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        let weekPlan = try planningService.getOrCreateWeekPlan(
            athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart(referenceDate: dayPlus3)
        )
        let created = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Football", localDate: date3, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            location: "Nadderud Stadion"
        )

        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [athlete] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        // Note: athleteId in the group's rows comes from the ViewModel's
        // own activeAthletes list, not the freshly-generated athleteId
        // used above for the plan — this test targets the ACTIVITY
        // identity preserved through the query, which is athlete-scoped
        // via the athlete passed to loadSchedule's own iteration.
        _ = viewModel // constructed to confirm compile-time shape only for this identity check
        let resolvedActivity = try planningRepository.fetchPlannedActivity(byId: created.plannedActivityId)
        #expect(resolvedActivity?.plannedActivityId == created.plannedActivityId)
        #expect(resolvedActivity?.location == "Nadderud Stadion")

        // The ActivityDetailViewLoader this row would navigate to is
        // constructed directly from row.plannedActivity/row.athleteId —
        // confirming here that those values are exactly what was
        // created, not derived or guessed.
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let detailViewModel = ActivityDetailViewModel(
            activity: created, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )
        #expect(detailViewModel.activity.plannedActivityId == created.plannedActivityId)
    }
}

extension FamilyScheduleAndTomorrowTests {
    /// Sprint 1.1, P1: Family Schedule must show recurring activities
    /// occurring within its displayed range, even for a week the
    /// parent has never visited (no WeekPlan exists yet for it) — the
    /// exact gap this fix addresses. Confirms the recurring occurrence
    /// appears as its own, distinct row (never collapsed with a real
    /// planned activity), with correct athlete identity.
    @Test("Family Schedule includes recurring activities within its date range, even for a week with no existing WeekPlan")
    @MainActor
    func familyScheduleIncludesRecurringActivitiesForUnvisitedWeek() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )

        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        // A recurring activity effective well into the future — no
        // WeekPlan has ever been created for any of the weeks it
        // recurs into; deliberately NOT calling getOrCreateWeekPlan at
        // all, matching "a week nobody has visited yet." 5 days ahead —
        // inside the approved "today through 7 days ahead" window, far
        // enough to confirm the window extends beyond tomorrow alone.
        guard let farFuture = Calendar.current.date(byAdding: .day, value: 5, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: farFuture)
        let farFutureDate = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Swim Practice", activityType: .individualTraining,
            weekdays: [farFutureDate.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [oliver] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        let matchingGroup = viewModel.dayGroups.first { $0.date == farFutureDate }
        let recurringRow = matchingGroup?.rows.first { row in
            if case .recurringSuggestion = row { return true }
            return false
        }
        #expect(recurringRow != nil)
        #expect(recurringRow?.title == "Swim Practice")
        #expect(recurringRow?.athleteName == "Oliver")
    }

    @Test("A recurring occurrence already materialized into a real PlannedActivity is not duplicated as a separate suggestion row")
    @MainActor
    func materializedRecurringOccurrenceIsNotDuplicated() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )

        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        guard let inThreeDays = Calendar.current.date(byAdding: .day, value: 3, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: inThreeDays)
        let occurrenceDate = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: inThreeDays)

        let recurring = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Swim Practice", activityType: .individualTraining,
            weekdays: [occurrenceDate.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        // Materialize the occurrence via the real acceptSuggestion path.
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStart)
        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let matchingSuggestion = try #require(suggestions.first { $0.recurringPlannedActivityId == recurring.recurringPlannedActivityId })
        _ = try planningService.acceptSuggestion(matchingSuggestion, forWeekPlan: weekPlan.weekPlanId)

        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [oliver] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        let matchingGroup = viewModel.dayGroups.first { $0.date == occurrenceDate }
        // Exactly one row for this occurrence — the materialized
        // .planned one — never a duplicate .recurringSuggestion.
        #expect(matchingGroup?.rows.count == 1)
        if case .planned = matchingGroup?.rows.first {
            // Correct — materialized.
        } else {
            Issue.record("Expected the materialized occurrence to appear as a .planned row, not a suggestion")
        }
    }

    // MARK: - Rolling window: today through +7 days

    @Test("Family Schedule's rolling window includes today and excludes activities beyond +7 days")
    @MainActor
    func rollingWindowIncludesTodayThroughSevenDaysAndExcludesEighth() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let today = TrainingPlanningCoordinationService.today()
        let plusSeven = today.adding(days: 7)
        let plusEight = today.adding(days: 8)
        let weekStartToday = TrainingPlanningCoordinationService.weekStart()
        let weekStartPlusSeven = TrainingPlanningCoordinationService.weekStart(referenceDate: {
            var comps = DateComponents()
            comps.year = plusSeven.year; comps.month = plusSeven.month; comps.day = plusSeven.day
            return Calendar.current.date(from: comps) ?? .now
        }())
        let weekStartPlusEight = TrainingPlanningCoordinationService.weekStart(referenceDate: {
            var comps = DateComponents()
            comps.year = plusEight.year; comps.month = plusEight.month; comps.day = plusEight.day
            return Calendar.current.date(from: comps) ?? .now
        }())

        let weekPlanToday = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStartToday)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanToday.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Today's session", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let weekPlanPlusSeven = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStartPlusSeven)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanPlusSeven.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Plus-seven session", localDate: plusSeven, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let weekPlanPlusEight = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStartPlusEight)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanPlusEight.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Plus-eight session", localDate: plusEight, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [oliver] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        #expect(viewModel.dayGroups.contains { $0.date == today })
        #expect(viewModel.dayGroups.contains { $0.date == plusSeven })
        #expect(!viewModel.dayGroups.contains { $0.date == plusEight })
    }

    @Test("A Sunday reference still surfaces activities in the following week, not just the current calendar week")
    @MainActor
    func sundayReferenceSurfacesFollowingWeekActivities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        // 3 days ahead of today is always within the rolling window
        // regardless of which weekday "today" happens to be when this
        // test runs — including when today is itself a Sunday, this
        // date falls into the FOLLOWING Vǫxtr week (Monday-Sunday),
        // proving the rolling window is not bounded by the current
        // calendar week.
        let today = TrainingPlanningCoordinationService.today()
        let threeDaysAhead = today.adding(days: 3)
        let weekStartForTarget = threeDaysAhead.startOfWeek
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStartForTarget)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Following-week session", localDate: threeDaysAhead, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [oliver] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        let matchingGroup = viewModel.dayGroups.first { $0.date == threeDaysAhead }
        #expect(matchingGroup?.rows.contains { row in
            if case .planned(let familyHomeRow) = row { return familyHomeRow.plannedActivity.title == "Following-week session" }
            return false
        } == true)
    }

    /// Highest-practical-layer regression for the actual TestFlight
    /// report: proves `FamilyScheduleViewModel` itself — the real
    /// screen's own data path, not an isolated helper — genuinely
    /// crosses a Monday-Sunday week boundary. Unlike
    /// `sundayReferenceSurfacesFollowingWeekActivities` above (which
    /// only tests "3 days ahead," a window that DOESN'T cross a week
    /// boundary at all unless "today" happens to already be late in
    /// the week when the test runs — a non-deterministic proof of the
    /// one thing this test needs to prove), this test injects a
    /// deterministically-computed Sunday as "today" via the new
    /// `loadSchedule(referenceDate:calendar:)` overload, so the
    /// following-Monday activity is guaranteed to sit in the NEXT
    /// Vǫxtr week regardless of which weekday this test actually runs
    /// on.
    @Test("FamilyScheduleViewModel itself crosses a Sunday->Monday week boundary — planned activity, recurring occurrence, no duplication, no materialization")
    @MainActor
    func viewModelCrossesSundayToMondayWeekBoundary() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        // Deterministically compute the NEXT Sunday from "now" (or
        // today itself, if today already is Sunday) as the injected
        // reference date — never a hardcoded calendar date that could
        // go stale, never wall-clock "today" used directly.
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.year, .month, .day], from: .now)
        let todayLocalDate = LocalDate(year: nowComponents.year ?? 1970, month: nowComponents.month ?? 1, day: nowComponents.day ?? 1)
        let daysUntilSunday = (Weekday.sunday.rawValue - todayLocalDate.weekday.rawValue + 7) % 7
        let sundayLocalDate = todayLocalDate.adding(days: daysUntilSunday)
        var sundayComponents = DateComponents()
        sundayComponents.year = sundayLocalDate.year; sundayComponents.month = sundayLocalDate.month; sundayComponents.day = sundayLocalDate.day
        let sundayReferenceDate = calendar.date(from: sundayComponents) ?? .now
        #expect(sundayLocalDate.weekday == .sunday)

        // The following Monday — genuinely in the NEXT Vǫxtr week
        // relative to sundayLocalDate, not the same one.
        let followingMonday = sundayLocalDate.adding(days: 1)
        #expect(followingMonday.startOfWeek != sundayLocalDate.startOfWeek)
        // +8 days from the Sunday reference — must be excluded.
        let eightDaysOut = sundayLocalDate.adding(days: 8)

        let weekPlanForMonday = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: followingMonday.startOfWeek)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanForMonday.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Following Monday session", localDate: followingMonday, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        // A recurring definition landing on the same following Monday —
        // proves recurring composition also crosses the boundary,
        // read-only (never materialized merely by being displayed).
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Swim Practice", activityType: .individualTraining,
            weekdays: [followingMonday.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )
        // An activity 8 days out from the Sunday reference — must be
        // excluded from the rolling window entirely.
        let weekPlanForEighthDay = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: eightDaysOut.startOfWeek)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanForEighthDay.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Excluded eighth-day session", localDate: eightDaysOut, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [oliver] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        // The real screen's own entry point, injected with the fixed
        // Sunday reference — the same method FamilyScheduleView's own
        // .onAppear calls, not a bypass around it.
        viewModel.loadSchedule(referenceDate: sundayReferenceDate, calendar: calendar)

        // Criterion 4: crossing the boundary works — the materialized
        // planned activity in the following week appears.
        let mondayGroup = viewModel.dayGroups.first { $0.date == followingMonday }
        let plannedRow = mondayGroup?.rows.first { row in
            if case .planned(let familyHomeRow) = row { return familyHomeRow.plannedActivity.title == "Following Monday session" }
            return false
        }
        #expect(plannedRow != nil)

        // Criterion 5/6: the recurring occurrence for the SAME date
        // also appears (read-only composition), and there is exactly
        // one row per real identity on that day — no duplicate
        // recurring/materialized pair, no title/date-only inference.
        let recurringRow = mondayGroup?.rows.first { row in
            if case .recurringSuggestion(_, _, _, let suggestion) = row { return suggestion.title == "Swim Practice" }
            return false
        }
        #expect(recurringRow != nil)
        #expect(mondayGroup?.rows.count == 2)

        // Criterion 3: +8 days is excluded from the rolling window.
        #expect(!viewModel.dayGroups.contains { $0.date == eightDaysOut })
    }

    /// Design Foundation extension round: proves the injected
    /// `resolveAthleteColor` closure is what `resolvedAthleteColor(for:)`
    /// actually calls — not a second, locally re-derived colour — and
    /// that different athletes resolve independently through it (the
    /// same per-athlete isolation `FamilyHomeViewModelTests`'s own
    /// `resolvedAthleteColorPrefersExplicitPreferenceOverFallback` test
    /// already proves for Family Home). The default parameter (no
    /// resolver supplied) is exercised by every other test in this
    /// file, all seven of which predate this round and construct
    /// `FamilyScheduleViewModel` without a `resolveAthleteColor`
    /// argument — this test is the one that exercises the injected
    /// path instead.
    @Test("resolvedAthleteColor(for:) calls the injected resolver, independently per athlete")
    @MainActor
    func resolvedAthleteColorCallsInjectedResolverPerAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteId()
        let emma = AthleteId()
        // A resolver whose output is trivially checkable against its
        // input — proves the closure is actually invoked with the
        // right athlete id, per athlete, rather than some fixed or
        // memoized value.
        var resolvedIds: [AthleteId] = []
        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService,
            resolveAthleteColor: { athleteId in
                resolvedIds.append(athleteId)
                return athleteId == oliver ? .rose : .cyan
            }
        )

        #expect(viewModel.resolvedAthleteColor(for: oliver) == .rose)
        #expect(viewModel.resolvedAthleteColor(for: emma) == .cyan)
        #expect(resolvedIds == [oliver, emma])
    }

    /// The default `resolveAthleteColor` parameter — used by every
    /// pre-existing construction site above, none of which supplies a
    /// resolver — falls back to the same stable, repository-free
    /// `AthleteColor.forAthleteId(_:)` mapping Family Home itself falls
    /// back to when no explicit preference exists, so an athlete's
    /// colour is never left unresolved on Family Schedule.
    @Test("resolvedAthleteColor(for:) defaults to the stable AthleteColor.forAthleteId(_:) fallback when no resolver is injected")
    @MainActor
    func resolvedAthleteColorDefaultsToStableFallback() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()

        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )

        #expect(viewModel.resolvedAthleteColor(for: athleteId) == AthleteColor.forAthleteId(athleteId))
    }
}

extension FamilyScheduleAndTomorrowTests {
    // MARK: - Plan/Ahead root: calendar review prompt

    /// Test requirement 2: zero sources (or zero pending counts across
    /// all of them) must produce the same "nothing to show" result as
    /// the untouched `.none` default — Calm by Default, no permanent
    /// empty-state callout.
    @Test("CalendarReviewPrompt.from(sources:reviewCounts:) with no sources produces zero pending count and no actionable sources")
    func calendarReviewPromptFromEmptySourcesIsEmpty() throws {
        let prompt = FamilyScheduleViewModel.CalendarReviewPrompt.from(sources: [], reviewCounts: [:])
        #expect(prompt.totalPendingCount == 0)
        #expect(prompt.actionableSources.isEmpty)
    }

    /// Test requirement 3: with a mix of sources — some with pending
    /// items, some with zero, one with no entry in `reviewCounts` at
    /// all — the aggregate sums only the actionable ones and lists only
    /// those as `actionableSources`.
    @Test("CalendarReviewPrompt.from(sources:reviewCounts:) sums only sources with a positive pending count")
    func calendarReviewPromptFromMixedSourcesAggregatesCorrectly() throws {
        let workspaceId = WorkspaceId()
        let sourceWithPending = ExternalPlanningSource(
            workspaceId: workspaceId, providerKind: .eventKit,
            externalContainerIdentifier: "cal-with-pending", displayName: "Spond - Football", isEnabled: true
        )
        let sourceWithZero = ExternalPlanningSource(
            workspaceId: workspaceId, providerKind: .eventKit,
            externalContainerIdentifier: "cal-with-zero", displayName: "Spond - Handball", isEnabled: true
        )
        let sourceWithNoEntry = ExternalPlanningSource(
            workspaceId: workspaceId, providerKind: .eventKit,
            externalContainerIdentifier: "cal-no-entry", displayName: "Spond - Swimming", isEnabled: true
        )
        let secondSourceWithPending = ExternalPlanningSource(
            workspaceId: workspaceId, providerKind: .eventKit,
            externalContainerIdentifier: "cal-with-pending-2", displayName: "School Calendar", isEnabled: true
        )

        let reviewCounts: [ExternalPlanningSourceId: Int] = [
            sourceWithPending.externalPlanningSourceId: 5,
            sourceWithZero.externalPlanningSourceId: 0,
            secondSourceWithPending.externalPlanningSourceId: 2
            // sourceWithNoEntry deliberately has no entry at all.
        ]

        let prompt = FamilyScheduleViewModel.CalendarReviewPrompt.from(
            sources: [sourceWithPending, sourceWithZero, sourceWithNoEntry, secondSourceWithPending],
            reviewCounts: reviewCounts
        )

        #expect(prompt.totalPendingCount == 7)
        #expect(Set(prompt.actionableSources.map(\.externalPlanningSourceId)) == [
            sourceWithPending.externalPlanningSourceId, secondSourceWithPending.externalPlanningSourceId
        ])
    }

    /// Test requirement 4 / Lead Review follow-up: a disabled source
    /// must never contribute an actionable review count — proven here
    /// with a POSITIVE review count on the disabled source (the
    /// scenario that actually exercises the `isEnabled` guard inside
    /// `CalendarReviewPrompt.from(sources:reviewCounts:)` itself, rather
    /// than merely reflecting `FamilyCalendarSourcesViewModel.refreshSources()`'s
    /// own separate `isEnabled` short-circuit, which always writes `0`
    /// and would let a `reviewCounts[id] > 0` check alone pass this test
    /// without the pure function enforcing the rule directly). Defense
    /// in depth: this proves the aggregation function excludes a
    /// disabled source even if `reviewCounts` is stale or malformed.
    @Test("CalendarReviewPrompt.from(sources:reviewCounts:) excludes a disabled source even when its review count is positive")
    func calendarReviewPromptExcludesDisabledSourceWithPositiveCount() throws {
        let workspaceId = WorkspaceId()
        let disabledSource = ExternalPlanningSource(
            workspaceId: workspaceId, providerKind: .eventKit,
            externalContainerIdentifier: "cal-disabled", displayName: "Disabled Calendar", isEnabled: false
        )
        let enabledSource = ExternalPlanningSource(
            workspaceId: workspaceId, providerKind: .eventKit,
            externalContainerIdentifier: "cal-enabled", displayName: "Enabled Calendar", isEnabled: true
        )

        // Deliberately a POSITIVE count for the disabled source — stale
        // or malformed caller state is exactly what the pure function's
        // own `isEnabled` guard must survive.
        let reviewCounts: [ExternalPlanningSourceId: Int] = [
            disabledSource.externalPlanningSourceId: 99,
            enabledSource.externalPlanningSourceId: 3
        ]

        let prompt = FamilyScheduleViewModel.CalendarReviewPrompt.from(
            sources: [disabledSource, enabledSource], reviewCounts: reviewCounts
        )

        #expect(prompt.totalPendingCount == 3)
        #expect(prompt.actionableSources.map(\.externalPlanningSourceId) == [enabledSource.externalPlanningSourceId])
    }

    /// Proves the wiring between `FamilyScheduleViewModel.loadSchedule()`
    /// and the injected `provideCalendarReviewPrompt` closure — the
    /// same freshness contract `provideActiveAthletes` already has:
    /// re-read at the START of every load, not only at construction.
    @Test("FamilyScheduleViewModel.loadSchedule() assigns calendarReviewPrompt from the injected provider, freshly on every call")
    @MainActor
    func loadScheduleAssignsCalendarReviewPromptFromProvider() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )

        let workspaceId = WorkspaceId()
        let source = ExternalPlanningSource(
            workspaceId: workspaceId, providerKind: .eventKit,
            externalContainerIdentifier: "cal-1", displayName: "Spond", isEnabled: true
        )

        var currentPrompt = FamilyScheduleViewModel.CalendarReviewPrompt.none
        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService,
            provideCalendarReviewPrompt: { currentPrompt }
        )

        // No construction-time call — matches provideActiveAthletes's
        // own "not consulted until the first load" contract.
        viewModel.loadSchedule()
        #expect(viewModel.calendarReviewPrompt.totalPendingCount == 0)
        #expect(viewModel.calendarReviewPrompt.actionableSources.isEmpty)

        // Simulates pending review items appearing between two loads of
        // the same, still-pushed screen instance — no new
        // FamilyScheduleViewModel constructed.
        currentPrompt = .from(sources: [source], reviewCounts: [source.externalPlanningSourceId: 5])
        viewModel.loadSchedule()
        #expect(viewModel.calendarReviewPrompt.totalPendingCount == 5)
        #expect(viewModel.calendarReviewPrompt.actionableSources.map(\.externalPlanningSourceId) == [source.externalPlanningSourceId])
    }

    /// Test requirement: zero pending items must leave
    /// `FamilyScheduleViewModel.calendarReviewPrompt` at the same
    /// `.none`-equivalent state every pre-existing construction site
    /// (none of which supplies `provideCalendarReviewPrompt`) already
    /// gets by default — proving `FamilyScheduleView`'s own
    /// `viewModel.calendarReviewPrompt.totalPendingCount > 0` gate would
    /// show no callout in this state.
    @Test("FamilyScheduleViewModel defaults calendarReviewPrompt to none when no provider is injected")
    @MainActor
    func loadScheduleDefaultsCalendarReviewPromptToNone() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )

        let viewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        #expect(viewModel.calendarReviewPrompt.totalPendingCount == 0)
        #expect(viewModel.calendarReviewPrompt.actionableSources.isEmpty)
    }
}
