import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// S3.3: backs `DailyTrainingView`. Every state-changing action goes
/// through `TrainingService` (logging) or `TrainingPlanningCoordinationService`
/// (reading today's planned activities with completion state) — this
/// type holds no business rules of its own, only orchestrates calls and
/// turns thrown errors into a single user-facing `errorMessage`, the
/// same pattern `CreateFamilyViewModel`/`WeeklyPlanningViewModel`
/// already established.
@MainActor
@Observable
public final class DailyTrainingViewModel {
    public private(set) var plannedActivities: [PlannedActivityCompletion] = []
    public private(set) var loggedActivities: [LoggedActivity] = []
    public private(set) var errorMessage: String?
    public private(set) var isSubmitting = false

    // Log-activity form fields — LoggedActivity's existing fields only,
    // nothing new.
    public var newLogTitle: String = ""
    public var newLogActivityType: ActivityType = .individualTraining
    public var newLogStartedAt: Date = .now
    /// Sprint 1.1 closeout, Item 5: 1 was the validation floor
    /// (`TrainingValidator.validateDurationMinutes`'s own minimum), not
    /// a deliberate UX choice — nothing in the domain requires this
    /// specific starting value. 60 matches `LogActivityViewModel`'s own
    /// established default. This is transient UI state only — never a
    /// persisted default. It is not reset after a successful save (see
    /// `logActivity()` below, which resets title/notes/RPE but leaves
    /// duration as the user's own last-entered value, matching this
    /// form's existing behavior for that field).
    public var newLogDurationMinutes: Int = 60
    public var newLogPerceivedExertion: Int?
    public var newLogNotes: String = ""
    /// VX-022 (Session Form): the "Form" field in the UI — a required
    /// 1-5 self-rating (every log through this flow represents a
    /// completed session; there is no "not completed" state here),
    /// stored as `ActivityReflection.bodyFeeling` via
    /// `TrainingReflectionCoordinationService` — see that type's own
    /// doc comment for the atomicity/retry contract `logActivity()`
    /// below implements.
    public var newLogSessionForm: Int?
    /// True once a Session Form value was entered but has not yet been
    /// successfully saved. While true, `newLogSessionForm` is retained
    /// (never reset) and the next `logActivity()` call retries only the
    /// Session Form write against the already-logged activity, never
    /// logs a second one.
    public private(set) var sessionFormPendingRetry: Bool = false
    /// Optional link to a PlannedActivity — the picker in the view only
    /// lets the user select an uncompleted one; this property itself
    /// doesn't enforce that (the view disables completed options, and
    /// `TrainingService` itself rejects a duplicate link regardless).
    public var selectedPlannedActivityId: PlannedActivityId?
    /// Sprint 1.2B runtime closeout: increments on every SUCCESSFUL
    /// unplanned-activity log only — never on validation failure,
    /// persistence failure, or merely opening the form. The view
    /// watches this to scroll to the top after logging, per this
    /// package's own explicit "only after confirmed successful
    /// logging" requirement.
    public private(set) var successfulLogTrigger: Int = 0
    /// Sprint 1.2B, Priority 3: today's recurring occurrences not yet
    /// materialized — filtered from `TodayActivityComposer`'s own
    /// output (the same shared read model Family Home/Athlete Home
    /// use), not a second, screen-specific derivation.
    /// `plannedActivities`/`loggedActivities` above already cover the
    /// materialized-planned and logged cases for this screen, so only
    /// the recurring-occurrence case is pulled from the composer here.
    public private(set) var recurringOccurrences: [RecurringActivitySuggestion] = []

    private let trainingService: TrainingService
    private let coordinationService: TrainingPlanningCoordinationService
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    private let authorId: ActorId
    public let athleteId: AthleteId
    /// Set once a `logActivity()` call successfully logs the activity
    /// but its Session Form write fails — retried on the next
    /// `logActivity()` call instead of logging again. See
    /// `sessionFormPendingRetry`'s own doc comment.
    private var pendingSessionFormLoggedActivityId: LoggedActivityId?
    /// Optional, defaulted to `nil` — existing construction sites and
    /// tests that predate this feature are unaffected;
    /// `recurringOccurrences` simply stays empty if none was supplied,
    /// the same "absence never corrupts the rest of this ViewModel"
    /// principle `HomeDashboardViewModel`'s own optional composer
    /// dependency already establishes.
    private let todayActivityComposer: TodayActivityComposer?
    private let athleteDisplayName: String

    public init(
        trainingService: TrainingService,
        coordinationService: TrainingPlanningCoordinationService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        authorId: ActorId,
        athleteId: AthleteId,
        athleteDisplayName: String = "",
        todayActivityComposer: TodayActivityComposer? = nil
    ) {
        self.trainingService = trainingService
        self.coordinationService = coordinationService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.authorId = authorId
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.todayActivityComposer = todayActivityComposer
    }

    /// Loads today's planned activities (with completion state),
    /// today's logged activities, and (Sprint 1.2B) today's
    /// unmaterialized recurring occurrences. Call once when the view
    /// appears, and again after a successful log to refresh all three.
    public func load() {
        errorMessage = nil
        do {
            plannedActivities = try coordinationService.todaysPlannedActivitiesWithCompletion(forAthlete: athleteId)
            loggedActivities = try trainingService.fetchTodaysLoggedActivities(forAthlete: athleteId)
            if let todayActivityComposer {
                let rows = try todayActivityComposer.todayActivities(forAthlete: athleteId, athleteName: athleteDisplayName)
                recurringOccurrences = rows.compactMap { row in
                    if case .recurringOccurrence(_, _, let suggestion) = row { return suggestion }
                    return nil
                }
            }
        } catch {
            errorMessage = TrainingStrings.genericError
        }
    }

    public func logActivity() {
        guard !isSubmitting else { return }
        errorMessage = nil

        if let pendingSessionFormLoggedActivityId {
            // Retry path: the activity itself was already logged
            // successfully on a prior call — only the Session Form
            // write failed. Never re-invokes trainingService.logActivity.
            guard let newLogSessionForm else {
                self.pendingSessionFormLoggedActivityId = nil
                sessionFormPendingRetry = false
                return
            }
            isSubmitting = true
            defer { isSubmitting = false }
            do {
                _ = try trainingReflectionCoordinationService.recordSessionForm(
                    athleteId: athleteId,
                    loggedActivityId: pendingSessionFormLoggedActivityId,
                    authorId: authorId,
                    bodyFeeling: newLogSessionForm
                )
                self.pendingSessionFormLoggedActivityId = nil
                sessionFormPendingRetry = false
                self.newLogSessionForm = nil
                load()
            } catch {
                sessionFormPendingRetry = true
                errorMessage = "Activity logged. Form could not be saved — tap Log activity to try again."
            }
            return
        }

        if let durationError = TrainingValidator.validateDurationMinutes(newLogDurationMinutes) {
            errorMessage = durationError
            return
        }
        if let exertionError = TrainingValidator.validatePerceivedExertion(newLogPerceivedExertion) {
            errorMessage = exertionError
            return
        }
        let trimmedNotes = newLogNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesOrNil = trimmedNotes.isEmpty ? nil : trimmedNotes
        if let notesError = TrainingValidator.validateNotes(notesOrNil) {
            errorMessage = notesError
            return
        }
        // VX-022: every log through this flow represents a completed
        // session (no "not completed" state here) — Form is
        // unconditionally required, checked before anything is
        // created, so a log can never be reported as saved without it.
        if let formError = TrainingValidator.validateForm(newLogSessionForm) {
            errorMessage = formError
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let result = try trainingReflectionCoordinationService.logActivity(
                athleteId: athleteId,
                plannedActivityId: selectedPlannedActivityId,
                activityType: newLogActivityType,
                title: newLogTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                startedAt: newLogStartedAt,
                durationMinutes: newLogDurationMinutes,
                perceivedExertion: newLogPerceivedExertion,
                notes: notesOrNil,
                authorId: authorId,
                sessionForm: newLogSessionForm
            )
            newLogTitle = ""
            newLogNotes = ""
            newLogPerceivedExertion = nil
            selectedPlannedActivityId = nil
            load()
            // Sprint 1.2B runtime closeout: a simple counter, not a
            // Bool — .onChange must fire on every successful log, not
            // only a false->true transition, so a second/third
            // successful log in the same session still triggers the
            // view's own scroll-to-top.
            successfulLogTrigger += 1

            switch result.sessionFormOutcome {
            case .notRequested, .saved:
                newLogSessionForm = nil
                sessionFormPendingRetry = false
            case .failed:
                // The activity itself is genuinely logged (above) — only
                // Session Form failed. Preserved for retry, never
                // silently discarded.
                pendingSessionFormLoggedActivityId = result.loggedActivity.loggedActivityId
                sessionFormPendingRetry = true
                errorMessage = "Activity logged. Form could not be saved — tap Log activity to try again."
            }
        } catch let error as TrainingServiceError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = TrainingStrings.genericError
        }
    }

    private static func message(for error: TrainingServiceError) -> String {
        switch error {
        case .plannedActivityAlreadyLinked:
            return TrainingStrings.plannedActivityAlreadyLinked
        case .loggedActivityNotFound:
            // Codemagic compile-fix: `.loggedActivityNotFound` is thrown
            // only by `TrainingService.correctLoggedActivity` — a
            // capability this ViewModel's own `logActivity()` above
            // never calls (it only ever creates a LoggedActivity via
            // `logActivity`, never corrects an existing one), so this
            // case is unreachable through this exact call site. Handled
            // explicitly anyway, since `error` here is the full
            // `TrainingServiceError` type and this switch must stay
            // exhaustive against it. No dedicated message exists for
            // this case in this ViewModel, so this reuses the same
            // controlled fallback already used a few lines up for any
            // non-`TrainingServiceError` failure — not a new message,
            // not a new product flow.
            return TrainingStrings.genericError
        case .activityNotCancelled:
            // Reversibility principle (Reopen Activity): thrown only by
            // `TrainingService.reopenCancelledActivity`, a capability
            // this ViewModel's own `logActivity()` never calls (it only
            // ever creates a `LoggedActivity`, never reopens one) — same
            // "unreachable through this exact call site, handled anyway
            // for exhaustiveness" reasoning as `.loggedActivityNotFound`
            // directly above.
            return TrainingStrings.genericError
        }
    }
}
