import Foundation
import VoxtrCoreContracts
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// VX-022 (Session Form): whether the optional 1-5 Session Form value
/// entered alongside a log was recorded. `.notRequested` when no value
/// was entered at all (Session Form is optional — see
/// `TrainingReflectionCoordinationService.logActivity`'s own doc
/// comment). `.failed` carries whatever `ReflectionService` threw, for
/// display/retry — never silently discarded.
public enum SessionFormOutcome {
    case notRequested
    case saved(ActivityReflection)
    case failed(Error)
}

/// VX-022: the result of `TrainingReflectionCoordinationService.logActivity` —
/// the `LoggedActivity` this call created (always present; logging
/// itself either fully succeeds or throws, same as `TrainingService.logActivity`
/// always has), paired with what happened to the optional Session Form
/// value.
public struct LoggedActivityWithSessionForm {
    public let loggedActivity: LoggedActivity
    public let sessionFormOutcome: SessionFormOutcome

    public init(loggedActivity: LoggedActivity, sessionFormOutcome: SessionFormOutcome) {
        self.loggedActivity = loggedActivity
        self.sessionFormOutcome = sessionFormOutcome
    }
}

/// VX-022 (Session Form): the one place `TrainingService` (Training) and
/// `ReflectionService` (Reflection) are used together to log a completed
/// activity together with its optional 1-5 Session Form self-rating —
/// same reasoning `TrainingPlanningCoordinationService`/
/// `WeeklyReviewCoordinationService` already established for their own
/// cross-domain pairs. Session Form itself introduces no new entity or
/// persistence model: it is stored as the existing
/// `ActivityReflection.bodyFeeling`, through the existing
/// `ReflectionService.recordActivityReflection` path, linked to the
/// exact `LoggedActivity` this call creates by its stable, typed ID —
/// never by title/date matching.
///
/// ATOMICITY: logging a `LoggedActivity` and recording its
/// `ActivityReflection` are two separate SwiftData writes — this
/// architecture has no cross-domain transaction spanning both
/// `TrainingRepository` and `ReflectionRepository`. `logActivity` below
/// reflects that honestly rather than pretending otherwise:
/// - If the `LoggedActivity` write itself fails, nothing is created and
///   the error propagates normally (unchanged from calling
///   `TrainingService.logActivity` directly).
/// - If it succeeds but the Session Form write fails, the
///   `LoggedActivity` is preserved (never rolled back) and the result
///   reports `.failed` instead of throwing — callers must retry ONLY
///   `recordSessionForm` below, against the SAME `LoggedActivityId`
///   this call already produced, never call `logActivity` again for the
///   same attempt. That is what prevents a retry from ever creating a
///   duplicate `LoggedActivity`.
@MainActor
public final class TrainingReflectionCoordinationService {
    private let trainingService: TrainingService
    private let reflectionService: ReflectionService

    public init(trainingService: TrainingService, reflectionService: ReflectionService) {
        self.trainingService = trainingService
        self.reflectionService = reflectionService
    }

    /// Logs a completed activity through the canonical `TrainingService.logActivity`
    /// path, then — only if `sessionForm` is non-nil — records it as
    /// `ActivityReflection.bodyFeeling` via `ReflectionService.recordActivityReflection`,
    /// linked to the just-created `LoggedActivity`'s own ID. `sessionForm`
    /// is optional, matching the same optional-numeric-rating pattern
    /// `LoggedActivity.perceivedExertion` (RPE) already establishes for
    /// this exact logging flow — omitting it never blocks logging the
    /// activity itself.
    public func logActivity(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId? = nil,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        activityType: ActivityType,
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        durationMinutes: Int = 1,
        status: ActivityStatus = .completed,
        perceivedExertion: Int? = nil,
        source: String = "manual",
        notes: String? = nil,
        authorId: ActorId,
        sessionForm: Int?,
        sessionFormVisibility: VisibilityPolicy = .privateToAthlete
    ) throws -> LoggedActivityWithSessionForm {
        let loggedActivity = try trainingService.logActivity(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            sportId: sportId,
            categoryIds: categoryIds,
            activityType: activityType,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMinutes: durationMinutes,
            status: status,
            perceivedExertion: perceivedExertion,
            source: source,
            notes: notes
        )

        guard let sessionForm else {
            return LoggedActivityWithSessionForm(loggedActivity: loggedActivity, sessionFormOutcome: .notRequested)
        }

        do {
            let reflection = try recordSessionForm(
                athleteId: athleteId,
                loggedActivityId: loggedActivity.loggedActivityId,
                authorId: authorId,
                bodyFeeling: sessionForm,
                visibility: sessionFormVisibility
            )
            return LoggedActivityWithSessionForm(loggedActivity: loggedActivity, sessionFormOutcome: .saved(reflection))
        } catch {
            return LoggedActivityWithSessionForm(loggedActivity: loggedActivity, sessionFormOutcome: .failed(error))
        }
    }

    /// The retry path after a `.failed` Session Form outcome: records
    /// Session Form against an ALREADY-existing `LoggedActivity` by ID —
    /// never creates one. Also the only entry point callers need for
    /// "log now, add Session Form later" if that ever becomes a real
    /// flow, though nothing in this package's scope adds such a UI.
    @discardableResult
    public func recordSessionForm(
        athleteId: AthleteId,
        loggedActivityId: LoggedActivityId,
        authorId: ActorId,
        bodyFeeling: Int,
        visibility: VisibilityPolicy = .privateToAthlete
    ) throws -> ActivityReflection {
        try reflectionService.recordActivityReflection(
            athleteId: athleteId,
            loggedActivityId: loggedActivityId,
            authorId: authorId,
            visibility: visibility,
            bodyFeeling: bodyFeeling
        )
    }
}
