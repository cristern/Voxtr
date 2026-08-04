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
    public var recurringFormWeekday: Weekday = .monday
    public var recurringFormHasStartTime: Bool = false
    public var recurringFormStartTime: Date = .now
    public var recurringFormHasDuration: Bool = false
    public var recurringFormDurationMinutes: Int = 60
    public var recurringFormStartDate: Date = .now
    public var recurringFormEndDate: Date = .now

    private let service: PlanningService
    private let athleteId: AthleteId
    private let committedByActorId: ActorId
    private let weekStart: LocalDate

    public init(
        service: PlanningService,
        athleteId: AthleteId,
        committedByActorId: ActorId,
        weekStart: LocalDate? = nil
    ) {
        self.service = service
        self.athleteId = athleteId
        self.committedByActorId = committedByActorId
        self.weekStart = weekStart ?? Self.currentWeekStart()
    }

    /// Start of the calendar week containing today, per the device's
    /// own calendar — not a product business rule, the same kind of
    /// device-provided default `CreateFamilyViewModel` already uses for
    /// time zone.
    public static func currentWeekStart(referenceDate: Date = .now, calendar: Calendar = .current) -> LocalDate {
        let start = calendar.dateInterval(of: .weekOfYear, for: referenceDate)?.start ?? referenceDate
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        return LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    public var isCommitted: Bool { weekPlan?.status == .committed }
    public var statusLabel: String {
        isCommitted ? PlanningStrings.committedStatus : PlanningStrings.draftStatus
    }

    /// Loads the athlete's current-week plan, creating a draft if none
    /// exists yet, then loads its activities and recurring-activity
    /// suggestions. Call once when the view appears.
    public func loadOrCreateWeekPlan() {
        errorMessage = nil
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
                timeZoneId: TimeZoneId(rawValue: TimeZone.current.identifier)
            )
            newActivityTitle = ""
            newActivityDate = .now
            try reloadActivities(for: weekPlan)
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
                weekday: recurringFormWeekday,
                startLocalTime: recurringFormHasStartTime ? Self.localTime(from: recurringFormStartTime) : nil,
                plannedDurationMinutes: recurringFormHasDuration ? recurringFormDurationMinutes : nil,
                timeZoneId: TimeZoneId(rawValue: TimeZone.current.identifier),
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
                weekday: recurringFormWeekday,
                startLocalTime: recurringFormHasStartTime ? Self.localTime(from: recurringFormStartTime) : nil,
                plannedDurationMinutes: recurringFormHasDuration ? recurringFormDurationMinutes : nil,
                timeZoneId: recurringActivity.timeZoneId,
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
        recurringFormTitle = recurringActivity.title
        recurringFormActivityType = recurringActivity.activityType
        recurringFormWeekday = recurringActivity.weekday
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
    }

    public func resetRecurringForm() {
        recurringFormTitle = ""
        recurringFormActivityType = .individualTraining
        recurringFormWeekday = .monday
        recurringFormHasStartTime = false
        recurringFormStartTime = .now
        recurringFormHasDuration = false
        recurringFormDurationMinutes = 60
        recurringFormStartDate = .now
        recurringFormEndDate = .now
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
