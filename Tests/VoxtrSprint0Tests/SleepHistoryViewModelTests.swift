import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("SleepHistoryViewModel (VX-023 Sleep V1)", .serialized)
struct SleepHistoryViewModelTests {

    private static func makeService(container: ModelContainer) -> SleepCoordinationService {
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        return SleepCoordinationService(reflectionService: reflectionService, athleteRepository: athleteRepository)
    }

    @Test("12: initial history produces exactly 14 date rows — today + previous 13 days")
    @MainActor
    func initialHistoryProducesFourteenRows() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let today = LocalDate(year: 2026, month: 8, day: 17)

        let viewModel = SleepHistoryViewModel(sleepStatusProvider: service, athleteId: athleteId, today: today)
        viewModel.loadInitial()

        #expect(viewModel.rows.count == 14)
        #expect(viewModel.rows.first?.localDate == today)
        #expect(viewModel.rows.last?.localDate == today.adding(days: -13))
    }

    @Test("13: a date with no Sleep record appears as an explicit missing row (nil), never a score of 0")
    @MainActor
    func missingDatesAppearAsMissingNotZero() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let today = LocalDate(year: 2026, month: 8, day: 17)
        _ = try service.recordSleep(athleteId: athleteId, localDate: today, sleepQuality: 4, today: today)
        // Yesterday deliberately left with no Sleep record.

        let viewModel = SleepHistoryViewModel(sleepStatusProvider: service, athleteId: athleteId, today: today)
        viewModel.loadInitial()

        let todayRow = viewModel.rows.first { $0.localDate == today }
        let yesterdayRow = viewModel.rows.first { $0.localDate == today.adding(days: -1) }
        #expect(todayRow?.sleepQuality == 4)
        #expect(yesterdayRow?.sleepQuality == nil)
        #expect(viewModel.rows.contains { $0.localDate == today.adding(days: -1) })
    }

    @Test("14: older history beyond the initial 14-day window can be loaded, canonical data is not hard-limited to 14 days")
    @MainActor
    func olderHistoryCanBeLoaded() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let today = LocalDate(year: 2026, month: 8, day: 17)
        let farBack = today.adding(days: -20)
        _ = try service.recordSleep(athleteId: athleteId, localDate: farBack, sleepQuality: 2, today: today)

        let viewModel = SleepHistoryViewModel(sleepStatusProvider: service, athleteId: athleteId, today: today)
        viewModel.loadInitial()
        viewModel.loadMore()

        #expect(viewModel.rows.count == 28)
        #expect(viewModel.rows.first { $0.localDate == farBack }?.sleepQuality == 2)
        #expect(viewModel.canLoadMore == true)
    }

    @Test("15: editing a historical date and refreshing the row rereads the corrected canonical value")
    @MainActor
    func editHistoryDateRereadsCorrectedValue() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let today = LocalDate(year: 2026, month: 8, day: 17)
        let threeDaysAgo = today.adding(days: -3)
        _ = try service.recordSleep(athleteId: athleteId, localDate: threeDaysAgo, sleepQuality: 2, today: today)

        let viewModel = SleepHistoryViewModel(sleepStatusProvider: service, athleteId: athleteId, today: today)
        viewModel.loadInitial()
        #expect(viewModel.rows.first { $0.localDate == threeDaysAgo }?.sleepQuality == 2)

        // Simulate a correction made through the capture screen, against
        // the same canonical service this history view model reads.
        _ = try service.recordSleep(athleteId: athleteId, localDate: threeDaysAgo, sleepQuality: 5, today: today)
        viewModel.refreshRow(for: threeDaysAgo)

        #expect(viewModel.rows.first { $0.localDate == threeDaysAgo }?.sleepQuality == 5)
        #expect(viewModel.rows.count == 14)
    }
}
