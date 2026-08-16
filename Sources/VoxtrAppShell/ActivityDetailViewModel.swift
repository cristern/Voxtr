import Foundation
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

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
    /// Post-mutation navigation and stale-state consistency audit: the
    /// explicit signal back to whichever screen pushed this one (Family
    /// Home, Athlete Home, Daily Training, Family Schedule, Weekly
    /// Planning), fired the moment a log genuinely succeeds — never a
    /// mere `.onAppear` refire assumption. This screen also pops itself
    /// on successful log, synchronously, via the SAME `onLogged`
    /// closure (see `makeLogActivityViewModel`'s own `onDismiss`
    /// parameter) — the returning host is signaled to reload BEFORE
    /// this screen dismisses, never after. This closure is the
    /// deterministic counterpart that tells the screen being popped
    /// BACK TO to reload its own authoritative data, the same "explicit
    /// success signal, not implicit SwiftUI lifecycle" principle
    /// `successfulLogTrigger`/`onLogged` already establish elsewhere in
    /// this exact flow. Defaulted to a no-op so existing construction
    /// sites/tests are unaffected.
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
        self.onActivityLogged = onActivityLogged
        prefillEditForm()
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

    /// Planned/Logged Activity lifecycle consistency cleanup (Edit
    /// Logged Activity -> RPE + Form): offered whenever a
    /// `LoggedActivity` exists, regardless of its specific outcome —
    /// matching "Logged Activity Detail displays RPE/Form" itself,
    /// which shows whenever a value exists, not only for `.completed`.
    public var canEditLoggedActivity: Bool { loggedActivity != nil }

    public func prefillEditForm() {
        editTitle = activity.title
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
                startLocalTime: editHasStartTime ? Self.localTime(from: editStartTime) : nil,
                plannedDurationMinutes: editHasDuration ? editDurationMinutes : nil,
                notes: editNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editNotes,
                location: editLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editLocation
            )
            activity = updated
            return true
        } catch {
            errorMessage = "Could not save changes. Please try again."
            return false
        }
    }

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

    /// Planned/Logged Activity lifecycle consistency cleanup (Edit
    /// Logged Activity -> RPE + Form): loads the exact canonical values
    /// this screen already displays read-only — never re-derived,
    /// never a second source of truth.
    public func prefillLoggedActivityEditForm() {
        editLoggedPerceivedExertion = perceivedExertion
        editLoggedSessionForm = formValue
    }

    /// Corrects RPE on the canonical `LoggedActivity` and creates-or-
    /// updates the linked `ActivityReflection`'s Form value, via
    /// `TrainingReflectionCoordinationService.correctLoggedActivity` —
    /// see that method's own doc comment for the exact create-vs-update
    /// decision (a legacy logged activity with no reflection yet gets
    /// one created only if a Form value is actually entered; nothing is
    /// fabricated). Updates this screen's own `loggedActivity`/
    /// `activityReflection` in place on success, so the read-only
    /// summary above reflects the change immediately.
    @discardableResult
    public func saveLoggedActivityEdit() -> Bool {
        errorMessage = nil
        guard let loggedActivity else { return false }
        do {
            let result = try trainingReflectionCoordinationService.correctLoggedActivity(
                loggedActivityId: loggedActivity.loggedActivityId,
                athleteId: athleteId,
                authorId: deletedByActorId,
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
                errorMessage = "RPE saved. Form could not be saved — tap Save to try again."
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
    /// `onDismiss` (Athlete Home stale-state fix, single-owner
    /// closeout): `ActivityDetailView` passes its own
    /// `@Environment(\.dismiss)` here, called SYNCHRONOUSLY in the same
    /// `onLogged` closure as `onActivityLogged()` — the exact timing
    /// `RecurringOccurrencePreviewView`'s own already-verified-working
    /// `onLogged: { onActivityLogged(); dismiss() }` already uses. This
    /// is now the ONE place a successful log dismisses
    /// `ActivityDetailView` — `isCompleted` is `private(set)` and this
    /// closure (line below) is its only mutation site anywhere in this
    /// codebase, so `ActivityDetailView` no longer also observes
    /// `isCompleted` via `.onChange` to dismiss reactively; that
    /// would-be second, independent trigger was removed rather than
    /// kept as a "safety net" — a successful log has exactly one
    /// navigation owner, not two. Defaulted to a no-op so existing
    /// callers/tests that only care about `isCompleted`/`onActivityLogged`
    /// are unaffected.
    public func makeLogActivityViewModel(onDismiss: @escaping () -> Void = {}) -> LogActivityViewModel {
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
            onLogged: { [weak self] in
                self?.isCompleted = true
                self?.onActivityLogged()
                onDismiss()
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
