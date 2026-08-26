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

    @Test("StatisticsPeriod.default is Last Month, spanning exactly the trailing 28 days ending today")
    func defaultPeriodSpansTrailingTwentyEightDays() {
        #expect(StatisticsPeriod.default == .lastMonth)
        let today = LocalDate(year: 2026, month: 3, day: 31)
        let interval = StatisticsPeriod.default.interval(today: today)
        #expect(interval.upperBound == today)
        #expect(interval.lowerBound == LocalDate(year: 2026, month: 3, day: 4))
    }

    @Test("Root's default-period card excludes an activity outside the trailing 28 days and includes one inside it")
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
        // Outside the trailing-28-days window ending 2026-03-31 (window starts 2026-03-04).
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
