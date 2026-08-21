import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrPlanningDomain

/// S2.4: backs `WeeklyPlanningView`. Every state-changing action goes
/// through `PlanningService` — this type holds no business rules of its
/// own, only orchestrates calls and turns thrown errors into a single
/// user-facing `errorMessage`, matching the same pattern
/// `CreateFamilyViewModel` already established in Sprint 1.
@MainActor
@Observable
public final class WeeklyPlanningViewModel {
    public private(set) var weekPlan: WeekPlan?
    public private(set) var activities: [PlannedActivity] = []
    public private(set) var errorMessage: String?

    // Add-activity form fields.
    public var newActivityTitle: String = ""
    public var newActivityDate: Date = .now
    public var newActivityType: ActivityType = .individualTraining
    public var newActivityLocation: String = ""
    public var newActivityHasStartTime: Bool = false
    public var newActivityStartTime: Date = .now
    /// Planned/Logged Activity lifecycle consistency cleanup: planned
    /// duration is optional at the domain level
    /// (`PlannedActivity.plannedDurationMinutes: Int?`), but the user
    /// must still be able to enter it wherever a `PlannedActivity` can
    /// be created — the same "Has X" Toggle + `DurationPickerView`
    /// pattern `ActivityDetailViewModel.editHasDuration`/`editDurationMinutes`
    /// (Edit Planned Activity) and `recurringFormHasDuration`/
    /// `recurringFormDurationMinutes` (recurring activities) already
    /// establish for this exact optional-duration shape — reused here,
    /// not a second representation.
    public var newActivityHasDuration: Bool = false
    public var newActivityDurationMinutes: Int = 60
    /// Post-mutation navigation and stale-state consistency audit
    /// (Issue B): increments on every SUCCESSFUL `addActivity()` only —
    /// never on validation failure or persistence failure. Same "simple
    /// counter, not a Bool" shape as `DailyTrainingViewModel.successfulLogTrigger`
    /// (its own doc comment explains why: `.onChange` must fire on
    /// every success, not only a false->true transition, so a second
    /// add in the same session still triggers the view's own
    /// scroll-to-top). The "Add activity" form here is inline on this
    /// same screen, exactly like Daily Training's own "Log an activity"
    /// section — there is no separate screen to dismiss, so the fix is
    /// the same one already established there: an explicit signal the
    /// view uses to scroll back to the top of the list, not a new
    /// navigation architecture.
    public private(set) var successfulAddActivityTrigger: Int = 0

    /// Derived fresh on every load/mutation, never persisted. Reflects
    /// `dismissedSuggestionIds` below — a dismissed occurrence is
    /// filtered out of this list, but only for this ViewModel instance.
    public private(set) var recurringSuggestions: [RecurringActivitySuggestion] = []

    /// Session-only dismissal state. Deliberately never persisted, and
    /// deliberately not a new persisted model — a fresh ViewModel
    /// instance (e.g. after "reloading from persistence") starts with
    /// this empty, so a previously-dismissed occurrence appears again.
    private var dismissedSuggestionIds: Set<String> = []

    /// All recurring definitions for this athlete (enabled and
    /// disabled), for the management flow's own listing.
    public private(set) var recurringPlannedActivities: [RecurringPlannedActivity] = []

    // Recurring-activity management form fields.
    public var recurringFormTitle: String = ""
    public var recurringFormActivityType: ActivityType = .individualTraining
    /// Sprint 1.2B: one or more weekdays — replaces the previous
    /// single `recurringFormWeekday: Weekday`. `Set<Weekday>` (not
    /// an array) since UI multi-select has no meaningful order of
    /// its own; `RecurringPlannedActivity.init` itself sorts and
    /// dedupes when this is finally passed through, so this being a
    /// Set here changes nothing about the persisted result.
    public var recurringFormWeekdays: Set<Weekday> = [.monday]
    public var recurringFormHasStartTime: Bool = false
    public var recurringFormStartTime: Date = .now
    public var recurringFormHasDuration: Bool = false
    public var recurringFormDurationMinutes: Int = 60
    public var recurringFormStartDate: Date = .now
    public var recurringFormEndDate: Date = .now
    public var recurringFormLocation: String = ""

    private let service: PlanningService
    /// Shared, athlete-scoped presentation invalidation. Planning
    /// remains the canonical mutation owner; this only tells already-
    /// live read models to refetch after a successful mutation.
    private let activityChangeBroadcaster: AthleteActivityChangeBroadcaster?
    public let athleteId: AthleteId
    private let committedByActorId: ActorId
    public private(set) var weekStart: LocalDate

    public init(
        service: PlanningService,
        athleteId: AthleteId,
        committedByActorId: ActorId,
        weekStart: LocalDate? = nil,
        activityChangeBroadcaster: AthleteActivityChangeBroadcaster? = nil
    ) {
        self.service = service
        self.athleteId = athleteId
        self.committedByActorId = committedByActorId
        self.weekStart = weekStart ?? Self.currentWeekStart()
        self.activityChangeBroadcaster = activityChangeBroadcaster
    }

    /// Area 4 (Parent Time Navigation package): switches to a
    /// different Monday–Sunday week and reloads that week's plan —
    /// the same `loadOrCreateWeekPlan()` this type already uses for
    /// its initial load, not a second loading path. The canonical
    /// Monday–Sunday week model itself is unchanged; this only lets
    /// the same, already-established mechanism be re-entered for a
    /// different week.
    public func switchToWeek(_ newWeekStart: LocalDate) {
        weekStart = newWeekStart
        loadOrCreateWeekPlan()
    }

    /// Fix: this used to duplicate `TrainingPlanningCoordinationService.weekStart`'s
    /// own (formerly locale-dependent, now-fixed) computation, with a
    /// doc comment incorrectly framing week boundaries as "not a
    /// product business rule" — Vǫxtr's Monday → Sunday week IS a
    /// product decision, not a device default. Now delegates to that
    /// one canonical implementation instead of recomputing the same
    /// thing a second way.
    public static func currentWeekStart(referenceDate: Date = .now, calendar: Calendar = .current) -> LocalDate {
        TrainingPlanningCoordinationService.weekStart(referenceDate: referenceDate, calendar: calendar)
    }

    public var isCommitted: Bool { weekPlan?.status == .committed }
    public var statusLabel: String {
        isCommitted ? PlanningStrings.committedStatus : PlanningStrings.draftStatus
    }

    /// Reversibility principle (Reopen Planning): offered ONLY for a
    /// committed CURRENT or FUTURE week — never a historical one. This
    /// screen only ever shows one week at a time (`weekStart`, switched
    /// via `switchToWeek(_:)`), so "the current/future week" is simply
    /// "not before the real current week," using the SAME canonical
    /// `currentWeekStart()` every other current-week check in this app
    /// already uses. Historical weeks are deliberately left under
    /// existing historical/read behavior — this task does not invent
    /// historical-plan editing semantics.
    public var canReopenPlanning: Bool {
        isCommitted && weekStart >= Self.currentWeekStart()
    }

    /// Loads the athlete's current-week plan, creating a draft if none
    /// exists yet, then loads its activities and recurring-activity
    /// suggestions. Call once when the view appears.
    public func loadOrCreateWeekPlan() {
        errorMessage = nil
        // Issue 3 fix: clear dependent state BEFORE attempting the new
        // load, consistent with the same principle applied to
        // `WeeklyHistoryViewModel.load()` — if getOrCreateWeekPlan
        // succeeds but a later step throws, the previous week's
        // activities/suggestions must not remain displayed under the
        // new week's heading.
        weekPlan = nil
        activities = []
        recurringSuggestions = []
        do {
            let plan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
            weekPlan = plan
            try reloadActivities(for: plan)
            try reloadSuggestions(for: plan)
        } catch {
            errorMessage = PlanningStrings.genericServiceError
        }
    }

    public func addActivity() {
        guard let weekPlan else { return }
        errorMessage = nil
        let trimmedTitle = newActivityTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: newActivityDate)
        let localDate = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        do {
            _ = try service.addPlannedActivity(
                toWeekPlan: weekPlan.weekPlanId,
                athleteId: athleteId,
                activityType: newActivityType,
                title: trimmedTitle,
                localDate: localDate,
                timeZoneId: TimeZoneId(rawValue: TimeZone.current.identifier),
                startLocalTime: newActivityHasStartTime ? Self.localTime(from: newActivityStartTime) : nil,
                plannedDurationMinutes: newActivityHasDuration ? newActivityDurationMinutes : nil,
                location: newActivityLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newActivityLocation
            )
            newActivityTitle = ""
            newActivityDate = .now
            newActivityLocation = ""
            newActivityHasStartTime = false
            newActivityStartTime = .now
            newActivityHasDuration = false
            newActivityDurationMinutes = 60
            activityChangeBroadcaster?.activityChanged(for: athleteId)
            try reloadActivities(for: weekPlan)
            successfulAddActivityTrigger += 1
        } catch let error as PlanningServiceError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = PlanningStrings.genericServiceError
        }
    }

    public func editActivity(
        _ activity: PlannedActivity,
        title: String,
        localDate: LocalDate,
        activityType: ActivityType
    ) {
        guard let weekPlan else { return }
        errorMessage = nil
        do {
            _ = try service.editPlannedActivity(
                activity.plannedActivityId,
                expectedWeekPlanId: weekPlan.weekPlanId,
                activityType: activityType,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                localDate: localDate,
                timeZoneId: activity.timeZoneId
            )
            activityChangeBroadcaster?.activityChanged(for: athleteId)
            try reloadActivities(for: weekPlan)
        } catch let error as PlanningServiceError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = PlanningStrings.genericServiceError
        }
    }

    /// Requirement: "Allow deleting a planned activity only while the
    /// week is draft." The actual enforcement lives in
    /// `PlanningService.deletePlannedActivity` — this method doesn't
    /// duplicate that check, it just surfaces whatever the service
    /// decides, same as every other action here.
    public func deleteActivity(_ activity: PlannedActivity) {
        guard let weekPlan else { return }
        errorMessage = nil
        do {
            try service.deletePlannedActivity(
                activity.plannedActivityId,
                expectedWeekPlanId: weekPlan.weekPlanId,
                deletedBy: committedByActorId
            )
            activityChangeBroadcaster?.activityChanged(for: athleteId)
            try reloadActivities(for: weekPlan)
        } catch let error as PlanningServiceError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = PlanningStrings.genericServiceError
        }
    }

    public func commit() {
        guard let weekPlan else { return }
        errorMessage = nil
        do {
            let committed = try service.commitWeekPlan(
                weekPlan.weekPlanId,
                expectedRevision: weekPlan.revision,
                committedBy: committedByActorId
            )
            self.weekPlan = committed
        } catch is WeekPlanConflictError {
            errorMessage = PlanningStrings.genericServiceError
        } catch let error as PlanningServiceError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = PlanningStrings.genericServiceError
        }
    }

    /// Reversibility principle (Reopen Planning): the exact mirror of
    /// `commit()` above, for the reverse transition. Reassigns `self.weekPlan`
    /// to the SAME entity `service.reopenWeekPlan` returns (never
    /// reloaded/reconstructed from a fresh fetch, never a different
    /// object) — `isCommitted`/`canReopenPlanning` recompute immediately
    /// from that reassignment since both are `@Observable`-tracked
    /// computed properties, so the currently-selected week becomes
    /// editable without navigating away or waiting on `.onAppear`.
    /// `activities` is untouched — this call never mutates
    /// `PlannedActivity` rows, so there is nothing to reload.
    ///
    /// Review follow-up: `canReopenPlanning` above is UI presentation
    /// gating only, not the authoritative check — passes the SAME
    /// canonical `Self.currentWeekStart()` `canReopenPlanning` itself
    /// reads through to `service.reopenWeekPlan`, which forwards it to
    /// `WeekPlan.reopen` — the actual, non-bypassable enforcement now
    /// lives at the domain boundary; this call site merely supplies the
    /// one wall-clock read the domain itself is never allowed to make.
    public func reopenPlanning() {
        guard let weekPlan else { return }
        errorMessage = nil
        do {
            let reopened = try service.reopenWeekPlan(
                weekPlan.weekPlanId,
                expectedRevision: weekPlan.revision,
                reopenedBy: committedByActorId,
                currentWeekStart: Self.currentWeekStart()
            )
            self.weekPlan = reopened
        } catch is WeekPlanConflictError {
            errorMessage = PlanningStrings.genericServiceError
        } catch let error as PlanningServiceError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = PlanningStrings.genericServiceError
        }
    }

    // MARK: - Recurring suggestions

    /// Accepts one suggestion, turning it into a real `PlannedActivity`
    /// in the current `WeekPlan`, then removes it from
    /// `recurringSuggestions`. Rejected by the service (surfaced as
    /// `errorMessage`) if the `WeekPlan` is no longer draft — the view
    /// also hides this whole section once committed, matching how
    /// edit/delete are already hidden, but the actual enforcement lives
    /// in `PlanningService`, not here.
    public func acceptSuggestion(_ suggestion: RecurringActivitySuggestion) {
        guard let weekPlan else { return }
        errorMessage = nil
        do {
            _ = try service.acceptSuggestion(suggestion, forWeekPlan: weekPlan.weekPlanId)
            activityChangeBroadcaster?.activityChanged(for: athleteId)
            try reloadActivities(for: weekPlan)
            try reloadSuggestions(for: weekPlan)
        } catch let error as PlanningServiceError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = PlanningStrings.genericServiceError
        }
    }

    /// Removes one suggestion from `recurringSuggestions` for the
    /// remainder of this ViewModel's lifetime — session-only, never
    /// persisted, and never touches the recurring definition itself.
    public func dismissSuggestion(_ suggestion: RecurringActivitySuggestion) {
        dismissedSuggestionIds.insert(suggestion.id)
        recurringSuggestions.removeAll { $0.id == suggestion.id }
    }

    private func reloadSuggestions(for weekPlan: WeekPlan) throws {
        let derived = try service.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        recurringSuggestions = derived.filter { !dismissedSuggestionIds.contains($0.id) }
    }

    // MARK: - Recurring activity management

    public func loadRecurringActivities() {
        errorMessage = nil
        do {
            recurringPlannedActivities = try service.fetchRecurringPlannedActivities(forAthlete: athleteId)
        } catch {
            errorMessage = PlanningStrings.genericServiceError
        }
    }

    /// Returns whether creation succeeded, so the presenting view can
    /// dismiss only on success — on failure the form must stay open
    /// with `errorMessage` set and the entered values untouched (this
    /// method never resets the form on the failure path, only on
    /// success).
    @discardableResult
    public func createRecurringActivity() -> Bool {
        errorMessage = nil
        let trimmedTitle = recurringFormTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try service.createRecurringPlannedActivity(
                athleteId: athleteId,
                title: trimmedTitle,
                activityType: recurringFormActivityType,
                weekdays: Array(recurringFormWeekdays),
                startLocalTime: recurringFormHasStartTime ? Self.localTime(from: recurringFormStartTime) : nil,
                plannedDurationMinutes: recurringFormHasDuration ? recurringFormDurationMinutes : nil,
                timeZoneId: TimeZoneId(rawValue: TimeZone.current.identifier),
                location: recurringFormLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : recurringFormLocation,
                effectiveStartDate: Self.localDate(from: recurringFormStartDate),
                effectiveEndDate: Self.localDate(from: recurringFormEndDate)
            )
            resetRecurringForm()
            loadRecurringActivities()
            refreshSuggestionsIfLoaded()
            return true
        } catch let error as PlanningServiceError {
            errorMessage = Self.message(for: error)
            return false
        } catch {
            errorMessage = PlanningStrings.genericServiceError
            return false
        }
    }

    /// Returns whether the edit succeeded, so the presenting view can
    /// dismiss only on success — same rationale as
    /// `createRecurringActivity`'s own doc comment.
    @discardableResult
    public func editRecurringActivity(_ recurringActivity: RecurringPlannedActivity) -> Bool {
        errorMessage = nil
        let trimmedTitle = recurringFormTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try service.editRecurringPlannedActivity(
                recurringActivity.recurringPlannedActivityId,
                title: trimmedTitle,
                activityType: recurringFormActivityType,
                weekdays: Array(recurringFormWeekdays),
                startLocalTime: recurringFormHasStartTime ? Self.localTime(from: recurringFormStartTime) : nil,
                plannedDurationMinutes: recurringFormHasDuration ? recurringFormDurationMinutes : nil,
                timeZoneId: recurringActivity.timeZoneId,
                location: recurringFormLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : recurringFormLocation,
                effectiveStartDate: Self.localDate(from: recurringFormStartDate),
                effectiveEndDate: Self.localDate(from: recurringFormEndDate)
            )
            resetRecurringForm()
            loadRecurringActivities()
            refreshSuggestionsIfLoaded()
            return true
        } catch let error as PlanningServiceError {
            errorMessage = Self.message(for: error)
            return false
        } catch {
            errorMessage = PlanningStrings.genericServiceError
            return false
        }
    }

    public func toggleRecurringActivityEnabled(_ recurringActivity: RecurringPlannedActivity) {
        errorMessage = nil
        do {
            try service.setRecurringPlannedActivityEnabled(
                recurringActivity.recurringPlannedActivityId,
                isEnabled: !recurringActivity.isEnabled
            )
            loadRecurringActivities()
            refreshSuggestionsIfLoaded()
        } catch let error as PlanningServiceError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = PlanningStrings.genericServiceError
        }
    }

    /// Populates the management form fields from an existing recurring
    /// activity, so the edit sheet opens pre-filled.
    public func beginEditingRecurringActivity(_ recurringActivity: RecurringPlannedActivity) {
        recurringFormTitle = recurringActivity.title ?? ""
        recurringFormActivityType = recurringActivity.activityType
        recurringFormWeekdays = Set(recurringActivity.weekdays)
        if let startLocalTime = recurringActivity.startLocalTime {
            recurringFormHasStartTime = true
            recurringFormStartTime = Calendar.current.date(
                from: DateComponents(hour: startLocalTime.hour, minute: startLocalTime.minute)
            ) ?? .now
        } else {
            recurringFormHasStartTime = false
        }
        if let duration = recurringActivity.plannedDurationMinutes {
            recurringFormHasDuration = true
            recurringFormDurationMinutes = duration
        } else {
            recurringFormHasDuration = false
        }
        recurringFormStartDate = Self.date(from: recurringActivity.effectiveStartDate)
        recurringFormEndDate = Self.date(from: recurringActivity.effectiveEndDate)
        recurringFormLocation = recurringActivity.location ?? ""
    }

    public func resetRecurringForm() {
        recurringFormTitle = ""
        recurringFormActivityType = .individualTraining
        recurringFormWeekdays = [.monday]
        recurringFormHasStartTime = false
        recurringFormStartTime = .now
        recurringFormHasDuration = false
        recurringFormDurationMinutes = 60
        recurringFormStartDate = .now
        recurringFormEndDate = .now
        recurringFormLocation = ""
    }

    /// Best-effort refresh after a management action — deliberately
    /// swallows failure (`try?`) rather than surfacing it as
    /// `errorMessage`, since the management action itself already
    /// succeeded by the time this runs; a stale suggestion list is a
    /// much smaller problem than overwriting that success with a
    /// misleading error.
    private func refreshSuggestionsIfLoaded() {
        guard let weekPlan else { return }
        try? reloadSuggestions(for: weekPlan)
    }

    private static func localTime(from date: Date) -> LocalTime {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return LocalTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    private static func localDate(from date: Date) -> LocalDate {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    private static func date(from localDate: LocalDate) -> Date {
        Calendar.current.date(from: DateComponents(year: localDate.year, month: localDate.month, day: localDate.day)) ?? .now
    }

    private func reloadActivities(for weekPlan: WeekPlan) throws {
        activities = try service.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
    }

    /// Called by the canonical activity-detail flow after its Planning
    /// edit/delete succeeds. Invalidates only this athlete's live
    /// presentation caches and reloads this screen from Planning truth.
    public func refreshAfterActivityDetailMutation() {
        activityChangeBroadcaster?.activityChanged(for: athleteId)
        loadOrCreateWeekPlan()
    }

    private static func message(for error: PlanningServiceError) -> String {
        switch error {
        case .weekPlanNotFound:
            return PlanningStrings.weekPlanNotFoundError
        case .weekPlanNotDraft:
            return PlanningStrings.weekPlanNotDraftError
        case .invalidField:
            return PlanningStrings.activityTitleRequired
        case .plannedActivityNotFound, .plannedActivityDoesNotBelongToWeekPlan,
             .recurringPlannedActivityNotFound, .recurringOccurrenceAlreadyAccepted,
             .recurringOccurrenceAthleteMismatch, .recurringOccurrenceOutsideWeekPlan,
             .recurringOccurrenceWeekdayMismatch, .recurringOccurrenceOutsideEffectiveRange,
             .recurringPlannedActivityDisabled:
            return PlanningStrings.genericServiceError
        }
    }
}
