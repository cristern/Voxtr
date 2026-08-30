import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrCalendarPlanningDomain

/// Calendar Planning Source V1: thrown by mapping-configuration methods
/// below — genuine request problems, distinct from a reconciliation
/// outcome (which never throws per-event; see `reconcileAllEnabledMappings`).
public enum CalendarPlanningCoordinationError: Error, Sendable, Equatable {
    case athleteNotFound
    case mappingNotFound
    /// V1 product contract: one mapping per (calendar, athlete) pair.
    case duplicateMapping
}

/// Calendar Planning Source V1: the one place `CalendarPlanningMappingRepository`
/// (Calendar Planning domain), `PlanningService`, `TrainingService`, and
/// `AthleteRepository` are used together — same placement rationale
/// `NotificationsPlanningCoordinationService`/`TrainingPlanningCoordinationService`
/// already established for their own cross-domain concerns. Owns mapping
/// configuration (create/update/enable/disable/delete) and the actual
/// reconciliation operation.
///
/// External calendar data PROPOSES schedule facts; Planning remains
/// canonical. Every mutation below goes through `PlanningService`'s own
/// normal create/edit/delete methods — this type never touches
/// `PlanningRepository` or SwiftData directly, so every existing
/// lifecycle invariant/event (`PlannedActivityChanged`/`Deleted`, and
/// therefore Activity Reminder reconciliation) fires exactly as it does
/// for a Parent's own manual edit.
///
/// Recurring calendar events: EventKit reports each occurrence of a
/// recurring series as its own `ExternalCalendarEvent` (own
/// `eventIdentifier`, own `startDate`) — this type imports each one
/// independently, like any other event. It never creates or infers a
/// Vǫxtr `RecurringPlannedActivity` rule from Calendar recurrence, and
/// never touches that type at all.
@MainActor
public final class CalendarPlanningCoordinationService {
    /// The generic provenance-pair `type` half stamped on every
    /// `PlannedActivity` this coordinator creates — see
    /// `RecurringPlannedActivity.externalSourceType`'s own doc comment
    /// for why this field is deliberately generic, not EventKit-specific.
    public static let externalSourceType = "calendarPlanningSource"

    /// V1 Alpha reconciliation window, in days FORWARD from today (no
    /// historical lookback — "prefer future/current planning usefulness
    /// over historical ingestion"). 21 days = the current week plus two
    /// weeks of lookahead, so Weekly Planning has next week's imported
    /// activities ready before a Parent opens it. A named, explicit
    /// policy rather than a scattered magic number — see this type's own
    /// delivery-report rationale for why 21 was chosen over, e.g.,
    /// Family Schedule's unrelated 7-day "upcoming" presentation window.
    public static let reconciliationWindowDays = 21

    private let mappingRepository: CalendarPlanningMappingRepository
    private let calendarEventProvider: CalendarEventProviding
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let athleteRepository: AthleteRepository
    private let dateProvider: any DateProvider

    public init(
        mappingRepository: CalendarPlanningMappingRepository,
        calendarEventProvider: CalendarEventProviding,
        planningService: PlanningService,
        trainingService: TrainingService,
        athleteRepository: AthleteRepository,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.mappingRepository = mappingRepository
        self.calendarEventProvider = calendarEventProvider
        self.planningService = planningService
        self.trainingService = trainingService
        self.athleteRepository = athleteRepository
        self.dateProvider = dateProvider
    }

    // MARK: - Permission (contextual only — never called at launch)

    public func authorizationStatus(completion: @escaping @MainActor @Sendable (CalendarAuthorizationStatus) -> Void) {
        calendarEventProvider.authorizationStatus(completion: completion)
    }

    public func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        calendarEventProvider.requestAuthorization(completion: completion)
    }

    public func fetchAvailableCalendars() throws -> [AvailableCalendar] {
        try calendarEventProvider.availableCalendars()
    }

    // MARK: - Mapping configuration

    public func fetchMappings(forAthlete athleteId: AthleteId) throws -> [CalendarPlanningMapping] {
        try mappingRepository.fetchAll(forAthlete: athleteId)
    }

    @discardableResult
    public func createMapping(
        athleteId: AthleteId,
        calendarIdentifier: String,
        calendarTitle: String,
        activityType: ActivityType,
        sportId: SportId?
    ) throws -> CalendarPlanningMapping {
        guard try athleteRepository.fetchAthlete(byId: athleteId) != nil else {
            throw CalendarPlanningCoordinationError.athleteNotFound
        }
        let existing = try mappingRepository.fetchAll(forAthlete: athleteId)
        guard !existing.contains(where: { $0.calendarIdentifier == calendarIdentifier }) else {
            throw CalendarPlanningCoordinationError.duplicateMapping
        }
        return try mappingRepository.insert(
            athleteId: athleteId,
            calendarIdentifier: calendarIdentifier,
            calendarTitle: calendarTitle,
            activityType: activityType,
            sportId: sportId
        )
    }

    @discardableResult
    public func updateMapping(
        _ mappingId: CalendarPlanningMappingId,
        activityType: ActivityType,
        sportId: SportId?
    ) throws -> CalendarPlanningMapping {
        guard let mapping = try mappingRepository.fetch(byId: mappingId) else {
            throw CalendarPlanningCoordinationError.mappingNotFound
        }
        return try mappingRepository.update(mapping, activityType: activityType, sportId: sportId)
    }

    public func setMappingEnabled(_ mappingId: CalendarPlanningMappingId, isEnabled: Bool) throws {
        guard let mapping = try mappingRepository.fetch(byId: mappingId) else {
            throw CalendarPlanningCoordinationError.mappingNotFound
        }
        try mappingRepository.setEnabled(mapping, isEnabled: isEnabled)
    }

    /// Deletes the mapping (stops future reconciliation for this
    /// calendar) — never touches any `PlannedActivity` already imported
    /// through it. Those remain normal Planning data, editable/deletable
    /// through the normal Planning UI like anything else; disconnecting
    /// a source never retroactively erases what it already created.
    public func deleteMapping(_ mappingId: CalendarPlanningMappingId) throws {
        guard let mapping = try mappingRepository.fetch(byId: mappingId) else { return }
        try mappingRepository.delete(mapping)
    }

    // MARK: - Reconciliation

    /// Per-mapping reconciliation counts — presentation/diagnostic only,
    /// never itself a stored or authoritative value.
    public struct ReconciliationOutcome: Sendable, Equatable {
        public let created: Int
        public let updated: Int
        public let cancelled: Int
        /// An event this run could not safely act on — e.g. its target
        /// week is no longer draft, or it moved to a different week than
        /// its already-linked `PlannedActivity` (see this type's own
        /// doc comment on cross-week moves). Never a crash, never a
        /// fabricated mutation — just "left as-is this round."
        public let skipped: Int
    }

    /// Reconciles every currently-enabled mapping, in deterministic
    /// order. A disabled mapping is skipped entirely (no create/update/
    /// cancel) — "mapping disabled -> no new import." Safe and idempotent
    /// to call repeatedly (e.g. on every app foreground); each mapping's
    /// own `lastReconciledAt` is recorded whether or not anything
    /// changed. A single mapping's failure (e.g. its calendar was
    /// removed) does not prevent the others from reconciling.
    @discardableResult
    public func reconcileAllEnabledMappings() throws -> [CalendarPlanningMappingId: ReconciliationOutcome] {
        var results: [CalendarPlanningMappingId: ReconciliationOutcome] = [:]
        for mapping in try mappingRepository.fetchAllEnabled() {
            results[mapping.calendarPlanningMappingId] = try reconcile(mapping)
        }
        return results
    }

    @discardableResult
    public func reconcile(_ mapping: CalendarPlanningMapping) throws -> ReconciliationOutcome {
        let athleteId = AthleteId(rawValue: mapping.athleteId)
        guard let athlete = try athleteRepository.fetchAthlete(byId: athleteId) else {
            throw CalendarPlanningCoordinationError.athleteNotFound
        }

        let now = dateProvider.now
        guard let windowEnd = Calendar(identifier: .gregorian).date(
            byAdding: .day, value: Self.reconciliationWindowDays, to: now
        ) else {
            return ReconciliationOutcome(created: 0, updated: 0, cancelled: 0, skipped: 0)
        }
        let externalEvents = try calendarEventProvider.events(inCalendar: mapping.calendarIdentifier, from: now, to: windowEnd)
        // All-day events have no meaningful start TIME to plan around in
        // this V1 slice (Vǫxtr's own PlannedActivity.startLocalTime is
        // optional, but a Parent picking "when" needs an actual time to
        // build a reminder against) — excluded, not imported as a
        // dateless activity.
        let qualifyingEvents = externalEvents.filter { !$0.isAllDay }

        var created = 0
        var updated = 0
        var skipped = 0

        var seenExternalSourceIds: Set<String> = []
        for event in qualifyingEvents {
            let externalSourceId = Self.externalSourceId(calendarIdentifier: mapping.calendarIdentifier, eventIdentifier: event.eventIdentifier)
            seenExternalSourceIds.insert(externalSourceId)
            let outcome = try applyEvent(event, externalSourceId: externalSourceId, mapping: mapping, athlete: athlete)
            switch outcome {
            case .created: created += 1
            case .updated: updated += 1
            case .skipped: skipped += 1
            }
        }

        let cancelled = try cancelDisappearedActivities(
            mapping: mapping, athleteId: athleteId, windowStart: now, windowEnd: windowEnd, seenExternalSourceIds: seenExternalSourceIds
        )

        try mappingRepository.recordReconciliation(mapping, at: now)
        return ReconciliationOutcome(created: created, updated: updated, cancelled: cancelled, skipped: skipped)
    }

    private enum EventApplyOutcome { case created, updated, skipped }

    private func applyEvent(
        _ event: ExternalCalendarEvent,
        externalSourceId: String,
        mapping: CalendarPlanningMapping,
        athlete: AthleteProfile
    ) throws -> EventApplyOutcome {
        let athleteId = AthleteId(rawValue: athlete.id)
        let timeZoneId = athlete.timeZoneId
        let (localDate, startLocalTime) = Self.localDateAndTime(for: event.startDate, in: timeZoneId)
        let durationMinutes = Self.durationMinutes(start: event.startDate, end: event.endDate)

        let existingMatches = try planningService.fetchPlannedActivities(forAthlete: athleteId, externalSourceType: Self.externalSourceType)
        guard let existing = existingMatches.first(where: { $0.externalSourceId == externalSourceId }) else {
            // CREATE: never against a temporary/draft identity — the
            // canonical WeekPlan is resolved/created first, through the
            // same getOrCreateWeekPlan every other Planning creation path
            // uses.
            let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: localDate.startOfWeek)
            _ = try planningService.addPlannedActivity(
                toWeekPlan: weekPlan.weekPlanId,
                athleteId: athleteId,
                activityType: mapping.activityType,
                title: event.title,
                localDate: localDate,
                timeZoneId: timeZoneId,
                sportId: mapping.sportId.map { SportId(rawValue: $0) },
                startLocalTime: startLocalTime,
                plannedDurationMinutes: durationMinutes,
                externalSourceId: externalSourceId,
                externalSourceType: Self.externalSourceType
            )
            return .created
        }

        // UPDATE: the external source owns schedule facts (title/start/
        // duration/time zone); every other Vǫxtr-owned field — sportId,
        // activityType, categoryIds, plannedIntensity, notes, location —
        // is read back from the EXISTING row and passed through
        // unchanged, never re-applied from the mapping (the Parent may
        // have adjusted them after import; see this type's own
        // delivery-report note on field ownership).
        let existingWeekPlanId = WeekPlanId(rawValue: existing.weekPlanId)
        let targetWeekStart = localDate.startOfWeek
        guard let currentWeekPlan = try planningService.fetchWeekPlan(byId: existingWeekPlanId),
              currentWeekPlan.weekStart == targetWeekStart else {
            // The event moved to a different Vǫxtr planning week than its
            // already-linked PlannedActivity. editPlannedActivity cannot
            // move an activity between WeekPlans (weekPlanId is
            // identity/ownership, not editable) — inventing a delete+
            // recreate here would violate "an external update must not
            // replace the PlannedActivity identity." Left untouched this
            // round; see this type's own known-limitations note.
            return .skipped
        }
        do {
            _ = try planningService.editPlannedActivity(
                existing.plannedActivityId,
                expectedWeekPlanId: existingWeekPlanId,
                activityType: existing.activityType,
                title: event.title,
                localDate: localDate,
                timeZoneId: timeZoneId,
                sportId: existing.sportId.map { SportId(rawValue: $0) },
                categoryIds: existing.categoryIds.map { ActivityCategoryId(rawValue: $0) },
                startLocalTime: startLocalTime,
                plannedDurationMinutes: durationMinutes,
                plannedIntensity: existing.plannedIntensity,
                notes: existing.notes,
                location: existing.location
            )
            return .updated
        } catch PlanningServiceError.weekPlanNotDraft {
            // The week has since been committed — Planning's own existing
            // "no edits to a committed plan" rule applies exactly as it
            // does for a Parent's manual edit. Skipped, not an error.
            return .skipped
        }
    }

    /// Cancels/removes every already-imported `PlannedActivity` (for
    /// this mapping's calendar) inside the reconciliation window that no
    /// longer has a matching external event THIS round — "handle an
    /// event disappearing without silently leaving misleading future
    /// schedule data forever." Scoped strictly to the SAME window just
    /// fetched (never activities outside it, which were never re-checked
    /// this round and must not be treated as "disappeared").
    private func cancelDisappearedActivities(
        mapping: CalendarPlanningMapping,
        athleteId: AthleteId,
        windowStart: Date,
        windowEnd: Date,
        seenExternalSourceIds: Set<String>
    ) throws -> Int {
        let athlete = try athleteRepository.fetchAthlete(byId: athleteId)
        let timeZoneId = athlete?.timeZoneId ?? TimeZoneId(rawValue: TimeZone.current.identifier)
        let windowStartLocalDate = Self.localDateAndTime(for: windowStart, in: timeZoneId).0
        let windowEndLocalDate = Self.localDateAndTime(for: windowEnd, in: timeZoneId).0

        let calendarPrefix = "\(mapping.calendarIdentifier)|"
        let allLinked = try planningService.fetchPlannedActivities(forAthlete: athleteId, externalSourceType: Self.externalSourceType)
        let candidates = allLinked.filter { activity in
            guard let sourceId = activity.externalSourceId, sourceId.hasPrefix(calendarPrefix) else { return false }
            guard !seenExternalSourceIds.contains(sourceId) else { return false }
            return activity.localDate >= windowStartLocalDate && activity.localDate <= windowEndLocalDate
        }

        var cancelled = 0
        for activity in candidates {
            // Planning proposes; Training proves. Proven training truth
            // is never erased by an external source disappearing.
            let logged = try trainingService.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
            guard logged.isEmpty else { continue }
            let weekPlanId = WeekPlanId(rawValue: activity.weekPlanId)
            do {
                try planningService.deletePlannedActivity(
                    activity.plannedActivityId, expectedWeekPlanId: weekPlanId, deletedBy: .system
                )
                cancelled += 1
            } catch PlanningServiceError.weekPlanNotDraft {
                // Same "already-committed week" boundary as the update
                // path above — left in place, not an error.
                continue
            }
        }
        return cancelled
    }

    // MARK: - Identity + time normalization

    static func externalSourceId(calendarIdentifier: String, eventIdentifier: String) -> String {
        "\(calendarIdentifier)|\(eventIdentifier)"
    }

    /// The ONE place an `ExternalCalendarEvent`'s absolute `Date` is
    /// normalized into Vǫxtr's own `LocalDate`/`LocalTime` — never the
    /// device's current time zone, always the athlete's own configured
    /// `AthleteProfile.timeZoneId` (the same field `PlannedActivity.timeZoneId`
    /// is already populated from throughout this app), matching "do not
    /// silently use device-current timezone as business truth" and
    /// "normalize only at the integration boundary."
    private static func localDateAndTime(for date: Date, in timeZoneId: TimeZoneId) -> (LocalDate, LocalTime) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneId.timeZone ?? TimeZone(identifier: "UTC") ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let localDate = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        let localTime = LocalTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
        return (localDate, localTime)
    }

    private static func durationMinutes(start: Date, end: Date?) -> Int? {
        guard let end else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        guard (1...1440).contains(minutes) else { return nil }
        return minutes
    }
}
