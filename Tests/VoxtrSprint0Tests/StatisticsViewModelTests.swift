import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrParentDomain
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
        let athleteId = AthleteId()
        let football = SportId()

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

    // MARK: - Required ViewModel test 10: series toggles never mutate Statistics data

    @Test("Toggling Development Timeline series visibility never reloads or alters the underlying Statistics data")
    @MainActor
    func seriesTogglesNeverMutateUnderlyingData() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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

    // MARK: - Required ViewModel test 11: no-data is distinct from error

    @Test("An athlete with no data in the period loads as .loaded with factual zeroes, never .failed")
    @MainActor
    func noDataLoadsAsLoadedNeverFailed() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
}
