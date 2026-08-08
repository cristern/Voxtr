import Foundation
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

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
    private let trainingService: TrainingService

    public init(
        activity: PlannedActivity,
        isCompleted: Bool,
        weekPlanId: WeekPlanId,
        athleteId: AthleteId,
        athleteDisplayName: String,
        isWeekPlanDraft: Bool,
        deletedByActorId: ActorId,
        planningService: PlanningService,
        trainingService: TrainingService
    ) {
        self.activity = activity
        self.isCompleted = isCompleted
        self.weekPlanId = weekPlanId
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.isWeekPlanDraft = isWeekPlanDraft
        self.deletedByActorId = deletedByActorId
        self.planningService = planningService
        self.trainingService = trainingService
        prefillEditForm()
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
    public func makeLogActivityViewModel() -> LogActivityViewModel {
        LogActivityViewModel(
            plannedActivity: activity,
            athleteId: athleteId,
            athleteDisplayName: athleteDisplayName,
            trainingService: trainingService,
            onLogged: { [weak self] in
                self?.isCompleted = true
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
