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
    public let athleteId: AthleteId
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
        athleteId: AthleteId,
        athleteDisplayName: String = "",
        todayActivityComposer: TodayActivityComposer? = nil
    ) {
        self.trainingService = trainingService
        self.coordinationService = coordinationService
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

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try trainingService.logActivity(
                athleteId: athleteId,
                plannedActivityId: selectedPlannedActivityId,
                activityType: newLogActivityType,
                title: newLogTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                startedAt: newLogStartedAt,
                durationMinutes: newLogDurationMinutes,
                perceivedExertion: newLogPerceivedExertion,
                notes: notesOrNil
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
        }
    }
}
