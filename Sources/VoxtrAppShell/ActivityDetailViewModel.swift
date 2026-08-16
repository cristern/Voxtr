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
    /// loading step" pattern already used for `isWeekPlanDraft`. Never
    /// fetched by this type itself.
    private let loggedActivity: LoggedActivity?
    /// The `ActivityReflection` linked to `loggedActivity` above, if
    /// one exists — raw/unfiltered; `formValue` below applies the
    /// existing privacy gate before exposing its content.
    private let activityReflection: ActivityReflection?

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
    /// mere `.onAppear` refire assumption. This screen already pops
    /// itself on successful log (`ActivityDetailView`'s own
    /// `.onChange(of: isCompleted)`); this closure is the deterministic
    /// counterpart that tells the screen being popped BACK TO to reload
    /// its own authoritative data, the same "explicit success signal,
    /// not implicit SwiftUI lifecycle" principle `successfulLogTrigger`/
    /// `onLogged` already establish elsewhere in this exact flow.
    /// Defaulted to a no-op so existing construction sites/tests are
    /// unaffected.
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

    /// Whether Edit/Delete are currently offered — mirrors
    /// `PlanningService.editPlannedActivity`/`deletePlannedActivity`'s
    /// own requirement that the WeekPlan still be `.draft`. Logging
    /// remains available regardless — a committed week's activities are
    /// exactly the ones worth logging.
    public var canEditOrDelete: Bool { isWeekPlanDraft }

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

    /// Builds the logging ViewModel with every planned-activity value
    /// already known, prefilled — Part 4's own core requirement.
    ///
    /// `onDismiss` (Athlete Home stale-state fix): `ActivityDetailView`
    /// passes its own `@Environment(\.dismiss)` here, called
    /// SYNCHRONOUSLY in the same `onLogged` closure as
    /// `onActivityLogged()` — the exact timing
    /// `RecurringOccurrencePreviewView`'s own already-verified-working
    /// `onLogged: { onActivityLogged(); dismiss() }` already uses,
    /// rather than waiting for a separate, later render pass to detect
    /// `isCompleted`'s change and dismiss reactively (still preserved
    /// below as a redundant safety net — this closure is additive, not
    /// a replacement). Defaulted to a no-op so existing callers/tests
    /// that only care about `isCompleted`/`onActivityLogged` are
    /// unaffected.
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
