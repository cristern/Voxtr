import Foundation
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrReflectionDomain

/// VX-023 (Sleep V1): the one place `AthleteRepository` (Sleep tracking
/// preference) and `ReflectionService` (canonical `DailyStatus.sleepQuality`)
/// are used together — same cross-domain-composition-lives-in-AppShell
/// reasoning `TrainingReflectionCoordinationService`/
/// `TrainingPlanningCoordinationService` already establish for their own
/// domain pairs.
///
/// TRACKING DEFAULT: "no `AthleteSettings` row for this athlete" means
/// tracking is ON — a pure application-logic decision made here in
/// `isSleepTrackingEnabled(for:)`, never a SwiftData column default
/// applied retroactively to existing rows (there are none; see
/// `AthleteSettings.sleepTrackingEnabled`'s own doc comment).
///
/// INVALIDATION: `recordSleep` calls `sleepChangeBroadcaster?.sleepChanged(for:)`
/// once the canonical write already succeeded — the single fan-out point
/// for "athlete X's Sleep presentation may be stale," mirroring (not
/// reusing) `TrainingReflectionCoordinationService`'s own placement
/// pattern for `AthleteActivityChangeBroadcaster`.
@MainActor
public final class SleepCoordinationService: SleepStatusProviding {
    private let reflectionService: ReflectionService
    private let athleteRepository: AthleteRepository
    private let sleepChangeBroadcaster: AthleteSleepChangeBroadcaster?

    public init(
        reflectionService: ReflectionService,
        athleteRepository: AthleteRepository,
        sleepChangeBroadcaster: AthleteSleepChangeBroadcaster? = nil
    ) {
        self.reflectionService = reflectionService
        self.athleteRepository = athleteRepository
        self.sleepChangeBroadcaster = sleepChangeBroadcaster
    }

    /// "No row = tracking ON." See this type's own doc comment.
    public func isSleepTrackingEnabled(for athleteId: AthleteId) throws -> Bool {
        try athleteRepository.fetchAthleteSettings(forAthlete: athleteId)?.sleepTrackingEnabled ?? true
    }

    /// "Tracking OFF: existing Sleep data remains untouched... Disabled
    /// != missing... re-enabling continues the same canonical history" —
    /// this method only ever flips the preference flag; it never reads
    /// or writes any `DailyStatus` row, so Sleep history is provably
    /// untouched by a tracking toggle in either direction.
    @discardableResult
    public func setSleepTrackingEnabled(athleteId: AthleteId, enabled: Bool) throws -> Bool {
        try athleteRepository.setSleepTrackingEnabled(athleteId: athleteId, enabled: enabled).sleepTrackingEnabled
    }

    /// The canonical Sleep write path — see `ReflectionService.recordSleep`
    /// for the full create-vs-update / validation contract. Broadcasts
    /// only after the underlying write already succeeded.
    @discardableResult
    public func recordSleep(
        athleteId: AthleteId,
        localDate: LocalDate,
        sleepQuality: Int,
        visibility: VisibilityPolicy = .sharedWithGuardians,
        today: LocalDate
    ) throws -> DailyStatus {
        let status = try reflectionService.recordSleep(
            athleteId: athleteId,
            localDate: localDate,
            sleepQuality: sleepQuality,
            visibility: visibility,
            today: today
        )
        sleepChangeBroadcaster?.sleepChanged(for: athleteId)
        return status
    }

    public func fetchDailyStatus(forAthlete athleteId: AthleteId, localDate: LocalDate) throws -> DailyStatus? {
        try reflectionService.fetchDailyStatus(forAthlete: athleteId, localDate: localDate)
    }

    public func fetchDailyStatuses(forAthlete athleteId: AthleteId, from: LocalDate, to: LocalDate) throws -> [DailyStatus] {
        try reflectionService.fetchDailyStatuses(forAthlete: athleteId, from: from, to: to)
    }

    /// Injectable-`referenceDate` convenience, matching
    /// `TrainingPlanningCoordinationService.today(referenceDate:calendar:)`'s
    /// own established shape — callers that only have a `Date` (not
    /// already a `LocalDate`) use this instead of resolving "today"
    /// themselves.
    public static func today(referenceDate: Date = .now, calendar: Calendar = .current) -> LocalDate {
        TrainingPlanningCoordinationService.today(referenceDate: referenceDate, calendar: calendar)
    }
}
