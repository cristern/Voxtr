import Foundation
import VoxtrCore
import VoxtrCoreContracts

/// S2.2: thrown by `PlanningService` when an add/edit can't proceed.
/// Not a new business rule — these two cases are exactly the two guards
/// the approved scope asks for.
public enum PlanningServiceError: Error, Equatable {
    case weekPlanNotFound
    case plannedActivityNotFound
    case plannedActivityDoesNotBelongToWeekPlan
    case weekPlanNotDraft
    case invalidField(String)
    case recurringPlannedActivityNotFound
    case recurringOccurrenceAlreadyAccepted
    case recurringOccurrenceAthleteMismatch
    case recurringOccurrenceOutsideWeekPlan
    case recurringOccurrenceWeekdayMismatch
    case recurringOccurrenceOutsideEffectiveRange
    case recurringPlannedActivityDisabled
}

/// S2.1 scope only: one use case — get-or-create a draft `WeekPlan` for
/// a given athlete and calendar week. No commit-week behavior, no
/// `PlannedActivity` editing, no UI. Lives in `VoxtrPlanningDomain`
/// itself (not `VoxtrAppShell`) since it only ever touches Planning's
/// own entity via `PlanningRepository` — no cross-domain concern here.
@MainActor
public final class PlanningService {
    private let repository: PlanningRepository

    public init(repository: PlanningRepository) {
        self.repository = repository
    }

    /// Returns the existing draft `WeekPlan` for this athlete/week if
    /// one already exists; otherwise creates one and returns it. Never
    /// creates a second `WeekPlan` for the same athlete/week — the
    /// fetch-then-insert-if-absent check below is this use case's only
    /// business rule, matching the approved scope exactly ("one plan
    /// per athlete/week"), not inventing anything further. Status stays
    /// at `WeekPlan`'s own default (`.draft`) and revision at its own
    /// default (`1`) — this method sets neither explicitly, so any
    /// future change to those defaults is the entity's decision, not
    /// duplicated here.
    public func getOrCreateWeekPlan(athleteId: AthleteId, weekStart: LocalDate) throws -> WeekPlan {
        if let existing = try repository.fetchWeekPlan(forAthlete: athleteId, weekStart: weekStart) {
            return existing
        }
        return try repository.insertWeekPlan(athleteId: athleteId, weekStart: weekStart)
    }

    /// S2.3: commits a draft WeekPlan. Delegates entirely to `WeekPlan.
    /// commit` for the actual transition/revision-increment logic (the
    /// existing optimistic-concurrency model) — this method's only job
    /// is the existence check ("commit a WeekPlan that doesn't exist"
    /// isn't one of the two error cases `WeekPlan.commit` itself can
    /// express, since it needs an instance to call this on).
    /// `WeekPlanConflictError` (stale revision / already committed)
    /// propagates directly, unwrapped — same as how `AthleteProfile.
    /// applyMutation`'s conflict error is surfaced.
    @discardableResult
    public func commitWeekPlan(
        _ weekPlanId: WeekPlanId,
        expectedRevision: Int,
        committedBy: ActorId
    ) throws -> WeekPlan {
        guard let weekPlan = try repository.fetchWeekPlan(byId: weekPlanId) else {
            throw PlanningServiceError.weekPlanNotFound
        }
        try weekPlan.commit(expectedRevision: expectedRevision, committedBy: committedBy)
        try repository.save()
        return weekPlan
    }

    /// S2.2: adds a `PlannedActivity` to an existing `WeekPlan`.
    /// Requirement: "Prevent edits when the referenced WeekPlan does
    /// not exist" — checked here before any insert is attempted.
    public func addPlannedActivity(
        toWeekPlan weekPlanId: WeekPlanId,
        athleteId: AthleteId,
        activityType: ActivityType,
        title: String,
        localDate: LocalDate,
        timeZoneId: TimeZoneId,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        startLocalTime: LocalTime? = nil,
        plannedDurationMinutes: Int? = nil,
        plannedIntensity: Int? = nil,
        notes: String? = nil,
        location: String? = nil
    ) throws -> PlannedActivity {
        guard try repository.fetchWeekPlan(byId: weekPlanId) != nil else {
            throw PlanningServiceError.weekPlanNotFound
        }
        try Self.validate(
            title: title,
            plannedDurationMinutes: plannedDurationMinutes,
            plannedIntensity: plannedIntensity,
            notes: notes
        )
        return try repository.insertPlannedActivity(
            weekPlanId: weekPlanId,
            athleteId: athleteId,
            activityType: activityType,
            title: title,
            localDate: localDate,
            timeZoneId: timeZoneId,
            sportId: sportId,
            categoryIds: categoryIds,
            startLocalTime: startLocalTime,
            plannedDurationMinutes: plannedDurationMinutes,
            plannedIntensity: plannedIntensity,
            notes: notes,
            location: location
        )
    }

    /// S2.2: edits an existing `PlannedActivity`. Requirements: "Prevent
    /// edits when the referenced WeekPlan does not exist" and "...when
    /// the PlannedActivity does not belong to the supplied WeekPlan" —
    /// both checked before any field is changed. `id`, `weekPlanId`,
    /// `athleteId`, and `createdAt` are identity/ownership/audit fields
    /// and are not editable through this method — everything else
    /// `PlannedActivity` stores is.
    public func editPlannedActivity(
        _ plannedActivityId: PlannedActivityId,
        expectedWeekPlanId weekPlanId: WeekPlanId,
        activityType: ActivityType,
        title: String,
        localDate: LocalDate,
        timeZoneId: TimeZoneId,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        startLocalTime: LocalTime? = nil,
        plannedDurationMinutes: Int? = nil,
        plannedIntensity: Int? = nil,
        notes: String? = nil,
        location: String? = nil
    ) throws -> PlannedActivity {
        guard let weekPlan = try repository.fetchWeekPlan(byId: weekPlanId) else {
            throw PlanningServiceError.weekPlanNotFound
        }
        guard weekPlan.status == .draft else {
            throw PlanningServiceError.weekPlanNotDraft
        }
        guard let activity = try repository.fetchPlannedActivity(byId: plannedActivityId) else {
            throw PlanningServiceError.plannedActivityNotFound
        }
        guard activity.weekPlanId == weekPlanId.rawValue else {
            throw PlanningServiceError.plannedActivityDoesNotBelongToWeekPlan
        }
        try Self.validate(
            title: title,
            plannedDurationMinutes: plannedDurationMinutes,
            plannedIntensity: plannedIntensity,
            notes: notes
        )

        activity.activityType = activityType
        activity.title = title
        activity.localDate = localDate
        activity.timeZoneId = timeZoneId
        activity.sportId = sportId?.rawValue
        activity.categoryIds = categoryIds.map(\.rawValue)
        activity.startLocalTime = startLocalTime
        activity.plannedDurationMinutes = plannedDurationMinutes
        activity.plannedIntensity = plannedIntensity
        activity.notes = notes
        activity.location = location
        activity.updatedAt = .now

        try repository.save()
        return activity
    }

    /// S2.2: mirrors — does not replace — `PlannedActivity`'s own
    /// `precondition` bounds (v1.3 Section 8.2). `insertPlannedActivity`
    /// already goes through the entity's real initializer, which
    /// enforces these directly; this exists so `editPlannedActivity`
    /// (which mutates an already-constructed instance in place, so the
    /// initializer's preconditions don't run again) can reject the same
    /// invalid input with a catchable error instead of a crash.
    private static func validate(
        title: String,
        plannedDurationMinutes: Int?,
        plannedIntensity: Int?,
        notes: String?
    ) throws {
        guard (1...120).contains(title.count) else {
            throw PlanningServiceError.invalidField("title must be 1-120 characters")
        }
        if let duration = plannedDurationMinutes {
            guard (1...1440).contains(duration) else {
                throw PlanningServiceError.invalidField("plannedDurationMinutes must be 1-1440")
            }
        }
        if let intensity = plannedIntensity {
            guard (1...10).contains(intensity) else {
                throw PlanningServiceError.invalidField("plannedIntensity must be 1-10")
            }
        }
        if let notes, notes.count > 500 {
            throw PlanningServiceError.invalidField("notes must be 0-500 characters")
        }
    }

    /// S2.4: passthrough so UI code only ever depends on
    /// `PlanningService`, never `PlanningRepository` directly (same
    /// "reuse PlanningService" boundary every other UI-facing method
    /// here already follows).
    public func fetchPlannedActivities(forWeekPlan weekPlanId: WeekPlanId) throws -> [PlannedActivity] {
        try repository.fetchPlannedActivities(forWeekPlan: weekPlanId)
    }

    /// Sprint 1 (Daily Use Foundation): a thin passthrough, matching
    /// this service's own established "reuse PlanningService" boundary
    /// — needed so a UI layer can determine a WeekPlan's `.draft`
    /// status (e.g. before constructing `ActivityDetailViewModel`)
    /// without reaching into `PlanningRepository` directly.
    public func fetchWeekPlan(byId weekPlanId: WeekPlanId) throws -> WeekPlan? {
        try repository.fetchWeekPlan(byId: weekPlanId)
    }

    /// Sprint 1.1 closeout, Item 2: a thin passthrough, matching this
    /// service's own established "reuse PlanningService" boundary —
    /// needed so an unmaterialized recurring occurrence's preview can
    /// reach its underlying `RecurringPlannedActivity` definition (to
    /// open the existing edit form) without reaching into
    /// `PlanningRepository` directly.
    public func fetchRecurringPlannedActivity(byId recurringPlannedActivityId: RecurringPlannedActivityId) throws -> RecurringPlannedActivity? {
        try repository.fetchRecurringPlannedActivity(byId: recurringPlannedActivityId)
    }

    /// Sprint 1.2B, Priority 4: a thin passthrough — needed so a
    /// second "Log Activity" tap on an already-materialized recurring
    /// occurrence can recover the existing `PlannedActivity`
    /// (`acceptSuggestion` above already throws
    /// `.recurringOccurrenceAlreadyAccepted` rather than duplicating;
    /// this is how the caller then reaches the real, already-existing
    /// row instead of treating that as a hard failure).
    public func fetchPlannedActivity(forExternalSourceId externalSourceId: String, weekPlanId: WeekPlanId) throws -> PlannedActivity? {
        try repository.fetchPlannedActivity(forExternalSourceId: externalSourceId, weekPlanId: weekPlanId)
    }

    /// Sprint 1.2B, Priority 1 (recurring occurrence → Log Activity):
    /// materializes a recurring occurrence into a real `PlannedActivity`
    /// if it isn't one already, or deterministically resolves to the
    /// SAME existing `PlannedActivity` if it already was — repeated
    /// calls (e.g. the parent tapping "Log Activity" twice, or two
    /// screens racing to materialize the same occurrence) never create
    /// a duplicate. This is not new idempotency logic: `acceptSuggestion`
    /// already guards against a duplicate insert via the occurrence's
    /// own deterministic `externalSourceId` (see its own doc comment);
    /// this method only adds the recovery step — when that guard fires,
    /// fetch the row it's guarding instead of treating that as a hard
    /// failure the caller must handle. `occurrenceExternalSourceId` is
    /// `internal` to this module by design (an implementation detail of
    /// materialization identity, not something callers should compute
    /// themselves) — this method exists so a UI-layer caller never
    /// needs to.
    public func materializeOrFetchExisting(
        _ suggestion: RecurringActivitySuggestion,
        forWeekPlan weekPlanId: WeekPlanId
    ) throws -> PlannedActivity {
        do {
            return try acceptSuggestion(suggestion, forWeekPlan: weekPlanId)
        } catch PlanningServiceError.recurringOccurrenceAlreadyAccepted {
            let externalSourceId = RecurringPlannedActivity.occurrenceExternalSourceId(
                recurringPlannedActivityId: suggestion.recurringPlannedActivityId,
                occurrenceDate: suggestion.occurrenceDate,
                athleteId: suggestion.athleteId
            )
            guard let existing = try repository.fetchPlannedActivity(forExternalSourceId: externalSourceId, weekPlanId: weekPlanId) else {
                // The guard that threw .recurringOccurrenceAlreadyAccepted
                // just confirmed this row exists — this should be
                // unreachable, but surface the original error rather than
                // silently returning something invented if it somehow is.
                throw PlanningServiceError.recurringOccurrenceAlreadyAccepted
            }
            return existing
        }
    }

    /// S2.4: deletes a `PlannedActivity`, only while its `WeekPlan` is
    /// still draft — the same two existence/ownership guards
    /// `editPlannedActivity` already uses, plus the explicitly-requested
    /// draft-only restriction.
    ///
    /// A2: `deletedBy` attributes the resulting tombstone — required,
    /// not defaulted, matching how `WeekPlan.commit(committedBy:)`
    /// already requires an explicit actor rather than fabricating one.
    public func deletePlannedActivity(
        _ plannedActivityId: PlannedActivityId,
        expectedWeekPlanId weekPlanId: WeekPlanId,
        deletedBy: ActorId
    ) throws {
        guard let weekPlan = try repository.fetchWeekPlan(byId: weekPlanId) else {
            throw PlanningServiceError.weekPlanNotFound
        }
        guard weekPlan.status == .draft else {
            throw PlanningServiceError.weekPlanNotDraft
        }
        guard let activity = try repository.fetchPlannedActivity(byId: plannedActivityId) else {
            throw PlanningServiceError.plannedActivityNotFound
        }
        guard activity.weekPlanId == weekPlanId.rawValue else {
            throw PlanningServiceError.plannedActivityDoesNotBelongToWeekPlan
        }
        try repository.deletePlannedActivity(activity, deletedBy: deletedBy)
    }

    // MARK: - Recurring Planned Activities

    /// Creates a new recurring activity definition. Validation mirrors
    /// `RecurringPlannedActivity`'s own `precondition` bounds, the same
    /// way `Self.validate` already mirrors `PlannedActivity`'s — so
    /// invalid input is a catchable error here, not a crash.
    public func createRecurringPlannedActivity(
        athleteId: AthleteId,
        title: String,
        activityType: ActivityType,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        weekdays: [Weekday],
        startLocalTime: LocalTime? = nil,
        plannedDurationMinutes: Int? = nil,
        timeZoneId: TimeZoneId,
        location: String? = nil,
        effectiveStartDate: LocalDate,
        effectiveEndDate: LocalDate
    ) throws -> RecurringPlannedActivity {
        try Self.validateRecurringActivity(
            title: title,
            plannedDurationMinutes: plannedDurationMinutes,
            effectiveStartDate: effectiveStartDate,
            effectiveEndDate: effectiveEndDate,
            weekdays: weekdays
        )
        return try repository.insertRecurringPlannedActivity(
            athleteId: athleteId,
            title: title,
            activityType: activityType,
            sportId: sportId,
            categoryIds: categoryIds,
            weekdays: weekdays,
            startLocalTime: startLocalTime,
            plannedDurationMinutes: plannedDurationMinutes,
            timeZoneId: timeZoneId,
            location: location,
            effectiveStartDate: effectiveStartDate,
            effectiveEndDate: effectiveEndDate
        )
    }

    /// Edits an existing recurring activity definition in place.
    /// Editing it does not retroactively touch any `PlannedActivity`
    /// already accepted from an earlier occurrence — only future
    /// derivation (`deriveSuggestions`) sees the new values. Location
    /// (Sprint 1.2A) follows this exact same, already-established rule
    /// — no special Location-only synchronization behavior.
    @discardableResult
    public func editRecurringPlannedActivity(
        _ recurringPlannedActivityId: RecurringPlannedActivityId,
        title: String,
        activityType: ActivityType,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        weekdays: [Weekday],
        startLocalTime: LocalTime? = nil,
        plannedDurationMinutes: Int? = nil,
        timeZoneId: TimeZoneId,
        location: String? = nil,
        effectiveStartDate: LocalDate,
        effectiveEndDate: LocalDate
    ) throws -> RecurringPlannedActivity {
        guard let recurringActivity = try repository.fetchRecurringPlannedActivity(byId: recurringPlannedActivityId) else {
            throw PlanningServiceError.recurringPlannedActivityNotFound
        }
        try Self.validateRecurringActivity(
            title: title,
            plannedDurationMinutes: plannedDurationMinutes,
            effectiveStartDate: effectiveStartDate,
            effectiveEndDate: effectiveEndDate,
            weekdays: weekdays
        )
        recurringActivity.title = title
        recurringActivity.activityType = activityType
        recurringActivity.sportId = sportId?.rawValue
        recurringActivity.categoryIds = categoryIds.map(\.rawValue)
        recurringActivity.weekdays = weekdays
        recurringActivity.startLocalTime = startLocalTime
        recurringActivity.plannedDurationMinutes = plannedDurationMinutes
        recurringActivity.timeZoneId = timeZoneId
        recurringActivity.location = location
        recurringActivity.effectiveStartDate = effectiveStartDate
        recurringActivity.effectiveEndDate = effectiveEndDate
        recurringActivity.updatedAt = .now
        try repository.save()
        return recurringActivity
    }

    /// Enables or disables a recurring activity definition. A disabled
    /// definition produces no suggestions (see `deriveSuggestions`)
    /// until re-enabled; it is never deleted, and accepting one
    /// occurrence never disables the definition itself.
    public func setRecurringPlannedActivityEnabled(
        _ recurringPlannedActivityId: RecurringPlannedActivityId,
        isEnabled: Bool
    ) throws {
        guard let recurringActivity = try repository.fetchRecurringPlannedActivity(byId: recurringPlannedActivityId) else {
            throw PlanningServiceError.recurringPlannedActivityNotFound
        }
        try repository.setRecurringPlannedActivityEnabled(recurringActivity, isEnabled: isEnabled)
    }

    /// S2.4-style passthrough: UI code depends only on `PlanningService`.
    public func fetchRecurringPlannedActivities(forAthlete athleteId: AthleteId) throws -> [RecurringPlannedActivity] {
        try repository.fetchRecurringPlannedActivities(forAthlete: athleteId)
    }

    /// Derives this week's recurring-activity suggestions for the given
    /// `WeekPlan` — never persisted, computed fresh on every call.
    ///
    /// A suggestion is produced only when, for some day within the
    /// `WeekPlan`'s 7-day week (`weekStart` through `weekStart` +6,
    /// computed via `LocalDate.adding(days:)` — pure calendar
    /// arithmetic, never device-local `Date` math): the day's
    /// `LocalDate.weekday` is contained in the recurring definition's
    /// `weekdays` set (Sprint 1.2B: one or more weekdays, previously a
    /// single `Weekday`);
    /// the day falls within the definition's inclusive effective date
    /// range; the definition is enabled; and no `PlannedActivity`
    /// already exists in this `WeekPlan` for that exact occurrence
    /// (checked via the deterministic `externalSourceId` — see
    /// `RecurringPlannedActivity.occurrenceExternalSourceId`).
    ///
    /// Ordered deterministically (by occurrence date, then by
    /// recurring-activity id as a stable tiebreaker) so repeated calls
    /// with unchanged underlying data always return the same list in
    /// the same order.
    public func deriveSuggestions(forWeekPlan weekPlanId: WeekPlanId) throws -> [RecurringActivitySuggestion] {
        guard let weekPlan = try repository.fetchWeekPlan(byId: weekPlanId) else {
            throw PlanningServiceError.weekPlanNotFound
        }
        let athleteId = AthleteId(rawValue: weekPlan.athleteId)

        let recurringActivities = try repository.fetchRecurringPlannedActivities(forAthlete: athleteId).filter(\.isEnabled)
        guard !recurringActivities.isEmpty else { return [] }

        let existingActivities = try repository.fetchPlannedActivities(forWeekPlan: weekPlanId)
        let acceptedExternalSourceIds = Set(existingActivities.compactMap { activity -> String? in
            guard activity.externalSourceType == RecurringPlannedActivity.externalSourceType else { return nil }
            return activity.externalSourceId
        })

        let weekDates = (0..<7).map { weekPlan.weekStart.adding(days: $0) }

        var suggestions: [RecurringActivitySuggestion] = []
        for recurringActivity in recurringActivities {
            for date in weekDates {
                guard recurringActivity.weekdays.contains(date.weekday) else { continue }
                guard recurringActivity.effectiveStartDate <= date, date <= recurringActivity.effectiveEndDate else { continue }
                let externalSourceId = RecurringPlannedActivity.occurrenceExternalSourceId(
                    recurringPlannedActivityId: recurringActivity.recurringPlannedActivityId,
                    occurrenceDate: date,
                    athleteId: athleteId
                )
                guard !acceptedExternalSourceIds.contains(externalSourceId) else { continue }
                suggestions.append(
                    RecurringActivitySuggestion(
                        id: externalSourceId,
                        recurringPlannedActivityId: recurringActivity.recurringPlannedActivityId,
                        athleteId: athleteId,
                        occurrenceDate: date,
                        title: recurringActivity.title,
                        activityType: recurringActivity.activityType,
                        sportId: recurringActivity.sportId.map(SportId.init(rawValue:)),
                        categoryIds: recurringActivity.categoryIds.map(ActivityCategoryId.init(rawValue:)),
                        startLocalTime: recurringActivity.startLocalTime,
                        plannedDurationMinutes: recurringActivity.plannedDurationMinutes,
                        timeZoneId: recurringActivity.timeZoneId,
                        location: recurringActivity.location
                    )
                )
            }
        }

        return suggestions.sorted { lhs, rhs in
            if lhs.occurrenceDate != rhs.occurrenceDate {
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
            return lhs.recurringPlannedActivityId.rawValue.uuidString < rhs.recurringPlannedActivityId.rawValue.uuidString
        }
    }

    /// Sprint 1.1, P1 (Family Schedule missing recurring activities):
    /// `deriveSuggestions(forWeekPlan:)` above requires an existing
    /// `WeekPlan` — but a WeekPlan is only ever created when a parent
    /// actually opens that week's Weekly Plan screen
    /// (`getOrCreateWeekPlan`). A future week nobody has visited yet
    /// has no WeekPlan at all, so that method can't be used to preview
    /// recurring occurrences across a multi-week range like Family
    /// Schedule's. This is the same occurrence-matching logic
    /// (weekday match, effective-date-range match, already-materialized
    /// occurrences excluded), generalized to an arbitrary date range
    /// and not requiring any WeekPlan to pre-exist. Still excludes
    /// occurrences already materialized into a real `PlannedActivity`
    /// (checked per-week, only for weeks that do have a WeekPlan — a
    /// week with none can't have any materialized occurrences either).
    /// Returns unmaterialized suggestions only — a real
    /// `PlannedActivity` in the same range is returned separately by
    /// `TrainingPlanningCoordinationService`'s own range query; callers
    /// combine both, the same way Family Schedule needs to represent
    /// "planned for real" and "recurring but not yet accepted" as
    /// distinct row kinds rather than conflating them.
    public func deriveSuggestions(
        forAthlete athleteId: AthleteId,
        from startDate: LocalDate,
        through endDate: LocalDate,
        calendar: Calendar = .current
    ) throws -> [RecurringActivitySuggestion] {
        guard startDate <= endDate else { return [] }

        let recurringActivities = try repository.fetchRecurringPlannedActivities(forAthlete: athleteId).filter(\.isEnabled)
        guard !recurringActivities.isEmpty else { return [] }

        // Already-materialized occurrences, gathered across every week
        // that overlaps the range and genuinely has a WeekPlan — a week
        // with no WeekPlan has nothing materialized in it by
        // definition.
        var acceptedExternalSourceIds: Set<String> = []
        var weekStarts: Set<LocalDate> = []
        if let startDay = calendar.date(from: DateComponents(year: startDate.year, month: startDate.month, day: startDate.day)),
           let endDay = calendar.date(from: DateComponents(year: endDate.year, month: endDate.month, day: endDate.day)) {
            var cursor = startDay
            while cursor <= endDay {
                let cursorComponents = calendar.dateComponents([.year, .month, .day], from: cursor)
                let cursorDate = LocalDate(
                    year: cursorComponents.year ?? 1970,
                    month: cursorComponents.month ?? 1,
                    day: cursorComponents.day ?? 1
                )
                weekStarts.insert(cursorDate.startOfWeek)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }
        for weekStart in weekStarts {
            guard let weekPlan = try repository.fetchWeekPlan(forAthlete: athleteId, weekStart: weekStart) else { continue }
            let existingActivities = try repository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
            for activity in existingActivities {
                guard activity.externalSourceType == RecurringPlannedActivity.externalSourceType,
                      let externalSourceId = activity.externalSourceId else { continue }
                acceptedExternalSourceIds.insert(externalSourceId)
            }
        }

        var suggestions: [RecurringActivitySuggestion] = []
        for recurringActivity in recurringActivities {
            var date = startDate
            while date <= endDate {
                defer { date = date.adding(days: 1) }
                guard recurringActivity.weekdays.contains(date.weekday) else { continue }
                guard recurringActivity.effectiveStartDate <= date, date <= recurringActivity.effectiveEndDate else { continue }
                let externalSourceId = RecurringPlannedActivity.occurrenceExternalSourceId(
                    recurringPlannedActivityId: recurringActivity.recurringPlannedActivityId,
                    occurrenceDate: date,
                    athleteId: athleteId
                )
                guard !acceptedExternalSourceIds.contains(externalSourceId) else { continue }
                suggestions.append(
                    RecurringActivitySuggestion(
                        id: externalSourceId,
                        recurringPlannedActivityId: recurringActivity.recurringPlannedActivityId,
                        athleteId: athleteId,
                        occurrenceDate: date,
                        title: recurringActivity.title,
                        activityType: recurringActivity.activityType,
                        sportId: recurringActivity.sportId.map(SportId.init(rawValue:)),
                        categoryIds: recurringActivity.categoryIds.map(ActivityCategoryId.init(rawValue:)),
                        startLocalTime: recurringActivity.startLocalTime,
                        plannedDurationMinutes: recurringActivity.plannedDurationMinutes,
                        timeZoneId: recurringActivity.timeZoneId,
                        location: recurringActivity.location
                    )
                )
            }
        }

        return suggestions.sorted { lhs, rhs in
            if lhs.occurrenceDate != rhs.occurrenceDate {
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
            return lhs.recurringPlannedActivityId.rawValue.uuidString < rhs.recurringPlannedActivityId.rawValue.uuidString
        }
    }

    /// Accepts one suggestion, creating exactly one `PlannedActivity` in
    /// the given `WeekPlan`. `suggestion` is treated as untrusted,
    /// caller-suppliable presentation data, not authoritative domain
    /// input — it could be stale (the definition changed since it was
    /// derived) or outright hand-constructed, since
    /// `RecurringActivitySuggestion` is a public, freely-constructible
    /// value type. Only two of its fields are trusted as *lookup keys*
    /// (`recurringPlannedActivityId`, used to re-fetch the actual
    /// definition; `occurrenceDate`, itself independently re-validated
    /// below) — every descriptive field (title, type, sport,
    /// categories, time, duration, time zone) is ignored in favor of
    /// the freshly-fetched `RecurringPlannedActivity`'s own current
    /// values, and `athleteId` is checked against, never trusted over,
    /// the `WeekPlan`'s own athlete.
    ///
    /// Validated in order, each against freshly-fetched, authoritative
    /// state — never against anything the suggestion itself asserts:
    /// the `WeekPlan` exists and is `.draft`; the referenced
    /// `RecurringPlannedActivity` exists; that definition's own athlete
    /// matches the `WeekPlan`'s athlete; the suggestion's claimed
    /// athlete also matches the `WeekPlan`'s athlete; the occurrence
    /// date falls within the `WeekPlan`'s own 7-day week; the
    /// occurrence date's actual weekday matches the definition's
    /// weekday; the occurrence date falls within the definition's own
    /// current inclusive effective range; the definition is currently
    /// enabled; and, using an occurrence identity recomputed here (not
    /// `suggestion.id`), that this occurrence hasn't already been
    /// accepted.
    @discardableResult
    public func acceptSuggestion(
        _ suggestion: RecurringActivitySuggestion,
        forWeekPlan weekPlanId: WeekPlanId
    ) throws -> PlannedActivity {
        try acceptSuggestion(suggestion, forWeekPlan: weekPlanId, saveOverride: nil)
    }

    /// Test-only seam — not `public`, reachable only via `@testable
    /// import`, forwarded into `PlanningRepository.insertPlannedActivity`'s
    /// own internal seam. Every production call site goes through the
    /// public overload above, which always passes `nil`.
    func acceptSuggestion(
        _ suggestion: RecurringActivitySuggestion,
        forWeekPlan weekPlanId: WeekPlanId,
        saveOverride: (() throws -> Void)?
    ) throws -> PlannedActivity {
        guard let weekPlan = try repository.fetchWeekPlan(byId: weekPlanId) else {
            throw PlanningServiceError.weekPlanNotFound
        }
        guard weekPlan.status == .draft else {
            throw PlanningServiceError.weekPlanNotDraft
        }
        let weekPlanAthleteId = AthleteId(rawValue: weekPlan.athleteId)

        guard let recurringActivity = try repository.fetchRecurringPlannedActivity(byId: suggestion.recurringPlannedActivityId) else {
            throw PlanningServiceError.recurringPlannedActivityNotFound
        }

        // Neither the definition's own recorded athlete, nor the
        // suggestion's own claimed athlete, is trusted without
        // checking both against the WeekPlan's actual athlete — the
        // one fact here that cannot be a stale or tampered value,
        // since it comes from the WeekPlan just fetched above, not
        // from the caller-supplied suggestion.
        guard recurringActivity.athleteId == weekPlan.athleteId else {
            throw PlanningServiceError.recurringOccurrenceAthleteMismatch
        }
        guard suggestion.athleteId == weekPlanAthleteId else {
            throw PlanningServiceError.recurringOccurrenceAthleteMismatch
        }

        let weekEnd = weekPlan.weekStart.adding(days: 6)
        guard weekPlan.weekStart <= suggestion.occurrenceDate, suggestion.occurrenceDate <= weekEnd else {
            throw PlanningServiceError.recurringOccurrenceOutsideWeekPlan
        }

        guard recurringActivity.weekdays.contains(suggestion.occurrenceDate.weekday) else {
            throw PlanningServiceError.recurringOccurrenceWeekdayMismatch
        }

        guard recurringActivity.effectiveStartDate <= suggestion.occurrenceDate,
              suggestion.occurrenceDate <= recurringActivity.effectiveEndDate else {
            throw PlanningServiceError.recurringOccurrenceOutsideEffectiveRange
        }

        guard recurringActivity.isEnabled else {
            throw PlanningServiceError.recurringPlannedActivityDisabled
        }

        // Recomputed from validated, authoritative inputs — never
        // trusted from `suggestion.id`.
        let externalSourceId = RecurringPlannedActivity.occurrenceExternalSourceId(
            recurringPlannedActivityId: recurringActivity.recurringPlannedActivityId,
            occurrenceDate: suggestion.occurrenceDate,
            athleteId: weekPlanAthleteId
        )

        // Defensive re-check against the recomputed identity — this,
        // not whatever the caller's own last `deriveSuggestions` call
        // showed, is what actually makes a duplicate accept
        // impossible, not just unlikely.
        guard try repository.fetchPlannedActivity(forExternalSourceId: externalSourceId, weekPlanId: weekPlanId) == nil else {
            throw PlanningServiceError.recurringOccurrenceAlreadyAccepted
        }

        // The definition's own CURRENT values are authoritative for
        // every descriptive field — never the suggestion's, which may
        // be stale relative to an edit made after it was derived.
        return try repository.insertPlannedActivity(
            weekPlanId: weekPlanId,
            athleteId: weekPlanAthleteId,
            activityType: recurringActivity.activityType,
            title: recurringActivity.title,
            localDate: suggestion.occurrenceDate,
            timeZoneId: recurringActivity.timeZoneId,
            sportId: recurringActivity.sportId.map(SportId.init(rawValue:)),
            categoryIds: recurringActivity.categoryIds.map(ActivityCategoryId.init(rawValue:)),
            startLocalTime: recurringActivity.startLocalTime,
            plannedDurationMinutes: recurringActivity.plannedDurationMinutes,
            externalSourceId: externalSourceId,
            externalSourceType: RecurringPlannedActivity.externalSourceType,
            location: recurringActivity.location,
            saveOverride: saveOverride
        )
    }

    /// Mirrors `Self.validate`'s existing role for `PlannedActivity`:
    /// `RecurringPlannedActivity`'s own initializer preconditions
    /// already enforce these bounds on create, but `editRecurringPlannedActivity`
    /// mutates an already-constructed instance in place, so this lets
    /// that path reject the same invalid input with a catchable error
    /// instead of a crash.
    private static func validateRecurringActivity(
        title: String,
        plannedDurationMinutes: Int?,
        effectiveStartDate: LocalDate,
        effectiveEndDate: LocalDate,
        weekdays: [Weekday]
    ) throws {
        guard (1...120).contains(title.count) else {
            throw PlanningServiceError.invalidField("title must be 1-120 characters")
        }
        if let duration = plannedDurationMinutes {
            guard (1...1440).contains(duration) else {
                throw PlanningServiceError.invalidField("plannedDurationMinutes must be 1-1440")
            }
        }
        guard effectiveStartDate <= effectiveEndDate else {
            throw PlanningServiceError.invalidField("effectiveStartDate must be on or before effectiveEndDate")
        }
        // Sprint 1.2B: at least one weekday is required — surfaced here
        // as a normal, catchable validation error (the same way every
        // other field on this form already is), rather than only
        // relying on RecurringPlannedActivity.init's own precondition,
        // which would crash instead of showing the existing error
        // presentation.
        guard !weekdays.isEmpty else {
            throw PlanningServiceError.invalidField("at least one weekday is required")
        }
    }
}
