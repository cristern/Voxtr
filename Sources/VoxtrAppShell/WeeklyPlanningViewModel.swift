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
    /// exists yet, then loads its activities. Call once when the view
    /// appears.
    public func loadOrCreateWeekPlan() {
        errorMessage = nil
        do {
            let plan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
            weekPlan = plan
            try reloadActivities(for: plan)
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
            try service.deletePlannedActivity(activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId)
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
        case .plannedActivityNotFound, .plannedActivityDoesNotBelongToWeekPlan:
            return PlanningStrings.genericServiceError
        }
    }
}
