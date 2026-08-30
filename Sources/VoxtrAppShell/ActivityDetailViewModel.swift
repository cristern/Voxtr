import Foundation
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrNotificationsDomain

/// Sprint 1 (Daily Use Foundation), Part 3. The ONE Activity Detail
/// screen every planned activity opens into, regardless of entry point
/// (Family Home, Athlete Overview, Weekly Plan). Backs edit/delete
/// (delegating entirely to `PlanningService`'s already-existing
/// methods — no new validation or business rule is added here) and
/// hosts the hand-off into logging (Part 4).
@MainActor
@Observable
public final class ActivityDetailViewModel {
    public private(set) var activity: PlannedActivity
    public private(set) var isCompleted: Bool
    public private(set) var errorMessage: String?
    public private(set) var isDeleted: Bool = false
    /// VX-022 closeout: the exact `LoggedActivity` this `PlannedActivity`
    /// resolved to, if any — resolved by `ActivityDetailViewLoader` via
    /// `TrainingReflectionCoordinationService.loggedActivityDetail(forPlannedActivity:)`
    /// before this view model is constructed, the same "small, local
    /// loading step" pattern already used for `isWeekPlanDraft`.
    /// Planned/Logged Activity lifecycle consistency cleanup: now
    /// `private(set)`, not `let` — `cancelActivity()` and
    /// `saveLoggedActivityEdit()` update it in place after a successful
    /// mutation, so this screen reflects the new canonical state
    /// immediately without requiring a reopen, the same "explicit
    /// success signal, not a stale snapshot" principle
    /// `onActivityLogged` already establishes for the screens above
    /// this one.
    public private(set) var loggedActivity: LoggedActivity?
    /// The `ActivityReflection` linked to `loggedActivity` above, if
    /// one exists — raw/unfiltered; `formValue` below applies the
    /// existing privacy gate before exposing its content. Also now
    /// `private(set)`, for the same reason as `loggedActivity` above.
    private(set) var activityReflection: ActivityReflection?

    // Edit form fields — prefilled from `activity` on open, matching
    // WeeklyPlanningView's own established edit-sheet convention.
    public var editTitle: String = ""
    public var editSportId: SportId?
    public var editDate: Date = .now
    public var editActivityType: ActivityType = .individualTraining
    public var editStartTime: Date = .now
    public var editHasStartTime: Bool = false
    public var editDurationMinutes: Int = 60
    public var editHasDuration: Bool = false
    public var editNotes: String = ""
    public var editLocation: String = ""

    /// Planned/Logged Activity lifecycle consistency cleanup (Edit
    /// Logged Activity -> RPE + Form): prefilled from the exact
    /// canonical values this screen already displays read-only (see
    /// `perceivedExertion`/`formValue` below) — never re-derived or
    /// inferred separately.
    public var editLoggedPerceivedExertion: Int?
    public var editLoggedSessionForm: Int?
    /// Review follow-up: actual duration is canonical training truth,
    /// required at initial logging for Completed/PartiallyCompleted —
    /// without a correction path, a data-entry mistake would be
    /// permanently uncorrectable. Prefilled from `loggedActivity.durationMinutes`
    /// (the schema's own non-optional `Int` — never `nil`, so this
    /// stays non-optional too, matching `editDurationMinutes` above for
    /// the same reason). Only offered in the UI when
    /// `canEditLoggedDuration` is true (see below) — the same
    /// `.completed`/`.partiallyCompleted` gate `TrainingValidator.requiresActualDuration(for:)`
    /// already establishes; `saveLoggedActivityEdit()` still sends this
    /// value for every outcome, but it is only ever changed by the user
    /// when the field is actually shown.
    public var editLoggedDurationMinutes: Int = 60

    /// Notifications V1 Activity Reminder UI slice: this screen's own
    /// mirror of the reminder intent for `activity`, loaded via
    /// `NotificationsPlanningCoordinationService.fetchReminder(forPlannedActivity:)`
    /// — never a second, independently-computed reminder state.
    /// Refreshed from canonical state in `prefillReminderForm()` (called
    /// from `init`, and again after `saveEdit()`/`cancelActivity()`
    /// succeed, since either can cause the foundation's own EventBus
    /// reconciliation to reschedule or cancel the active reminder).
    public private(set) var reminderEnabled: Bool = false
    /// Bound directly by `ReminderLeadTimePickerView` — see that
    /// component's own doc comment: live edits (typing a Custom value)
    /// update this directly for display, while the actual persisted
    /// mutation only runs once a value is committed, via
    /// `setReminderLeadTimeMinutes(_:)` below.
    public var reminderLeadTimeMinutes: Int = 30
    /// Set when the user's most recent attempt to enable/change a
    /// reminder was declined by notification authorization — distinct
    /// from `reminderErrorMessage`, since this is a calm, expected
    /// outcome the UI offers a path to system Settings for, not a
    /// failure.
    public private(set) var reminderAuthorizationDenied: Bool = false
    public private(set) var reminderErrorMessage: String?
    /// True only while `enableReminder`'s own authorization-check/
    /// request/create round trip is in flight — lets the UI disable the
    /// control briefly rather than allow overlapping toggles.
    public private(set) var reminderIsUpdating: Bool = false

    /// Approved product contract: "If the activity has no start time,
    /// the reminder control must be unavailable" — read directly from
    /// `activity.startLocalTime`, the same canonical field
    /// `NotificationsPlanningCoordinationService.createReminder` itself
    /// requires, never a separately maintained flag.
    public var canSetReminder: Bool { activity.startLocalTime != nil }

    /// Sprint 1.1, P1 (athlete context): passed in by the caller, which
    /// already has the athlete's name (a `FamilyHomeRow`, an
    /// `athleteDisplayName` property, etc.) — no repository re-fetch or
    /// duplicated athlete state.
    public let athleteDisplayName: String

    private let weekPlanId: WeekPlanId
    public let athleteId: AthleteId
    private let isWeekPlanDraft: Bool
    private let deletedByActorId: ActorId
    private let planningService: PlanningService
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    /// Notifications V1 Activity Reminder UI slice: the sole
    /// cross-domain coordination point for reminder intent — never
    /// `ActivityReminderService`/`ActivityReminderScheduling` directly,
    /// matching this service's own "Notifications owns reminder intent
    /// and delivery infrastructure" boundary.
    private let notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService
    /// Post-mutation navigation and stale-state consistency audit: the
    /// explicit signal back to whichever screen pushed this one (Family
    /// Home, Athlete Home, Daily Training, Family Schedule, Weekly
    /// Planning), fired the moment a log genuinely succeeds — never a
    /// mere `.onAppear` refire assumption. This closure is the
    /// deterministic counterpart that tells the screen ALREADY BEHIND
    /// this one to reload its own authoritative data, the same "explicit
    /// success signal, not implicit SwiftUI lifecycle" principle
    /// `successfulLogTrigger`/`onLogged` already establish elsewhere in
    /// this exact flow. Planning edit/delete use the same host-refresh
    /// signal; the Weekly Planning host then publishes athlete-scoped
    /// invalidation after its own canonical refetch. Defaulted to a no-op
    /// so existing construction sites/tests are unaffected.
    ///
    /// TestFlight closeout: logging a planned activity is an in-context
    /// correction/update flow, not a hand-off to a new screen —
    /// `ActivityDetailView` itself no longer dismisses in response to a
    /// successful log (see `makeLogActivityViewModel`'s own doc comment
    /// for the previous, buggy behavior this replaces). `onActivityLogged`
    /// here still only reaches the screen THIS one was pushed FROM, so
    /// that screen's own row list is fresh whenever the user eventually
    /// navigates back to it — this screen's OWN freshness after a log is
    /// handled separately, in place, by `makeLogActivityViewModel`'s
    /// `onLogged` closure updating `loggedActivity`/`activityReflection`
    /// directly.
    private let onActivityLogged: () -> Void

    public init(
        activity: PlannedActivity,
        isCompleted: Bool,
        loggedActivity: LoggedActivity? = nil,
        activityReflection: ActivityReflection? = nil,
        weekPlanId: WeekPlanId,
        athleteId: AthleteId,
        athleteDisplayName: String,
        isWeekPlanDraft: Bool,
        deletedByActorId: ActorId,
        planningService: PlanningService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        onActivityLogged: @escaping () -> Void = {}
    ) {
        self.activity = activity
        self.isCompleted = isCompleted
        self.loggedActivity = loggedActivity
        self.activityReflection = activityReflection
        self.weekPlanId = weekPlanId
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.isWeekPlanDraft = isWeekPlanDraft
        self.deletedByActorId = deletedByActorId
        self.planningService = planningService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.notificationsPlanningCoordinationService = notificationsPlanningCoordinationService
        self.onActivityLogged = onActivityLogged
        prefillEditForm()
        prefillReminderForm()
    }

    /// RPE — read directly from the canonical `LoggedActivity` field,
    /// never duplicated elsewhere. `nil` when no `LoggedActivity` exists
    /// yet, or one exists but no RPE was recorded for it.
    public var perceivedExertion: Int? {
        loggedActivity?.perceivedExertion
    }

    /// Form — `ActivityReflection.bodyFeeling` for the EXACT
    /// `LoggedActivity` this screen represents, linked by stable typed
    /// ID (never inferred from title/date/list position). `nil` when:
    /// no reflection exists, the reflection has no `bodyFeeling`, or
    /// the reflection's own `visibility` is `.privateToAthlete` — the
    /// same existing gate `FamilyHomeViewModel.loadFocusThisWeek()`/
    /// `WeeklyHistoryViewModel.focusNextWeekIfPermitted` already
    /// established for reflection content, not a new privacy rule
    /// invented for this screen.
    public var formValue: Int? {
        guard let activityReflection, activityReflection.visibility != .privateToAthlete else {
            return nil
        }
        return activityReflection.bodyFeeling
    }

    /// Planned/Logged Activity lifecycle consistency cleanup: the
    /// canonical outcome — `.completed`/`.partiallyCompleted`/`.missed`/
    /// `.cancelled` — read directly from `loggedActivity.status`, never
    /// a second, locally-derived flag. `nil` exactly when `loggedActivity`
    /// is `nil` (nothing resolved yet), matching `isCompleted`'s own
    /// "has this been resolved at all" meaning.
    public var outcomeStatus: ActivityStatus? {
        loggedActivity?.status
    }

    /// Whether Edit/Delete are currently offered — mirrors
    /// `PlanningService.editPlannedActivity`/`deletePlannedActivity`'s
    /// own requirement that the WeekPlan still be `.draft`. Logging
    /// remains available regardless — a committed week's activities are
    /// exactly the ones worth logging.
    public var canEditOrDelete: Bool { isWeekPlanDraft }

    /// Planned/Logged Activity lifecycle consistency cleanup: Cancel is
    /// a training-time determination ("this will not take place"), the
    /// same category of event `TrainingService.logActivity` already
    /// records `.missed` through — never gated by `WeekPlan.status`
    /// (unlike edit/delete, which are plan-time-only mutations). Only
    /// offered before ANY outcome has been resolved — once logged,
    /// missed, or cancelled, `TrainingService`'s own duplicate-link
    /// guard would reject a second attempt anyway; this mirrors that at
    /// the UI layer, the same way the existing "Log Activity" button's
    /// own `!isCompleted` gate already does.
    public var canCancel: Bool { !isCompleted }

    /// Reversibility principle: "Reopen Activity" is offered ONLY for a
    /// canonical outcome of exactly `.cancelled` — never Completed,
    /// PartiallyCompleted. Undoing an erroneous Cancelled or Missed
    /// no-training outcome is approved; a genuinely completed training
    /// outcome is never reopenable through this action.
    public var canReopen: Bool {
        outcomeStatus == .cancelled || outcomeStatus == .missed
    }

    /// Planned/Logged Activity lifecycle consistency cleanup (Edit
    /// Logged Activity -> RPE + Form): offered whenever a
    /// `LoggedActivity` exists, regardless of its specific outcome —
    /// matching "Logged Activity Detail displays RPE/Form" itself,
    /// which shows whenever a value exists, not only for `.completed`.
    public var canEditLoggedActivity: Bool { loggedActivity != nil }

    /// Review follow-up: whether the Edit Logged Activity sheet should
    /// offer a duration correction field at all — only when the
    /// canonical outcome is one `TrainingValidator.requiresActualDuration(for:)`
    /// says duration is meaningful for (`.completed`/`.partiallyCompleted`).
    /// For `.missed`/`.cancelled`, `durationMinutes` is the schema's own
    /// documented `1`-minute placeholder for "nothing to measure" — not
    /// a real value a parent would ever need to correct, so this stays
    /// `false` and the field is hidden entirely rather than inviting a
    /// meaningless edit.
    public var canEditLoggedDuration: Bool {
        guard let outcomeStatus else { return false }
        return TrainingValidator.requiresActualDuration(for: outcomeStatus)
    }

    public func prefillEditForm() {
        editTitle = activity.title ?? ""
        editSportId = activity.sportId.map { SportId(rawValue: $0) }
        editDate = Self.date(from: activity.localDate)
        editActivityType = activity.activityType
        if let startTime = activity.startLocalTime {
            editHasStartTime = true
            editStartTime = Calendar.current.date(from: DateComponents(hour: startTime.hour, minute: startTime.minute)) ?? .now
        } else {
            editHasStartTime = false
        }
        if let duration = activity.plannedDurationMinutes {
            editHasDuration = true
            editDurationMinutes = duration
        } else {
            editHasDuration = false
        }
        editNotes = activity.notes ?? ""
        editLocation = activity.location ?? ""
    }

    /// Notifications V1 Activity Reminder UI slice: loads the current
    /// reminder intent for `activity` from canonical Notifications
    /// truth — Off (default) when none exists, matching this slice's
    /// own "Reminder is Off by default" and "existing reminder must
    /// load correctly when editing" requirements. `try?` here mirrors
    /// this screen's own established convention for read-only prefill
    /// (see `deleteActivity`/`cancelActivity`'s own throwing calls,
    /// which surface errors; this is a display-only read where a
    /// failure just means Off is shown, not a silent data loss).
    public func prefillReminderForm() {
        reminderErrorMessage = nil
        reminderAuthorizationDenied = false
        guard let reminder = try? notificationsPlanningCoordinationService.fetchReminder(
            forPlannedActivity: activity.plannedActivityId
        ) else {
            reminderEnabled = false
            return
        }
        reminderEnabled = true
        reminderLeadTimeMinutes = reminder.leadTimeMinutes
    }

    /// Notifications V1 Activity Reminder UI slice: the Reminder
    /// toggle's own entry point. Turning Off cancels/removes the
    /// reminder immediately — no authorization check needed for that
    /// direction. Turning On runs the full `enableReminder` round trip
    /// via `applyReminder(leadTimeMinutes:)`, using whatever lead time
    /// is currently selected (the default preset, or a previously
    /// prefilled value).
    public func setReminderEnabled(_ enabled: Bool) {
        reminderErrorMessage = nil
        guard enabled else {
            reminderAuthorizationDenied = false
            do {
                try notificationsPlanningCoordinationService.disableReminder(
                    forPlannedActivity: activity.plannedActivityId
                )
            } catch {
                reminderErrorMessage = PlanningStrings.reminderGenericError
            }
            reminderEnabled = false
            return
        }
        applyReminder(leadTimeMinutes: reminderLeadTimeMinutes)
    }

    /// Notifications V1 Activity Reminder UI slice: `ReminderLeadTimePickerView`'s
    /// own commit callback — fired only on a genuinely committed lead
    /// time (a preset tap, or Custom losing focus with a valid value),
    /// never per keystroke. A no-op if the reminder isn't currently
    /// enabled: the picker's own live-typing display already keeps
    /// `reminderLeadTimeMinutes` correct via its two-way binding, and
    /// there is nothing to reschedule until the user turns Reminder On.
    public func setReminderLeadTimeMinutes(_ minutes: Int) {
        reminderLeadTimeMinutes = minutes
        guard reminderEnabled else { return }
        applyReminder(leadTimeMinutes: minutes)
    }

    /// The shared enable/change-lead-time path — `NotificationsPlanningCoordinationService
    /// .enableReminder` already replaces any existing reminder for this
    /// activity, so "turn on" and "change lead time while already on"
    /// are the exact same call. Requests authorization contextually
    /// (only via the coordination service, never here directly) and
    /// maps every outcome to this screen's own displayed state — never
    /// leaves `reminderEnabled` true without a genuinely active,
    /// scheduled reminder.
    private func applyReminder(leadTimeMinutes: Int) {
        guard canSetReminder else { return }
        reminderErrorMessage = nil
        reminderAuthorizationDenied = false
        reminderIsUpdating = true
        notificationsPlanningCoordinationService.enableReminder(
            athleteId: athleteId,
            plannedActivityId: activity.plannedActivityId,
            leadTimeMinutes: leadTimeMinutes
        ) { [weak self] result in
            guard let self else { return }
            self.reminderIsUpdating = false
            switch result {
            case .success(.enabled(let leadTimeMinutes)):
                self.reminderEnabled = true
                self.reminderLeadTimeMinutes = leadTimeMinutes
            case .success(.authorizationDenied):
                self.reminderEnabled = false
                self.reminderAuthorizationDenied = true
            case .success(.fireDateInPast):
                self.reminderEnabled = false
                self.reminderErrorMessage = PlanningStrings.reminderFireDateInPast
            case .failure:
                self.reminderEnabled = false
                self.reminderErrorMessage = PlanningStrings.reminderGenericError
            }
        }
    }

    @discardableResult
    public func saveEdit() -> Bool {
        errorMessage = nil
        do {
            let updated = try planningService.editPlannedActivity(
                activity.plannedActivityId,
                expectedWeekPlanId: weekPlanId,
                activityType: editActivityType,
                title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                localDate: Self.localDate(from: editDate),
                timeZoneId: activity.timeZoneId,
                sportId: editSportId,
                startLocalTime: editHasStartTime ? Self.localTime(from: editStartTime) : nil,
                plannedDurationMinutes: editHasDuration ? editDurationMinutes : nil,
                notes: editNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editNotes,
                location: editLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editLocation
            )
            activity = updated
            // Notifications V1 Activity Reminder UI slice: an edit that
            // changed date/time/timezone already triggered the
            // foundation's own EventBus reconciliation
            // (`NotificationsPlanningCoordinationService.handlePlannedActivityChanged`)
            // synchronously, before this call returns — this just
            // re-reads whatever it decided (rescheduled, or cancelled if
            // the new time is in the past / the start time was removed),
            // so the displayed Reminder control never shows stale state.
            prefillReminderForm()
            onActivityLogged()
            return true
        } catch let error as PlanningServiceError {
            if case .invalidField(let field) = error, field == "title or sportId is required" {
                errorMessage = PlanningStrings.activityIdentityRequired
            } else {
                errorMessage = "Could not save changes. Please try again."
            }
            return false
        } catch {
            errorMessage = "Could not save changes. Please try again."
            return false
        }
    }

    /// P0 crash fix (same-pattern audit): `onActivityLogged()` was
    /// missing here — the only mutation on this screen that didn't fire
    /// it, even though `cancelActivity()`/`reopenActivity()` both
    /// already do, for the exact same reason: the screen this was
    /// pushed from must reread canonical state, so its own row list no
    /// longer references the just-deleted `PlannedActivity` once this
    /// screen pops. `loadTodaysTraining()`/`loadTodayActivityRows()`
    /// re-fetch from the repository fresh, which naturally excludes a
    /// hard-deleted entity — never a second, ad hoc "remove this one row
    /// locally" mechanism.
    @discardableResult
    public func deleteActivity() -> Bool {
        errorMessage = nil
        do {
            try planningService.deletePlannedActivity(
                activity.plannedActivityId,
                expectedWeekPlanId: weekPlanId,
                deletedBy: deletedByActorId
            )
            isDeleted = true
            onActivityLogged()
            return true
        } catch {
            errorMessage = "Could not delete this activity. Please try again."
            return false
        }
    }

    /// Planned/Logged Activity lifecycle consistency cleanup: cancels
    /// this planned activity — "the previously planned activity will
    /// not take place." Domain status is `.cancelled`, the canonical
    /// `ActivityStatus` case that already existed in the shared enum
    /// (never a new "dismissed" concept); reuses the EXACT same
    /// `TrainingReflectionCoordinationService.logActivity` path a
    /// completed/missed log already goes through, linked to this
    /// `PlannedActivity` by the same stable typed ID — never Delete:
    /// the `PlannedActivity` itself is completely untouched, preserving
    /// the historical existence of the plan, and Weekly/history
    /// composition can still distinguish "planned and cancelled" from
    /// either "still pending" (no `LoggedActivity` at all) or "missed"
    /// (`LoggedActivity.status == .missed`) via this exact canonical
    /// relationship — never title/date matching, never a local flag.
    ///
    /// `durationMinutes: 1` is the schema's own documented minimum
    /// placeholder for an outcome with nothing to measure (see
    /// `TrainingService`'s own doc comment on this exact convention for
    /// `.missed`) — never a fabricated real duration. No Form is
    /// collected for a cancellation (nothing happened to rate).
    ///
    /// Retrying this action (e.g. a double-tap) can never create a
    /// duplicate lifecycle record: `TrainingService.logActivity` already
    /// rejects a second link to the same `PlannedActivity` via
    /// `TrainingServiceError.plannedActivityAlreadyLinked` — reused
    /// here, not reimplemented.
    @discardableResult
    public func cancelActivity() -> Bool {
        errorMessage = nil
        do {
            let result = try trainingReflectionCoordinationService.logActivity(
                athleteId: athleteId,
                plannedActivityId: activity.plannedActivityId,
                sportId: activity.sportId.map(SportId.init(rawValue:)),
                categoryIds: activity.categoryIds.map(ActivityCategoryId.init(rawValue:)),
                activityType: activity.activityType,
                title: activity.title,
                startedAt: Self.startedAt(for: activity),
                durationMinutes: 1,
                status: .cancelled,
                authorId: deletedByActorId,
                sessionForm: nil
            )
            loggedActivity = result.loggedActivity
            isCompleted = true
            // Notifications V1 Activity Reminder UI slice: cancelling
            // this activity already published `ActivityLogged`
            // synchronously above (via `TrainingReflectionCoordinationService
            // .logActivity` -> `TrainingService`), which the foundation's
            // `handleActivityLogged` reacts to by cancelling any active
            // reminder — re-reads that outcome so the Reminder control
            // reflects Off immediately, never a stale "still on" display.
            prefillReminderForm()
            onActivityLogged()
            return true
        } catch TrainingServiceError.plannedActivityAlreadyLinked {
            errorMessage = "This activity has already been logged."
            return false
        } catch {
            errorMessage = "Could not cancel this activity. Please try again."
            return false
        }
    }

    /// Reversibility principle: undoes an erroneous no-training outcome.
    /// Removes exactly the `.cancelled` or `.missed` `LoggedActivity` this screen
    /// already resolved via the canonical `loggedActivity` relationship
    /// (never a second lookup, never title/date matching) through
    /// `TrainingReflectionCoordinationService.reopenNoTrainingOutcome` —
    /// the SAME `PlannedActivity` (`activity` here is never reassigned
    /// or recreated) becomes unresolved again: `loggedActivity` and
    /// `outcomeStatus` return to `nil`, `isCompleted` returns to `false`,
    /// so Log Activity and Cancel Activity both become available again
    /// exactly as they were before the erroneous cancellation, and
    /// `onActivityLogged()` fires the SAME reload signal a successful
    /// cancel/log already fires, so the mounted screen this was pushed
    /// from picks up the unresolved state immediately.
    @discardableResult
    public func reopenActivity() -> Bool {
        errorMessage = nil
        guard let loggedActivity, canReopen else { return false }
        do {
            try trainingReflectionCoordinationService.reopenNoTrainingOutcome(
                loggedActivity.loggedActivityId,
                athleteId: athleteId
            )
            self.loggedActivity = nil
            self.activityReflection = nil
            isCompleted = false
            onActivityLogged()
            return true
        } catch {
            errorMessage = "Could not reopen this activity. Please try again."
            return false
        }
    }

    /// Planned/Logged Activity lifecycle consistency cleanup (Edit
    /// Logged Activity -> RPE + Form), extended by review follow-up for
    /// duration: loads the exact canonical values this screen already
    /// displays read-only — never re-derived, never a second source of
    /// truth. `editLoggedDurationMinutes` is prefilled from the real
    /// stored value regardless of `canEditLoggedDuration` — harmless
    /// when the field isn't shown, since `saveLoggedActivityEdit()`
    /// then sends back the exact same untouched value.
    public func prefillLoggedActivityEditForm() {
        editLoggedPerceivedExertion = perceivedExertion
        editLoggedSessionForm = formValue
        editLoggedDurationMinutes = loggedActivity?.durationMinutes ?? 60
    }

    /// Corrects duration and RPE on the canonical `LoggedActivity` and
    /// creates-or-updates the linked `ActivityReflection`'s Form value,
    /// via `TrainingReflectionCoordinationService.correctLoggedActivity`
    /// — see that method's own doc comment for the exact create-vs-update
    /// decision (a legacy logged activity with no reflection yet gets
    /// one created only if a Form value is actually entered; nothing is
    /// fabricated). Updates this screen's own `loggedActivity`/
    /// `activityReflection` in place on success, so the read-only
    /// summary above reflects the change immediately.
    ///
    /// Review follow-up: validates duration and Form BEFORE calling the
    /// coordinator — using the EXACT SAME `TrainingValidator` functions
    /// `LogActivityViewModel.save()` uses for initial logging
    /// (`validateActualDuration(_:for:)`/`validateForm(_:for:)`, both
    /// keyed off the `LoggedActivity`'s own canonical `status`), never a
    /// separate edit-only rule. This is what makes it impossible to
    /// correct a `.completed`/`.partiallyCompleted` activity's Form back
    /// to unset, or its duration to something invalid — including the
    /// legacy case where `editLoggedSessionForm` opens `nil` (no
    /// historical value, or a private reflection this actor cannot
    /// see): the sheet may OPEN that way, but Save is blocked until a
    /// valid value is actually entered, exactly the "safe to open,
    /// blocked to commit" contract required.
    @discardableResult
    public func saveLoggedActivityEdit() -> Bool {
        errorMessage = nil
        guard let loggedActivity else { return false }
        if let durationError = TrainingValidator.validateActualDuration(editLoggedDurationMinutes, for: loggedActivity.status) {
            errorMessage = durationError
            return false
        }
        if let formError = TrainingValidator.validateForm(editLoggedSessionForm, for: loggedActivity.status) {
            errorMessage = formError
            return false
        }
        do {
            let result = try trainingReflectionCoordinationService.correctLoggedActivity(
                loggedActivityId: loggedActivity.loggedActivityId,
                athleteId: athleteId,
                authorId: deletedByActorId,
                durationMinutes: max(1, min(1440, editLoggedDurationMinutes)),
                perceivedExertion: editLoggedPerceivedExertion,
                sessionForm: editLoggedSessionForm
            )
            self.loggedActivity = result.loggedActivity
            switch result.sessionFormOutcome {
            case .notRequested:
                break
            case .saved(let reflection):
                self.activityReflection = reflection
            case .failed:
                errorMessage = "Duration and RPE saved. Form could not be saved — tap Save to try again."
                return false
            }
            return true
        } catch {
            errorMessage = "Could not save changes. Please try again."
            return false
        }
    }

    /// Builds the logging ViewModel with every planned-activity value
    /// already known, prefilled — Part 4's own core requirement.
    ///
    /// TestFlight closeout (blank-screen-after-Save fix): this used to
    /// take an `onDismiss` closure that `ActivityDetailView` wired to its
    /// own `@Environment(\.dismiss)`, called synchronously the moment a
    /// log succeeded — so a successful Save popped `ActivityDetailView`
    /// itself off the NavigationStack, not just the `LogActivityView`
    /// sheet. Logging a planned activity is an in-context correction/
    /// update flow, not a hand-off to a new screen (unlike
    /// `RecurringOccurrencePreviewView`'s own, DELIBERATELY different
    /// `onLogged: { onActivityLogged(); dismiss() }` — that screen's own
    /// content is static text that becomes meaningless the instant the
    /// occurrence materializes, so dismissing itself there is correct;
    /// `ActivityDetailView` has real, updatable state to show instead,
    /// so it must not copy that pattern). `onDismiss` is removed
    /// entirely — nothing here asks the presenting screen to dismiss
    /// anymore. `onLogged` below now refreshes `loggedActivity`/
    /// `activityReflection` from the SAME canonical read
    /// `ActivityDetailViewLoader.onAppear` already uses to build this
    /// exact state initially (`loggedActivityDetail(forPlannedActivity:)`),
    /// so the moment the sheet closes (via `LogActivityView`'s own
    /// `dismiss()`, unrelated to this closure), `ActivityDetailView` is
    /// already showing the real logged outcome and recorded data — no
    /// forced refresh, no timing workaround, no fabricated local state.
    public func makeLogActivityViewModel() -> LogActivityViewModel {
        LogActivityViewModel(
            plannedActivity: activity,
            athleteId: athleteId,
            athleteDisplayName: athleteDisplayName,
            // VX-022: the same acting-party identity already used for
            // `deletedByActorId` doubles as the Session Form reflection's
            // author — one actor identity per screen, not a second,
            // separately-resolved one.
            authorId: deletedByActorId,
            trainingReflectionCoordinationService: trainingReflectionCoordinationService,
            // Review follow-up (blank-screen-after-Save closeout, round
            // 3): split from the refresh below — this fires
            // unconditionally, regardless of whether THIS screen's own
            // canonical refresh succeeds, because the screen this one was
            // pushed from reads its own canonical state independently and
            // is correct either way.
            onLogged: { [weak self] in
                self?.onActivityLogged()
            },
            // Review follow-up (blank-screen-after-Save closeout, round
            // 3): reports success/failure back to `LogActivityViewModel.save()`
            // so a failed refresh here keeps the sheet open for retry
            // instead of dismissing onto a screen it never actually
            // updated. `isCompleted` and `loggedActivity` must never
            // diverge — One Truth — so both are still set together, ONLY
            // inside the success branch, exactly as round 2 already
            // established; the only change here is that failure is now
            // reported outward instead of silently swallowed by `try?`.
            // On failure, nothing here is mutated — an honest "still
            // don't know" rather than a false "definitely logged" —
            // self-correcting the next time this screen (or a fresh one,
            // via `ActivityDetailViewLoader`) re-reads canonical state, or
            // the next time `save()` retries this same closure.
            refreshMountedState: { [weak self] in
                guard let self else { return false }
                guard let detail = try? self.trainingReflectionCoordinationService.loggedActivityDetail(
                    forPlannedActivity: self.activity.plannedActivityId
                ) else {
                    return false
                }
                self.loggedActivity = detail.loggedActivity
                self.activityReflection = detail.reflection
                self.isCompleted = true
                return true
            }
        )
    }

    /// The planned activity's own date/time, combined into a single
    /// `Date` — same derivation `LogActivityViewModel.startedAt(for:)`
    /// already establishes for the exact same purpose (a concrete
    /// instant `LoggedActivity.startedAt` needs), reused here for
    /// `cancelActivity()` rather than duplicated with different logic.
    private static func startedAt(for activity: PlannedActivity) -> Date {
        var components = DateComponents(
            year: activity.localDate.year,
            month: activity.localDate.month,
            day: activity.localDate.day
        )
        if let startTime = activity.startLocalTime {
            components.hour = startTime.hour
            components.minute = startTime.minute
        }
        return Calendar.current.date(from: components) ?? .now
    }

    private static func date(from localDate: LocalDate) -> Date {
        Calendar.current.date(from: DateComponents(year: localDate.year, month: localDate.month, day: localDate.day)) ?? .now
    }

    private static func localDate(from date: Date) -> LocalDate {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    private static func localTime(from date: Date) -> LocalTime {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return LocalTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }
}
