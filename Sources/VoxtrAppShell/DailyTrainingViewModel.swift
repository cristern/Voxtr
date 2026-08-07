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
    public var newLogDurationMinutes: Int = 1
    public var newLogPerceivedExertion: Int?
    public var newLogNotes: String = ""
    /// Optional link to a PlannedActivity — the picker in the view only
    /// lets the user select an uncompleted one; this property itself
    /// doesn't enforce that (the view disables completed options, and
    /// `TrainingService` itself rejects a duplicate link regardless).
    public var selectedPlannedActivityId: PlannedActivityId?

    private let trainingService: TrainingService
    private let coordinationService: TrainingPlanningCoordinationService
    public let athleteId: AthleteId

    public init(
        trainingService: TrainingService,
        coordinationService: TrainingPlanningCoordinationService,
        athleteId: AthleteId
    ) {
        self.trainingService = trainingService
        self.coordinationService = coordinationService
        self.athleteId = athleteId
    }

    /// Loads today's planned activities (with completion state) and
    /// today's logged activities. Call once when the view appears, and
    /// again after a successful log to refresh both lists.
    public func load() {
        errorMessage = nil
        do {
            plannedActivities = try coordinationService.todaysPlannedActivitiesWithCompletion(forAthlete: athleteId)
            loggedActivities = try trainingService.fetchTodaysLoggedActivities(forAthlete: athleteId)
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
            newLogDurationMinutes = 1
            selectedPlannedActivityId = nil
            load()
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
