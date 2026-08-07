import Foundation
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// Sprint 1 (Daily Use Foundation), Part 4. Logging starts from Activity
/// Detail with the planned activity already known — athlete, activity,
/// date, and time are never re-asked; only what genuinely only exists
/// after training happened is collected.
///
/// FLAGGED GAP: the brief asks for "Duration, Intensity, RPE, Notes,
/// Completion." `LoggedActivity` (the only persisted shape this can
/// write to, unchanged per this sprint's own persistence constraint)
/// has `durationMinutes`, `perceivedExertion` (RPE), `notes`, and
/// `status` — but no separate "intensity" field distinct from RPE.
/// Rather than silently repurpose a different field or invent one,
/// this form offers RPE only (the field that actually exists) — a
/// genuine data-model gap to close in a future work package if a
/// distinct "intensity" concept is truly wanted, not something to
/// paper over here.
@MainActor
@Observable
public final class LogActivityViewModel {
    public let plannedActivity: PlannedActivity
    public private(set) var errorMessage: String?
    public private(set) var didLog: Bool = false

    public var durationMinutes: Int
    public var perceivedExertion: Int?
    public var notes: String = ""
    public var isCompleted: Bool = true

    private let athleteId: AthleteId
    private let trainingService: TrainingService
    private let onLogged: () -> Void

    public init(
        plannedActivity: PlannedActivity,
        athleteId: AthleteId,
        trainingService: TrainingService,
        onLogged: @escaping () -> Void
    ) {
        self.plannedActivity = plannedActivity
        self.athleteId = athleteId
        self.trainingService = trainingService
        self.onLogged = onLogged
        // Prefilled from the plan itself where a sensible starting
        // value exists — the parent only adjusts if reality differed.
        self.durationMinutes = plannedActivity.plannedDurationMinutes ?? 60
    }

    @discardableResult
    public func save() -> Bool {
        errorMessage = nil
        do {
            _ = try trainingService.logActivity(
                athleteId: athleteId,
                plannedActivityId: plannedActivity.plannedActivityId,
                sportId: plannedActivity.sportId.map(SportId.init(rawValue:)),
                categoryIds: plannedActivity.categoryIds.map(ActivityCategoryId.init(rawValue:)),
                activityType: plannedActivity.activityType,
                title: plannedActivity.title,
                startedAt: Self.startedAt(for: plannedActivity),
                durationMinutes: max(1, min(1440, durationMinutes)),
                status: isCompleted ? .completed : .missed,
                perceivedExertion: perceivedExertion,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
            )
            didLog = true
            onLogged()
            return true
        } catch TrainingServiceError.plannedActivityAlreadyLinked {
            errorMessage = "This activity has already been logged."
            return false
        } catch {
            errorMessage = "Could not save this log. Please try again."
            return false
        }
    }

    /// The planned activity's own date/time, combined into a single
    /// `Date` — `LoggedActivity.startedAt` needs a concrete instant,
    /// and the planned date/time is the best-known one until the
    /// parent says otherwise (which this form doesn't currently ask,
    /// matching "do not ask the parent to reselect... date, time").
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
}
