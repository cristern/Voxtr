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
/// recurring series as its own `ExternalCalendarEvent`, but occurrences
/// of the SAME series share the SAME `eventIdentifier` — see
/// `ExternalCalendarEvent`'s own doc comment (PR #39 review follow-up,
/// Blocker 2: an earlier version of this comment incorrectly claimed
/// each occurrence had its own `eventIdentifier`; verified against
/// Apple's actual documented behavior and corrected). This type imports
/// each concrete occurrence independently, like any other event.
///
/// PR #39 review follow-up (second round): identity is NOT one uniform
/// shape for both cases. An ordinary, non-recurring event is identified
/// by `calendarIdentifier + eventIdentifier` alone — its `eventIdentifier`
/// is already stable for that event's whole lifetime, including after a
/// Parent edits its title or start time in Calendar, so folding a
/// TIME-DERIVED value into its identity would be wrong (an earlier
/// version of this fix did exactly that, unconditionally including
/// `occurrenceDate` — which defaults to `startDate` for a non-recurring
/// event — in every event's identity; this meant simply moving an
/// ordinary event's start time changed its own external identity and
/// caused reconciliation to create a SECOND `PlannedActivity` instead of
/// updating the first, a genuine regression this round fixes). Only a
/// RECURRING occurrence (`isRecurring == true`) additionally folds in
/// `occurrenceDate` — see
/// `externalSourceId(calendarIdentifier:event:)` below for the exact
/// gated rule. It never creates or infers a Vǫxtr `RecurringPlannedActivity`
/// rule from Calendar recurrence, and never touches that type at all.
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

    // MARK: - Alpha diagnostic (metadata inspection only)

    /// Calendar V1 metadata inspection: how far forward, and how many
    /// events, the Alpha-only diagnostic surface below reads — smaller
    /// and separate from `reconciliationWindowDays`/no limit, so this
    /// stays a calm, bounded, quick-to-read list rather than a second
    /// import surface. Named, explicit policy, matching this type's own
    /// established "no scattered magic numbers" convention.
    public static let diagnosticEventHorizonDays = 14
    public static let diagnosticEventLimit = 10

    /// Calendar V1 metadata inspection: a small, bounded, READ-ONLY look
    /// at real upcoming events in `calendarIdentifier` — never persisted
    /// anywhere by this method or its caller, never used for identity or
    /// classification, and never itself a Planning mutation. Exists
    /// solely so a Product Owner can see what metadata a real external
    /// source (e.g. Spond, via a subscribed iOS calendar) actually
    /// populates per event — notes/location/URL in particular — before
    /// any event-classification/matching-rule model is designed. Reuses
    /// the exact same `CalendarEventProviding.events(inCalendar:from:to:)`
    /// call reconciliation itself uses; this is not a second read path,
    /// only a smaller, bounded window over the same provider boundary.
    public func fetchDiagnosticEvents(inCalendar calendarIdentifier: String) throws -> [ExternalCalendarEvent] {
        let now = dateProvider.now
        guard let windowEnd = Calendar(identifier: .gregorian).date(
            byAdding: .day, value: Self.diagnosticEventHorizonDays, to: now
        ) else {
            return []
        }
        let events = try calendarEventProvider.events(inCalendar: calendarIdentifier, from: now, to: windowEnd)
        return Array(events.sorted { $0.startDate < $1.startDate }.prefix(Self.diagnosticEventLimit))
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
    /// a source never retroactively erases what it already created. To
    /// also remove what it already created, see
    /// `removeImportedActivities(for:removedBy:)` below — a deliberately
    /// separate, explicit action, never implied by disconnecting or
    /// disabling.
    public func deleteMapping(_ mappingId: CalendarPlanningMappingId) throws {
        guard let mapping = try mappingRepository.fetch(byId: mappingId) else { return }
        try mappingRepository.delete(mapping)
    }

    // MARK: - Recovery

    /// Calendar V1 recovery: outcome of an explicit, Parent-triggered
    /// "remove everything this mapping imported" action — distinct from
    /// `ReconciliationOutcome`, which reports what an automatic
    /// reconciliation run did. Never a silent success: every candidate
    /// activity ends up in exactly one bucket below, so a caller can
    /// always tell partial completion from full completion.
    public struct ImportedActivityCleanupOutcome: Sendable, Equatable {
        /// Deleted through the normal `PlanningService.deletePlannedActivity`
        /// path.
        public let removed: Int
        /// Left untouched because it already has a `LoggedActivity` —
        /// proven Training truth is never erased by this action, exactly
        /// like automatic reconciliation's own `cancelDisappearedActivities`.
        public let preservedLogged: Int
        /// Left untouched because its `WeekPlan` is committed AND
        /// historical (`weekStart` before the current week) — reopening a
        /// historical week is never permitted (see `WeekPlan.reopen`'s own
        /// `.historicalWeekNotReopenable` guard), so this action does not
        /// attempt it. Reported separately from `failed` because it is an
        /// expected, permanent-for-this-action outcome, not an error.
        public let historicalWeeksSkipped: Int
        /// Left untouched because of an unexpected failure (e.g. a
        /// concurrent revision conflict) reopening or deleting. Distinct
        /// from `historicalWeeksSkipped` so a caller can tell "this can
        /// never be cleaned up automatically" from "something went wrong,
        /// try again."
        public let failed: Int
        /// Review follow-up: count of WeekPlans that WERE originally
        /// `.committed`, were reopened to allow cleanup, and had at least
        /// one activity removed — but whose committed status could NOT be
        /// restored afterward (`PlanningService.commitWeekPlan` failed, or
        /// the WeekPlan could not be re-fetched). Reported separately so
        /// this is never silently reported as full success: a caller
        /// (and the Parent-facing result message) can tell "cleanup
        /// finished and the week is back the way it was" from "cleanup
        /// finished but this week is still in draft and needs attention."
        public let lifecycleRestoreFailed: Int
    }

    /// Calendar V1 recovery: removes every currently-linked, not-yet-
    /// logged `PlannedActivity` this ONE mapping (this athlete + this
    /// external calendar) has ever imported — the explicit "undo what a
    /// wrongly-configured connection already created" action a Parent
    /// reaches for after fixing (or before removing) a mapping that
    /// pulled in another child's activities from a mixed external
    /// calendar. Does not disable or delete the mapping itself — call
    /// `setMappingEnabled`/`deleteMapping` separately if that's also
    /// wanted; kept deliberately separate so neither one implies the
    /// other (see `deleteMapping`'s own doc comment).
    ///
    /// SCOPING (identity constraint verified against actual repository
    /// declarations before writing this method): `PlannedActivity` has no
    /// persisted `CalendarPlanningMappingId` of its own — provenance is
    /// only ever the generic `externalSourceId`/`externalSourceType` pair
    /// `RecurringPlannedActivity` already established, exactly as
    /// `cancelDisappearedActivities` above already relies on. The same
    /// three canonical facts that method already uses are sufficient and
    /// necessary to safely scope this action too, with no new persisted
    /// ID:
    ///   1. `athleteId == mapping.athleteId` — every `PlannedActivity`
    ///      already carries its own canonical, stable owning athlete;
    ///   2. `externalSourceType == Self.externalSourceType` — excludes
    ///      every manually-created activity (`nil`) AND every Recurring-
    ///      Planned-Activity-materialized one (`"recurringPlannedActivity"`)
    ///      in one filter, via `PlanningService.fetchPlannedActivities(forAthlete:externalSourceType:)`;
    ///   3. `externalSourceId?.hasPrefix("\(mapping.calendarIdentifier)|")` —
    ///      excludes every activity imported by a DIFFERENT calendar
    ///      mapping (a different `calendarIdentifier` never produces this
    ///      exact prefix; see `externalSourceId(calendarIdentifier:event:)`'s
    ///      own doc comment for the composite format this prefix always
    ///      starts with, for both the recurring and non-recurring case).
    /// Together these three facts can only ever match activities this
    /// exact athlete+calendar combination created — never another
    /// athlete's, never another calendar's, never a manually-created row.
    @discardableResult
    public func removeImportedActivities(for mapping: CalendarPlanningMapping, removedBy actorId: ActorId) throws -> ImportedActivityCleanupOutcome {
        let athleteId = AthleteId(rawValue: mapping.athleteId)
        let calendarPrefix = "\(mapping.calendarIdentifier)|"
        let athlete = try athleteRepository.fetchAthlete(byId: athleteId)
        let timeZoneId = athlete?.timeZoneId ?? TimeZoneId(rawValue: TimeZone.current.identifier)
        let currentWeekStart = Self.localDateAndTime(for: dateProvider.now, in: timeZoneId).0.startOfWeek

        let allLinked = try planningService.fetchPlannedActivities(forAthlete: athleteId, externalSourceType: Self.externalSourceType)
        let candidates = allLinked.filter { activity in
            guard let sourceId = activity.externalSourceId else { return false }
            return sourceId.hasPrefix(calendarPrefix)
        }

        var preservedLogged = 0

        // Review follow-up: grouped by WeekPlanId BEFORE any reopen/delete
        // happens, so a committed week containing several imported
        // activities is reopened and (if eligible) recommitted exactly
        // ONCE, never per-activity. `removeImportedActivities` must never
        // silently change a WeekPlan's lifecycle state — see this method's
        // per-week handling below.
        var eligibleByWeek: [WeekPlanId: [PlannedActivity]] = [:]
        for activity in candidates {
            // Planning proposes; Training proves. Proven training truth is
            // never erased by this action, same rule
            // `cancelDisappearedActivities` already enforces.
            let logged = try trainingService.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
            guard logged.isEmpty else {
                preservedLogged += 1
                continue
            }
            eligibleByWeek[WeekPlanId(rawValue: activity.weekPlanId), default: []].append(activity)
        }

        var removed = 0
        var historicalWeeksSkipped = 0
        var failed = 0
        var lifecycleRestoreFailed = 0

        for (weekPlanId, activities) in eligibleByWeek {
            // 1. Fetch the canonical WeekPlan.
            guard let weekPlan = try planningService.fetchWeekPlan(byId: weekPlanId) else {
                failed += activities.count
                continue
            }
            // 2. Remember whether it was originally committed.
            let wasOriginallyCommitted = weekPlan.status == .committed

            if wasOriginallyCommitted {
                // 3. Historical committed weeks are never reopened, by
                // design — this action cannot clean these up, reported
                // honestly rather than silently skipped.
                guard weekPlan.weekStart >= currentWeekStart else {
                    historicalWeeksSkipped += activities.count
                    continue
                }
                // 4. Current/future committed: reopen ONCE for this week.
                do {
                    try planningService.reopenWeekPlan(
                        weekPlanId, expectedRevision: weekPlan.revision, reopenedBy: actorId, currentWeekStart: currentWeekStart
                    )
                } catch {
                    failed += activities.count
                    continue
                }
            }

            // 5. Process all eligible deletes for this week.
            var weekRemoved = 0
            for activity in activities {
                do {
                    try planningService.deletePlannedActivity(
                        activity.plannedActivityId, expectedWeekPlanId: weekPlanId, deletedBy: actorId
                    )
                    weekRemoved += 1
                } catch {
                    failed += 1
                }
            }
            removed += weekRemoved

            guard wasOriginallyCommitted else { continue }
            // 6. Restore the week's original committed state through the
            // canonical PlanningService — never left silently in `.draft`.
            // The revision after reopen + N deletes is never assumed here:
            // `deletePlannedActivity` does not itself advance
            // `WeekPlan.revision`, but re-reading canonical state (rather
            // than reusing the pre-delete `weekPlan.revision`, or the
            // reopen call's return value) keeps this correct even if that
            // ever changes. If the WeekPlan can no longer be found, or
            // `commitWeekPlan` fails (e.g. a concurrent revision
            // conflict), this is reported via `lifecycleRestoreFailed`
            // rather than folded into `removed`/`failed` as a silent
            // success.
            do {
                guard let currentWeekPlan = try planningService.fetchWeekPlan(byId: weekPlanId) else {
                    lifecycleRestoreFailed += 1
                    continue
                }
                try planningService.commitWeekPlan(
                    weekPlanId, expectedRevision: currentWeekPlan.revision, committedBy: actorId
                )
            } catch {
                lifecycleRestoreFailed += 1
            }
        }

        return ImportedActivityCleanupOutcome(
            removed: removed,
            preservedLogged: preservedLogged,
            historicalWeeksSkipped: historicalWeeksSkipped,
            failed: failed,
            lifecycleRestoreFailed: lifecycleRestoreFailed
        )
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
    /// changed (only on a SUCCESSFUL reconciliation — see `reconcile(_:)`).
    /// A single mapping's failure (e.g. its calendar was removed, or its
    /// athlete is no longer resolvable) does not prevent the others from
    /// reconciling.
    ///
    /// PR #39 review follow-up (Blocker 1): the earlier version of this
    /// method called `try reconcile(mapping)` directly inside the loop —
    /// under Swift's own error-propagation rules, ANY single mapping
    /// throwing (a removed calendar, an unresolvable athlete) aborted the
    /// entire function immediately, silently skipping every mapping still
    /// to come. That directly contradicted this method's own doc comment
    /// above. Each mapping's `reconcile(_:)` call is now individually
    /// caught: a failing mapping contributes no entry to the returned
    /// dictionary (never a fabricated zeroed outcome — this method
    /// reports only what genuinely happened) and every other mapping
    /// still reconciles normally in the same run.
    @discardableResult
    public func reconcileAllEnabledMappings() throws -> [CalendarPlanningMappingId: ReconciliationOutcome] {
        var results: [CalendarPlanningMappingId: ReconciliationOutcome] = [:]
        for mapping in try mappingRepository.fetchAllEnabled() {
            do {
                results[mapping.calendarPlanningMappingId] = try reconcile(mapping)
            } catch {
                continue
            }
        }
        return results
    }

    /// PR #39 review follow-up (Blocker 1): `calendarEventProvider.events(...)`
    /// below is a plain `try` — if the provider throws
    /// `CalendarEventProviderError.calendarUnavailable` (calendar
    /// removed/unresolvable), this method throws immediately and
    /// performs NO create/update/cancel for this mapping at all; nothing
    /// after this call runs, including `cancelDisappearedActivities` and
    /// `mappingRepository.recordReconciliation`. An unavailable source is
    /// therefore never interpreted as "every previously-imported event
    /// disappeared" — only a genuinely successful (possibly empty) fetch
    /// can ever reach the cancellation step below. The caller
    /// (`reconcileAllEnabledMappings`) is responsible for not letting one
    /// mapping's thrown error stop the others.
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
            let externalSourceId = Self.externalSourceId(calendarIdentifier: mapping.calendarIdentifier, event: event)
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

    /// PR #39 review follow-up (Blocker 2, then corrected a second round
    /// later): `eventIdentifier` alone is NOT a valid occurrence identity
    /// for a RECURRING event — every concrete occurrence of the same
    /// series shares the SAME `eventIdentifier` (see
    /// `ExternalCalendarEvent`'s own doc comment). `occurrenceDate` is
    /// what actually distinguishes one occurrence from its siblings, and
    /// — critically — Apple documents it as remaining STABLE even after
    /// that occurrence is detached and its `startDate` moved. Using it
    /// (rather than the mutable `startDate`) means a moved/detached
    /// occurrence's `externalSourceId` does not change, so reconciliation
    /// finds the SAME already-imported `PlannedActivity` and updates it
    /// in place — never re-creating it under a new identity, and never
    /// colliding with a sibling occurrence that happens to move to the
    /// same new time.
    ///
    /// For an ORDINARY, non-recurring event, `eventIdentifier` alone
    /// already is a valid, stable identity for that event's entire
    /// lifetime — including across a Parent editing its title or start
    /// time. Folding `occurrenceDate` into a non-recurring event's
    /// identity would be actively wrong: `ExternalCalendarEvent.occurrenceDate`
    /// defaults to (and, for a genuinely non-recurring `EKEvent`, always
    /// tracks) its own `startDate`, so an ordinary event's identity would
    /// silently change every time its start time moved — reconciliation
    /// would then create a SECOND `PlannedActivity` instead of updating
    /// the first. `ExternalCalendarEvent.isRecurring` — the
    /// provider-neutral "this belongs to a recurring series" statement,
    /// correctly classified below the provider boundary (see
    /// `EventKitCalendarEventProvider`'s own doc comment on assigning it,
    /// which is more than just `EKEvent.hasRecurrenceRules` alone) — is
    /// therefore the gate: only a recurring event's identity includes
    /// `occurrenceDate` at all.
    static func externalSourceId(calendarIdentifier: String, event: ExternalCalendarEvent) -> String {
        guard event.isRecurring else {
            return "\(calendarIdentifier)|\(event.eventIdentifier)"
        }
        return "\(calendarIdentifier)|\(event.eventIdentifier)|\(event.occurrenceDate.timeIntervalSince1970)"
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
