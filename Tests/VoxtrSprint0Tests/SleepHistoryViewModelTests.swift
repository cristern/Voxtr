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

    /// Review follow-up (one-DailyStatus-per-athlete/date audit, part D):
    /// the canonical write path (`ReflectionRepository.upsertSleepQuality`)
    /// cannot produce two rows for the same athlete/date under normal
    /// operation — verified separately by
    /// `SleepCoordinationServiceTests.concurrentRecordSleepNeverDuplicates`.
    /// This test covers the READ side's own defensiveness for a
    /// "shouldn't happen" anomaly instead (hand-edited data, a future
    /// bug, direct `ModelContext` access bypassing the repository): two
    /// genuinely separate `DailyStatus` rows inserted directly for the
    /// same athlete/date must never crash Sleep History —
    /// `Dictionary(uniqueKeysWithValues:)` would `fatalError` on a
    /// duplicate key; the fix uses `uniquingKeysWith:` instead (see
    /// `SleepHistoryViewModel.loadMore()`'s own doc comment).
    @Test("Review follow-up: two duplicate DailyStatus rows for the same athlete/date never crash Sleep History — one is used, never a fatal error")
    @MainActor
    func duplicateRowsForSameDateNeverCrashHistory() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let athleteId = AthleteId()
        let date = LocalDate(year: 2026, month: 8, day: 17)

        // Bypasses the canonical upsert path entirely — inserted
        // directly, simulating an anomaly the write path itself cannot
        // produce.
        let first = DailyStatus(athleteId: athleteId, localDate: date, sleepQuality: 2, visibility: .sharedWithGuardians)
        let second = DailyStatus(athleteId: athleteId, localDate: date, sleepQuality: 5, visibility: .sharedWithGuardians)
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()

        let service = Self.makeService(container: container)
        let viewModel = SleepHistoryViewModel(sleepStatusProvider: service, athleteId: athleteId, today: date)

        viewModel.loadInitial()

        let matchingRows = viewModel.rows.filter { $0.localDate == date }
        #expect(matchingRows.count == 1)
        let resolvedSleepQuality = matchingRows.first?.sleepQuality
        #expect(resolvedSleepQuality == 2 || resolvedSleepQuality == 5)
    }
}
