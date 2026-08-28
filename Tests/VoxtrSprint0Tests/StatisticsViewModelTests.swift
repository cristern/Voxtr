import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.
@Suite("Statistics V1 UI ViewModels", .serialized)
struct StatisticsViewModelTests {

    /// Same UTC-anchored determinism reasoning as `StatisticsServiceTests
    /// .utcCalendar` — every fixture `Date`/`LocalDate` and every
    /// `today:` argument below is pinned, never derived from `Date.now`
    /// or the device's current timezone.
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }

    // MARK: - Required ViewModel test 7: root active/archived filtering

    @Test("StatisticsRootViewModel includes only active athletes, excluding an archived one")
    @MainActor
    func rootIncludesOnlyActiveAthletes() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        let familyManagementService = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let active = try familyManagementService.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Jonas", birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let archived = try familyManagementService.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Emma", birthDate: LocalDate(year: 2014, month: 6, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        _ = try familyManagementService.archiveAthlete(archived.athlete.athleteId, expectedRevision: archived.athlete.revision)

        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let viewModel = StatisticsRootViewModel(
            statisticsService: statisticsService, athleteRepository: athleteRepository, workspaceId: staged.workspace.workspaceId
        )

        viewModel.load(today: LocalDate(year: 2026, month: 3, day: 31))

        guard case .loaded(let cards) = viewModel.loadState else {
            Issue.record("Expected .loaded, got \(viewModel.loadState)")
            return
        }
        #expect(cards.count == 1)
        #expect(cards.first?.athleteId == active.athlete.athleteId)
    }

    // MARK: - Required ViewModel test 8: default period semantics

    @Test("StatisticsPeriod.default is rolling Last 4 Weeks, starting at the current week's own Monday minus 3 weeks")
    func defaultPeriodIsRollingLast4WeeksFromCurrentWeekStart() {
        #expect(StatisticsPeriod.default == .rolling(.last4Weeks))
        // 2026-03-31 is a Tuesday; its own week starts 2026-03-30 (Monday).
        let today = LocalDate(year: 2026, month: 3, day: 31)
        let interval = StatisticsPeriod.default.interval(today: today)
        #expect(interval.upperBound == today)
        #expect(interval.lowerBound == LocalDate(year: 2026, month: 3, day: 9))
        #expect(interval.lowerBound.weekday == .monday)
    }

    @Test("Root's default-period card excludes an activity outside the Last 4 Weeks window and includes one inside it")
    @MainActor
    func rootDefaultPeriodExcludesActivityOutsideWindow() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        let familyManagementService = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let athlete = try familyManagementService.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Jonas", birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        // Outside the Last 4 Weeks window ending 2026-03-31 (window starts 2026-03-09).
        _ = try trainingService.logActivity(
            athleteId: athlete.athlete.athleteId, activityType: .individualTraining, title: "Too old",
            startedAt: Self.date(2026, 2, 1), durationMinutes: 40, status: .completed
        )
        // Inside the window.
        _ = try trainingService.logActivity(
            athleteId: athlete.athlete.athleteId, activityType: .individualTraining, title: "Recent",
            startedAt: Self.date(2026, 3, 20), durationMinutes: 25, status: .completed
        )

        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let viewModel = StatisticsRootViewModel(
            statisticsService: statisticsService, athleteRepository: athleteRepository, workspaceId: staged.workspace.workspaceId
        )

        viewModel.load(today: LocalDate(year: 2026, month: 3, day: 31))

        guard case .loaded(let cards) = viewModel.loadState, let card = cards.first else {
            Issue.record("Expected exactly one loaded card")
            return
        }
        #expect(card.summary.totalActualMinutes == 25)
        #expect(card.summary.performedActivityCount == 1)
    }

    /// Review follow-up (PR #24), locked contract: each rolling window
    /// must produce EXACTLY that many canonical week buckets, for a
    /// `today` that falls mid-week (not just when `today` happens to be
    /// a Monday) — the exact scenario the contract mismatch bug
    /// produced 5 buckets for. `2026-03-31` is a Tuesday, deliberately
    /// not a Monday. Following the S1.1 lesson: no shared private
    /// helper methods for container construction — each test below
    /// builds its own inline.
    @Test("Last 4 Weeks produces exactly 4 canonical weekly buckets for a mid-week today, with a Monday lower bound")
    @MainActor
    func last4WeeksProducesExactlyFourBuckets() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let today = LocalDate(year: 2026, month: 3, day: 31)

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            period: .rolling(.last4Weeks), today: today
        )
        viewModel.load()

        guard case .loaded(let summary) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(summary.weeklyBuckets.count == 4)
        #expect(summary.weeklyBuckets.first?.weekStart.weekday == .monday)
        #expect(summary.intervalStart.weekday == .monday)
    }

    @Test("Last 13 Weeks produces exactly 13 canonical weekly buckets for a mid-week today, with a Monday lower bound")
    @MainActor
    func last13WeeksProducesExactlyThirteenBuckets() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let today = LocalDate(year: 2026, month: 3, day: 31)

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            period: .rolling(.last13Weeks), today: today
        )
        viewModel.load()

        guard case .loaded(let summary) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(summary.weeklyBuckets.count == 13)
        #expect(summary.weeklyBuckets.first?.weekStart.weekday == .monday)
        #expect(summary.intervalStart.weekday == .monday)
    }

    @Test("Last 26 Weeks produces exactly 26 canonical weekly buckets for a mid-week today, with a Monday lower bound")
    @MainActor
    func last26WeeksProducesExactlyTwentySixBuckets() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let today = LocalDate(year: 2026, month: 3, day: 31)

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            period: .rolling(.last26Weeks), today: today
        )
        viewModel.load()

        guard case .loaded(let summary) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(summary.weeklyBuckets.count == 26)
        #expect(summary.weeklyBuckets.first?.weekStart.weekday == .monday)
        #expect(summary.intervalStart.weekday == .monday)
    }

    // MARK: - Additional locked requirement: calendar month period

    @Test("A calendar month period resolves to the exact first-through-last day of that month")
    func calendarMonthResolvesToExactMonthBounds() {
        let interval = StatisticsPeriod.calendarMonth(year: 2026, month: 6).interval(today: LocalDate(year: 2026, month: 8, day: 1))
        #expect(interval.lowerBound == LocalDate(year: 2026, month: 6, day: 1))
        #expect(interval.upperBound == LocalDate(year: 2026, month: 6, day: 30))
    }

    @Test("A calendar month period resolves February correctly for a leap year (29 days)")
    func calendarMonthResolvesLeapFebruaryCorrectly() {
        let interval = StatisticsPeriod.calendarMonth(year: 2024, month: 2).interval(today: LocalDate(year: 2026, month: 8, day: 1))
        #expect(interval.lowerBound == LocalDate(year: 2024, month: 2, day: 1))
        #expect(interval.upperBound == LocalDate(year: 2024, month: 2, day: 29))
    }

    @Test("A calendar month period resolves February correctly for a non-leap year (28 days)")
    func calendarMonthResolvesNonLeapFebruaryCorrectly() {
        let interval = StatisticsPeriod.calendarMonth(year: 2026, month: 2).interval(today: LocalDate(year: 2026, month: 8, day: 1))
        #expect(interval.lowerBound == LocalDate(year: 2026, month: 2, day: 1))
        #expect(interval.upperBound == LocalDate(year: 2026, month: 2, day: 28))
    }

    // MARK: - Review follow-up (PR #24): month history range

    /// The Year picker's range must not hide genuinely readable
    /// canonical Statistics data behind an arbitrary short history
    /// limit — an athlete/family whose data goes back well beyond two
    /// years must still be selectable and resolve correctly.
    @Test("A historical month more than two years before today is selectable and resolves correctly")
    @MainActor
    func historicalMonthBeyondTwoYearsIsSelectableAndResolves() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let today = LocalDate(year: 2026, month: 8, day: 1)

        // June 2019 — more than 2 years (in fact more than 5) before `today`.
        let historicalMonth = StatisticsPeriod.calendarMonth(year: 2019, month: 6)
        #expect(StatisticsPeriod.selectableCalendarMonthYears(today: today).contains(2019))

        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Old training",
            startedAt: Self.date(2019, 6, 15), durationMinutes: 45, status: .completed
        )

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            period: historicalMonth, today: today
        )
        viewModel.load()

        guard case .loaded(let summary) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(summary.intervalStart == LocalDate(year: 2019, month: 6, day: 1))
        #expect(summary.intervalEnd == LocalDate(year: 2019, month: 6, day: 30))
        #expect(summary.totalActualMinutes == 45)
        #expect(summary.performedActivityCount == 1)
    }

    /// The Month picker's UI model must never offer a future month
    /// within the current year — this is the pure range-generation
    /// logic the View's Month picker is built from, tested without any
    /// SwiftUI rendering.
    @Test("A future month in the current year is not offered by the selectable-months UI model")
    func futureMonthInCurrentYearIsNotSelectable() {
        // today.month == 3 (March): only January-March should be offered.
        let today = LocalDate(year: 2026, month: 3, day: 15)
        let selectableMonths = StatisticsPeriod.selectableCalendarMonths(forYear: 2026, today: today)
        #expect(selectableMonths == 1...3)
        #expect(!selectableMonths.contains(4))
        #expect(!selectableMonths.contains(12))

        // A past year is entirely selectable, future months included —
        // "future" only applies relative to `today`'s OWN year.
        let pastYearMonths = StatisticsPeriod.selectableCalendarMonths(forYear: 2025, today: today)
        #expect(pastYearMonths == 1...12)
    }

    @Test("Changing the Year to the current year clamps a future-month selection down to today's month")
    func clampCalendarMonthPullsFutureMonthBackToToday() {
        let today = LocalDate(year: 2026, month: 3, day: 15)
        // Previously selected November while viewing a past year — now
        // switching the Year to the current year, November is in the future.
        let clamped = StatisticsPeriod.clampCalendarMonth(11, forYear: 2026, today: today)
        #expect(clamped == 3)

        // A month already within range is left untouched.
        let unchanged = StatisticsPeriod.clampCalendarMonth(2, forYear: 2026, today: today)
        #expect(unchanged == 2)
    }

    /// Integration proof: February 2026 starts on a Sunday and ends on
    /// a Saturday, so its calendar-month interval genuinely straddles a
    /// partial FIRST canonical week (starting Monday 2026-01-26, mostly
    /// outside the month) and a partial LAST canonical week (starting
    /// Monday 2026-02-23, extending past the month's own end) — proving
    /// the Development Timeline's weekly buckets are never forced onto
    /// the calendar-month boundary. Also proves data outside the
    /// selected month never contributes, even when adjacent (Jan 31 /
    /// Mar 1 fixtures just outside the boundary).
    @Test("Calendar-month weekly buckets may include partial first/last weeks, and no data outside the month contributes")
    @MainActor
    func calendarMonthProducesPartialBoundaryWeeksAndExcludesOutsideData() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()

        // Just outside the month on both sides — must not contribute.
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Last day of January",
            startedAt: Self.date(2026, 1, 31), durationMinutes: 50, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "First day of March",
            startedAt: Self.date(2026, 3, 1), durationMinutes: 60, status: .completed
        )
        // Inside the month.
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Mid-February",
            startedAt: Self.date(2026, 2, 14), durationMinutes: 30, status: .completed
        )

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            period: .calendarMonth(year: 2026, month: 2), today: LocalDate(year: 2026, month: 8, day: 1)
        )
        viewModel.load()

        guard case .loaded(let summary) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(summary.totalActualMinutes == 30)
        #expect(summary.performedActivityCount == 1)
        #expect(summary.intervalStart == LocalDate(year: 2026, month: 2, day: 1))
        #expect(summary.intervalEnd == LocalDate(year: 2026, month: 2, day: 28))
        #expect(summary.weeklyBuckets.count == 5)
        #expect(summary.weeklyBuckets.first?.weekStart == LocalDate(year: 2026, month: 1, day: 26))
        #expect(summary.weeklyBuckets.last?.weekStart == LocalDate(year: 2026, month: 2, day: 23))
    }

    // MARK: - Required ViewModel test 9: filter updates request the correct StatisticsFilter

    @Test("Setting Sport and Activity Type filters requests exactly the matching StatisticsFilter")
    @MainActor
    func filterUpdatesRequestTheCorrectStatisticsFilter() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let football = SportId()
        // Sport filter catalog refinement round: `football` must have
        // genuine recorded/performed history, or the ViewModel's own
        // invalid-selected-Sport reset (see `load()`) would immediately
        // revert the selection below back to "All Sports" — this
        // fixture makes `football` a legitimately SELECTABLE Sport,
        // matching how the Sport filter Menu is actually populated.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 20), durationMinutes: 20, status: .completed
        )

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            today: LocalDate(year: 2026, month: 3, day: 31)
        )
        viewModel.load()
        #expect(viewModel.currentFilter == StatisticsFilter.none)

        viewModel.setSportFilter(football)
        #expect(viewModel.currentFilter == StatisticsFilter(sportId: football))
        guard case .loaded(let afterSport) = viewModel.loadState else {
            Issue.record("Expected .loaded after setSportFilter")
            return
        }
        #expect(afterSport.filter == StatisticsFilter(sportId: football))

        viewModel.setActivityTypeFilter(.teamTraining)
        #expect(viewModel.currentFilter == StatisticsFilter(sportId: football, activityType: .teamTraining))
        guard case .loaded(let afterBoth) = viewModel.loadState else {
            Issue.record("Expected .loaded after setActivityTypeFilter")
            return
        }
        #expect(afterBoth.filter == StatisticsFilter(sportId: football, activityType: .teamTraining))
    }

    /// Symmetric to the required test above: setting Activity Type
    /// FIRST, then Sport, must retain BOTH — changing Sport must not
    /// reset an already-set Activity Type, regardless of which was set
    /// first.
    @Test("Setting Sport after Activity Type preserves both filters")
    @MainActor
    func settingSportAfterActivityTypePreservesBoth() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let football = SportId()
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 20), durationMinutes: 20, status: .completed
        )

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            today: LocalDate(year: 2026, month: 3, day: 31)
        )
        viewModel.load()

        viewModel.setActivityTypeFilter(.teamTraining)
        #expect(viewModel.currentFilter == StatisticsFilter(activityType: .teamTraining))

        viewModel.setSportFilter(football)
        #expect(viewModel.currentFilter == StatisticsFilter(sportId: football, activityType: .teamTraining))
    }

    // MARK: - Sport filter catalog refinement round: filter validity

    /// Required test: a previously selected Sport that is no longer
    /// available (its recorded history is gone, or it never had any to
    /// begin with by the time availability refreshes) is reset to "All
    /// Sports" — never silently substituted for a different Sport, and
    /// never left as a stale, invisible filter.
    @Test("An invalid selected Sport resets to All Sports when availability refreshes")
    @MainActor
    func invalidSelectedSportResetsToAllSports() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let football = SportId()
        let neverRecorded = SportId()
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 20), durationMinutes: 20, status: .completed
        )

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            today: LocalDate(year: 2026, month: 3, day: 31)
        )
        viewModel.load()
        #expect(viewModel.availableSportIds == Set([football]))

        // Select a genuinely available Sport first — must be honored.
        viewModel.setSportFilter(football)
        #expect(viewModel.sportFilter == football)

        // Now select a Sport with no recorded history at all. Since
        // `setSportFilter` itself calls `load()`, which refreshes
        // `availableSportIds` and validates the JUST-set selection in
        // the same pass, the invalid selection must never be observed
        // as "currently selected" — it resets to nil (All Sports)
        // within the same call, never a different Sport.
        viewModel.setSportFilter(neverRecorded)
        #expect(viewModel.sportFilter == nil)
        #expect(viewModel.currentFilter == StatisticsFilter.none)
    }

    // MARK: - Activity Type filter catalog refinement round: filter validity

    /// Required test: a previously selected Activity Type that is no
    /// longer available resets to "All Types" — the exact same calm
    /// fallback rule already established for Sport, applied
    /// independently: resetting an invalid Activity Type must never
    /// touch a currently-valid Sport selection.
    @Test("An invalid selected Activity Type resets to All Types when availability refreshes, without disturbing Sport")
    @MainActor
    func invalidSelectedActivityTypeResetsToAllTypes() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let football = SportId()
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 20), durationMinutes: 20, status: .completed
        )

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            today: LocalDate(year: 2026, month: 3, day: 31)
        )
        viewModel.load()
        #expect(viewModel.availableActivityTypes == Set([.teamTraining]))

        // A genuinely available Sport selection, present throughout.
        viewModel.setSportFilter(football)
        #expect(viewModel.sportFilter == football)

        // An Activity Type never recorded for this athlete. Since
        // `setActivityTypeFilter` itself calls `load()`, which refreshes
        // `availableActivityTypes` and validates the JUST-set selection
        // in the same pass, the invalid selection must never be
        // observed as "currently selected" — it resets to nil (All
        // Types) within the same call, and Sport remains untouched.
        viewModel.setActivityTypeFilter(.recovery)
        #expect(viewModel.activityTypeFilter == nil)
        #expect(viewModel.sportFilter == football)
        #expect(viewModel.currentFilter == StatisticsFilter(sportId: football))
    }

    /// Required contract: the Activity Type catalog is GLOBAL
    /// athlete-history availability, never contextually narrowed by
    /// the currently selected Sport. Selecting Hockey must not hide
    /// Match (recorded only against Football) or Strength (recorded
    /// with no Sport at all) from the Activity Type catalog.
    @Test("Selecting a Sport does not narrow the Activity Type catalog — it stays the athlete's full historical set")
    @MainActor
    func activityTypeCatalogIsIndependentOfSelectedSport() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let football = SportId()
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .match, title: nil,
            startedAt: Self.date(2026, 3, 6), durationMinutes: 40, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: nil, activityType: .strength, title: "Gym",
            startedAt: Self.date(2026, 3, 7), durationMinutes: 25, status: .completed
        )

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            today: LocalDate(year: 2026, month: 3, day: 31)
        )
        viewModel.load()
        #expect(viewModel.availableActivityTypes == Set([.teamTraining, .match, .strength]))

        viewModel.setSportFilter(hockey)

        #expect(viewModel.availableActivityTypes == Set([.teamTraining, .match, .strength]))
    }

    // MARK: - Required ViewModel test 10: series toggles never mutate Statistics data

    @Test("Toggling Development Timeline series visibility never reloads or alters the underlying Statistics data")
    @MainActor
    func seriesTogglesNeverMutateUnderlyingData() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 20), durationMinutes: 30, status: .completed
        )

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            today: LocalDate(year: 2026, month: 3, day: 31)
        )
        viewModel.load()
        let loadStateBefore = viewModel.loadState

        viewModel.isTrainingSeriesVisible = false
        viewModel.isFormSeriesVisible = false
        viewModel.isSleepSeriesVisible = true

        #expect(viewModel.loadState == loadStateBefore)
    }

    // MARK: - Required ViewModel test 14: Plan vs Actual presentation-mode state

    /// Required test 14: `timelineComparisonMode` defaults to the calm/
    /// default `.actual` mode and, like every other presentation-only
    /// toggle above, changing it never reloads or alters the underlying
    /// `StatisticsAthleteSummary` — the same shared, non-persisted,
    /// side-effect-free `AthleteStatisticsViewModel` state portrait and
    /// fullscreen both bind to.
    @Test("timelineComparisonMode defaults to .actual and changing it never reloads or alters the underlying Statistics data")
    @MainActor
    func timelineComparisonModeDefaultsToActualAndNeverMutatesUnderlyingData() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 20), durationMinutes: 30, status: .completed
        )

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            today: LocalDate(year: 2026, month: 3, day: 31)
        )
        #expect(viewModel.timelineComparisonMode == .actual)
        viewModel.load()
        let loadStateBefore = viewModel.loadState

        viewModel.timelineComparisonMode = .planVsActual

        #expect(viewModel.loadState == loadStateBefore)
    }

    // MARK: - Required ViewModel test 11: no-data is distinct from error

    @Test("An athlete with no data in the period loads as .loaded with factual zeroes, never .failed")
    @MainActor
    func noDataLoadsAsLoadedNeverFailed() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            today: LocalDate(year: 2026, month: 3, day: 31)
        )
        viewModel.load()

        guard case .loaded(let summary) = viewModel.loadState else {
            Issue.record("An athlete with genuinely no data must load as .loaded, not .failed — got \(viewModel.loadState)")
            return
        }
        #expect(summary.totalActualMinutes == 0)
        #expect(summary.performedActivityCount == 0)
        #expect(summary.form.mean == nil)
        #expect(summary.sleep.mean == nil)
    }

    // MARK: - Week Drilldown: required test 18, navigation/presentation state

    /// Required test 18: `selectWeek(_:)`/`dismissWeekDrilldown()` are
    /// pure presentation-state — the selected week identity is the
    /// canonical `LocalDate` passed in, and opening/closing the
    /// drilldown never reloads or alters the parent Statistics filter/
    /// period state it explains.
    @Test("selectWeek/dismissWeekDrilldown record the canonical LocalDate week identity and never mutate Statistics filter/period/loadState")
    @MainActor
    func selectWeekAndDismissAreNavigationStateOnly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            period: .rolling(.last4Weeks), today: LocalDate(year: 2026, month: 3, day: 31)
        )
        viewModel.load()
        #expect(viewModel.selectedWeekStart == nil)

        let periodBefore = viewModel.period
        let filterBefore = viewModel.currentFilter
        let loadStateBefore = viewModel.loadState
        let weekStart = LocalDate(year: 2026, month: 3, day: 9)

        viewModel.selectWeek(weekStart)

        #expect(viewModel.selectedWeekStart == weekStart)
        #expect(viewModel.period == periodBefore)
        #expect(viewModel.currentFilter == filterBefore)
        #expect(viewModel.loadState == loadStateBefore)

        viewModel.dismissWeekDrilldown()

        #expect(viewModel.selectedWeekStart == nil)
        #expect(viewModel.period == periodBefore)
        #expect(viewModel.currentFilter == filterBefore)
        #expect(viewModel.loadState == loadStateBefore)
    }

    /// `makeWeekDrilldownViewModel()` captures an IMMUTABLE snapshot of
    /// the interval/filter/today the parent screen was showing at
    /// selection time — never a live reference back to this ViewModel.
    @Test("makeWeekDrilldownViewModel captures the currently loaded interval/filter/today for the selected week")
    @MainActor
    func makeWeekDrilldownViewModelCapturesImmutableSnapshot() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        // A matching performed activity so `hockey` is a genuinely
        // available Sport — `setSportFilter` resets an unavailable
        // selection back to `nil` inside its own `load()` (see
        // `AthleteStatisticsViewModel.load()`'s own filter-validity
        // contract), which would otherwise silently defeat this test's
        // own filter-snapshot assertion below.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: "Match",
            startedAt: Self.date(2026, 3, 10), durationMinutes: 30, status: .completed
        )

        let viewModel = AthleteStatisticsViewModel(
            statisticsService: statisticsService, athleteId: athleteId, athleteDisplayName: "Jonas",
            period: .rolling(.last4Weeks), today: LocalDate(year: 2026, month: 3, day: 31)
        )
        viewModel.load()
        viewModel.setSportFilter(hockey)
        guard case .loaded(let summary) = viewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }

        #expect(viewModel.makeWeekDrilldownViewModel() == nil)

        let weekStart = LocalDate(year: 2026, month: 3, day: 9)
        viewModel.selectWeek(weekStart)
        let drilldownViewModel = try #require(viewModel.makeWeekDrilldownViewModel())

        #expect(drilldownViewModel.weekStart == weekStart)
        #expect(drilldownViewModel.athleteId == athleteId)
        drilldownViewModel.load()
        guard case .loaded(let detail) = drilldownViewModel.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(detail.filter == summary.filter)
        #expect(detail.intervalStart >= summary.intervalStart)
        #expect(detail.intervalEnd <= summary.intervalEnd)
    }

    // MARK: - Week Drilldown: fullscreen presentation-ownership fix

    /// Review follow-up (fullscreen presentation-ownership fix): the
    /// PURE decision rule `weekDrilldownSheet(viewModel:sports:isActive:)`
    /// delegates to — never a second, independently-implemented
    /// presentation-ownership check. No week selected means neither
    /// surface ever presents, regardless of which is active; once a
    /// week IS selected, portrait and fullscreen are always each
    /// other's exact complement (portrait's own `isActive` is
    /// `!isShowingFullscreenTimeline`, fullscreen's is unconditionally
    /// `true`), so exactly one of them is ever `true` for the SAME
    /// `selectedWeekStart` — never both, never neither.
    @Test("shouldPresentWeekDrilldown: no week selected never presents; exactly one of portrait/fullscreen presents once a week is selected")
    @MainActor
    func shouldPresentWeekDrilldownEnsuresExactlyOnePresenterIsActive() {
        let weekStart = LocalDate(year: 2026, month: 3, day: 9)

        // Required test 1 is implicit here: with no week selected,
        // neither the portrait-shaped call (isActive: true) nor the
        // fullscreen-shaped call (isActive: true) ever presents —
        // `selectedWeekStart` is the gate, not `isActive` alone.
        #expect(AthleteStatisticsViewModel.shouldPresentWeekDrilldown(selectedWeekStart: nil, isActive: true) == false)
        #expect(AthleteStatisticsViewModel.shouldPresentWeekDrilldown(selectedWeekStart: nil, isActive: false) == false)

        // Required test 1: portrait can present when fullscreen is
        // closed — portrait's own `isActive` is `!isShowingFullscreenTimeline`.
        let isShowingFullscreenTimeline = false
        #expect(AthleteStatisticsViewModel.shouldPresentWeekDrilldown(selectedWeekStart: weekStart, isActive: !isShowingFullscreenTimeline) == true)

        // Required tests 2-4: fullscreen IS open — portrait's own
        // `isActive` becomes `false` (must defer), fullscreen's own
        // `isActive` is unconditionally `true` (must present) — both
        // read the SAME `selectedWeekStart`, and exactly one of the two
        // presenters is ever active for it.
        let fullscreenOpen = true
        let portraitIsActive = !fullscreenOpen
        let fullscreenIsActive = true
        let portraitPresents = AthleteStatisticsViewModel.shouldPresentWeekDrilldown(selectedWeekStart: weekStart, isActive: portraitIsActive)
        let fullscreenPresents = AthleteStatisticsViewModel.shouldPresentWeekDrilldown(selectedWeekStart: weekStart, isActive: fullscreenIsActive)
        #expect(portraitPresents == false)
        #expect(fullscreenPresents == true)
        #expect(portraitPresents != fullscreenPresents)
    }
}
