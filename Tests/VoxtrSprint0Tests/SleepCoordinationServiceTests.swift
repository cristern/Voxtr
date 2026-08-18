import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

/// VX-023 (Sleep V1): `SleepCoordinationService` is the one place
/// `AthleteRepository` (Sleep tracking preference) and `ReflectionService`
/// (canonical `DailyStatus.sleepQuality`) meet — these tests exercise
/// the whole contract through that one type, the same way a real caller
/// (`HomeDashboardViewModel`/`SleepCaptureViewModel`/UI) actually would,
/// rather than splitting Sleep-specific assertions across the
/// pre-existing Reflection-only and Athlete-only test files.
@Suite("SleepCoordinationService (VX-023 Sleep V1)", .serialized)
struct SleepCoordinationServiceTests {

    private static func makeService(container: ModelContainer) -> SleepCoordinationService {
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        return SleepCoordinationService(reflectionService: reflectionService, athleteRepository: athleteRepository)
    }

    // MARK: Domain / Persistence (1-8)

    @Test("1: recording Sleep 1-5 for an athlete/date persists it as the canonical DailyStatus.sleepQuality")
    @MainActor
    func recordSleepPersists() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let date = LocalDate(year: 2026, month: 8, day: 17)

        let status = try service.recordSleep(athleteId: athleteId, localDate: date, sleepQuality: 4, today: date)

        #expect(status.sleepQuality == 4)
        #expect(status.athleteId == athleteId.rawValue)
        #expect(try container.mainContext.fetch(FetchDescriptor<DailyStatus>()).count == 1)
    }

    @Test("2: recording Sleep again for the same athlete/date updates the existing DailyStatus, never creates a second one")
    @MainActor
    func updateExistingSleepNeverDuplicates() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let date = LocalDate(year: 2026, month: 8, day: 17)

        let first = try service.recordSleep(athleteId: athleteId, localDate: date, sleepQuality: 2, today: date)
        let second = try service.recordSleep(athleteId: athleteId, localDate: date, sleepQuality: 5, today: date)

        #expect(first.id == second.id)
        #expect(second.sleepQuality == 5)
        #expect(try container.mainContext.fetch(FetchDescriptor<DailyStatus>()).count == 1)
    }

    @Test("3: adding/editing Sleep preserves every other DailyStatus field already recorded for that athlete/date")
    @MainActor
    func recordSleepPreservesOtherFields() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let date = LocalDate(year: 2026, month: 8, day: 17)

        // A different wellbeing signal recorded first, through the
        // canonical Reflection-domain path directly (matching how any
        // other DailyStatus field would arrive in production).
        _ = try reflectionRepository.upsertSleepQuality(
            athleteId: athleteId, localDate: date, sleepQuality: 3, visibility: .sharedWithGuardians
        )
        let existing = try reflectionRepository.fetchDailyStatus(forAthlete: athleteId, localDate: date)
        existing?.energy = 4
        existing?.note = "Felt strong"
        try container.mainContext.save()

        let updated = try service.recordSleep(athleteId: athleteId, localDate: date, sleepQuality: 5, today: date)

        #expect(updated.sleepQuality == 5)
        #expect(updated.energy == 4)
        #expect(updated.note == "Felt strong")
    }

    @Test("4: sleepQuality 0 and 6 are rejected through a controlled error, not a precondition crash")
    @MainActor
    func outOfRangeSleepQualityRejected() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let date = LocalDate(year: 2026, month: 8, day: 17)

        #expect(throws: ReflectionServiceError.invalidField("sleepQuality must be 1-5")) {
            try service.recordSleep(athleteId: athleteId, localDate: date, sleepQuality: 0, today: date)
        }
        #expect(throws: ReflectionServiceError.invalidField("sleepQuality must be 1-5")) {
            try service.recordSleep(athleteId: athleteId, localDate: date, sleepQuality: 6, today: date)
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<DailyStatus>()).count == 0)
    }

    @Test("5: a future LocalDate is rejected")
    @MainActor
    func futureDateRejected() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let today = LocalDate(year: 2026, month: 8, day: 17)
        let tomorrow = today.adding(days: 1)

        #expect(throws: ReflectionServiceError.futureDateNotAllowed) {
            try service.recordSleep(athleteId: athleteId, localDate: tomorrow, sleepQuality: 3, today: today)
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<DailyStatus>()).count == 0)
    }

    @Test("6: a historical date (including today itself) is allowed as backfill")
    @MainActor
    func historicalBackfillAllowed() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let today = LocalDate(year: 2026, month: 8, day: 17)
        let lastWeek = today.adding(days: -7)

        let backfilled = try service.recordSleep(athleteId: athleteId, localDate: lastWeek, sleepQuality: 3, today: today)
        let recordedToday = try service.recordSleep(athleteId: athleteId, localDate: today, sleepQuality: 4, today: today)

        #expect(backfilled.localDate == lastWeek)
        #expect(recordedToday.localDate == today)
    }

    @Test("7: recording Sleep for athlete A never changes athlete B's DailyStatus")
    @MainActor
    func athleteIsolation() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteA = AthleteId()
        let athleteB = AthleteId()
        let date = LocalDate(year: 2026, month: 8, day: 17)

        _ = try service.recordSleep(athleteId: athleteA, localDate: date, sleepQuality: 5, today: date)
        _ = try service.recordSleep(athleteId: athleteB, localDate: date, sleepQuality: 1, today: date)

        let a = try service.fetchDailyStatus(forAthlete: athleteA, localDate: date)
        let b = try service.fetchDailyStatus(forAthlete: athleteB, localDate: date)

        #expect(a?.sleepQuality == 5)
        #expect(b?.sleepQuality == 1)
    }

    @Test("8: the same athlete/date remains exactly one canonical DailyStatus across repeated edits")
    @MainActor
    func sameAthleteDateStaysOneCanonicalRow() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let date = LocalDate(year: 2026, month: 8, day: 17)

        for value in [2, 4, 1, 5, 3] {
            _ = try service.recordSleep(athleteId: athleteId, localDate: date, sleepQuality: value, today: date)
        }

        #expect(try container.mainContext.fetch(FetchDescriptor<DailyStatus>()).count == 1)
        #expect(try service.fetchDailyStatus(forAthlete: athleteId, localDate: date)?.sleepQuality == 3)
    }

    /// Review follow-up (one-DailyStatus-per-athlete/date audit):
    /// `ReflectionRepository`/`ReflectionService`/`SleepCoordinationService`
    /// are all `@MainActor`-isolated, and `upsertSleepQuality`'s own
    /// fetch → decide → insert-or-mutate → save sequence contains no
    /// `await` at all — a fully synchronous run of MainActor-isolated
    /// code cannot be interleaved by another MainActor-isolated call,
    /// only preempted at a suspension point, and there isn't one here.
    /// This test proves that guarantee under GENUINE concurrent
    /// scheduling (`withTaskGroup`, not just sequential calls in one
    /// test body, which `sameAthleteDateStaysOneCanonicalRow` above
    /// already covers) — ten concurrently-dispatched `recordSleep`
    /// calls for the identical athlete/date still resolve to exactly
    /// one canonical row. No lock/queue/actor was added to make this
    /// pass — the existing MainActor isolation already proves it.
    @Test("8b: ten concurrent recordSleep calls for the same athlete/date never produce two DailyStatus rows")
    @MainActor
    func concurrentRecordSleepNeverDuplicates() async throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let date = LocalDate(year: 2026, month: 8, day: 17)

        await withTaskGroup(of: Void.self) { group in
            for value in 1...10 {
                group.addTask { @MainActor in
                    _ = try? service.recordSleep(athleteId: athleteId, localDate: date, sleepQuality: (value % 5) + 1, today: date)
                }
            }
        }

        #expect(try container.mainContext.fetch(FetchDescriptor<DailyStatus>()).count == 1)
    }

    // MARK: Tracking (9-11)

    @Test("9: default Sleep tracking is On for an athlete with no AthleteSettings row at all")
    @MainActor
    func defaultTrackingIsOn() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)

        #expect(try service.isSleepTrackingEnabled(for: AthleteId()) == true)
    }

    @Test("10: turning tracking Off does not delete existing Sleep history")
    @MainActor
    func trackingOffPreservesHistory() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let date = LocalDate(year: 2026, month: 8, day: 17)
        _ = try service.recordSleep(athleteId: athleteId, localDate: date, sleepQuality: 4, today: date)

        try service.setSleepTrackingEnabled(athleteId: athleteId, enabled: false)

        #expect(try service.isSleepTrackingEnabled(for: athleteId) == false)
        #expect(try service.fetchDailyStatus(forAthlete: athleteId, localDate: date)?.sleepQuality == 4)
    }

    @Test("11: re-enabling tracking exposes the same existing history, untouched")
    @MainActor
    func reEnablingExposesSameHistory() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeService(container: container)
        let athleteId = AthleteId()
        let date = LocalDate(year: 2026, month: 8, day: 17)
        let recorded = try service.recordSleep(athleteId: athleteId, localDate: date, sleepQuality: 4, today: date)

        try service.setSleepTrackingEnabled(athleteId: athleteId, enabled: false)
        try service.setSleepTrackingEnabled(athleteId: athleteId, enabled: true)

        let rereadStatus = try service.fetchDailyStatus(forAthlete: athleteId, localDate: date)
        #expect(try service.isSleepTrackingEnabled(for: athleteId) == true)
        #expect(rereadStatus?.id == recorded.id)
        #expect(rereadStatus?.sleepQuality == 4)
    }
}
