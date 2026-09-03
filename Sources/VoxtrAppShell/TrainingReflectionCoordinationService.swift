import Foundation
import SwiftData
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

/// VX-022 closeout (Activity Detail): the `LoggedActivity` for a given
/// `PlannedActivity`, paired with its `ActivityReflection` if one
/// exists — both fetched purely by stable typed-ID relationship, never
/// by title/date matching. `reflection` is the raw, unfiltered entity;
/// visibility gating (e.g. `.privateToAthlete`) is the caller's job,
/// same separation `WeeklyReviewResult`/`PlannedActivityCompletion`
/// already establish (assemble canonical data here, enforce privacy at
/// the point of display).
public struct LoggedActivityDetail {
    public let loggedActivity: LoggedActivity
    public let reflection: ActivityReflection?

    public init(loggedActivity: LoggedActivity, reflection: ActivityReflection?) {
        self.loggedActivity = loggedActivity
        self.reflection = reflection
    }
}

/// VX-022 (Session Form): the one place `TrainingService` (Training) and
/// `ReflectionService` (Reflection) are used together to log a completed
/// activity together with its 1-5 Session Form self-rating — same
/// reasoning `TrainingPlanningCoordinationService`/
/// `WeeklyReviewCoordinationService` already established for their own
/// cross-domain pairs. Session Form itself introduces no new entity or
/// persistence model: it is stored as the existing
/// `ActivityReflection.bodyFeeling`, through the existing
/// `ReflectionService.recordActivityReflection` path, linked to the
/// exact `LoggedActivity` this call creates by its stable, typed ID —
/// never by title/date matching.
///
/// `sessionForm` on `logActivity` below stays `Int?` at THIS layer —
/// this type is a reusable "log, then optionally attach a reflection"
/// primitive, not itself the place that owns the V1 product policy of
/// requiring Form. The approved V1 contract ("Form is required for
/// completed training/match/competition logging") is enforced one
/// layer up, at the UI/orchestration boundary
/// (`TrainingValidator.validateForm`, called by `LogActivityViewModel.save()`
/// and `DailyTrainingViewModel.logActivity()` before this method is
/// ever invoked) — never here, and never by making
/// `ActivityReflection.bodyFeeling` itself non-optional, since
/// `ActivityReflection` also carries reflection content unrelated to
/// Session Form (energy, satisfaction, free text) that has no
/// bodyFeeling at all.
///
/// VISIBILITY: `sessionFormVisibility` defaults to `.sharedWithGuardians`,
/// not `.privateToAthlete`. Investigated before choosing this: neither
/// `AthleteSettings.defaultReflectionVisibility` nor
/// `PrivacyPreference.defaultReflectionVisibility` (the two schema-level
/// settings that exist for exactly this) has ANY repository or service
/// method exposing it anywhere in this codebase — both are
/// schema-registered but otherwise fully unreachable, so there is no
/// existing canonical resolver to call without building new plumbing,
/// which is explicitly out of scope for VX-022. `.sharedWithGuardians`
/// is the documented family-first MVP default, and is also the one
/// real, already-established default elsewhere in this exact domain
/// package (`ReflectionRepository.insertParentObservation`/
/// `ParentObservation`'s own default) — `WeeklyReflectionFormViewModel`'s
/// local `.privateToAthlete` choice is a single form's own decision, not
/// a canonical policy source, and is deliberately NOT copied here.
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
    public enum ReopenError: Error, Equatable {
        case missingSharedModelContext
        case transactionBoundaryUnavailable
    }

    private let trainingService: TrainingService
    private let reflectionService: ReflectionService
    private let modelContext: ModelContext?
    /// Recurring reopen stale-Athlete-Home fix (architecture round): the
    /// single fan-out point told "athlete X's canonical activity state
    /// changed" after each of this type's three mutating methods below
    /// succeeds — never on a thrown failure, and never for the Session
    /// Form sub-write alone (see each call site's own placement).
    /// Optional and defaulted to `nil` so the many existing construction
    /// sites (production and test) that predate this feature don't all
    /// need updating — this coordinator's own mutations remain fully
    /// correct with no broadcaster present, they simply notify no one.
    private let activityChangeBroadcaster: AthleteActivityChangeBroadcaster?

    public init(
        trainingService: TrainingService,
        reflectionService: ReflectionService,
        activityChangeBroadcaster: AthleteActivityChangeBroadcaster? = nil,
        modelContext: ModelContext? = nil
    ) {
        self.trainingService = trainingService
        self.reflectionService = reflectionService
        self.activityChangeBroadcaster = activityChangeBroadcaster
        self.modelContext = modelContext
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
        title: String?,
        startedAt: Date,
        endedAt: Date? = nil,
        durationMinutes: Int = 1,
        status: ActivityStatus = .completed,
        perceivedExertion: Int? = nil,
        source: String = "manual",
        notes: String? = nil,
        authorId: ActorId,
        sessionForm: Int?,
        sessionFormVisibility: VisibilityPolicy = .sharedWithGuardians
    ) throws -> LoggedActivityWithSessionForm {
        // Athlete Connection Foundation A: `authorId` was already
        // required here (used for the Session Form's `ActivityReflection
        // .authorId` below) — now ALSO forwarded into Training's own
        // `loggedByActorId`, so the one actor this caller already
        // supplies attributes both canonical records it can produce,
        // rather than Training silently having none while Reflection
        // already had one.
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
            notes: notes,
            loggedByActorId: authorId
        )
        // The canonical write already succeeded — broadcast now,
        // regardless of the Session Form sub-write's own outcome below
        // (it never affects outcomeStatus/isCompleted, the fields live
        // TodayActivityRow/FamilyHomeRow presentation actually reads).
        activityChangeBroadcaster?.activityChanged(for: athleteId)

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
        visibility: VisibilityPolicy = .sharedWithGuardians
    ) throws -> ActivityReflection {
        try reflectionService.recordActivityReflection(
            athleteId: athleteId,
            loggedActivityId: loggedActivityId,
            authorId: authorId,
            visibility: visibility,
            bodyFeeling: bodyFeeling
        )
    }

    /// VX-022 closeout (Activity Detail): the read-side counterpart to
    /// `logActivity` above — resolves the `LoggedActivity` for a
    /// `PlannedActivity` (via `TrainingService.fetchLoggedActivities(forPlannedActivity:)`,
    /// the same canonical relationship lookup `TrainingPlanningCoordinationService`
    /// already derives completion from) and, if one exists, its linked
    /// `ActivityReflection` (via `ReflectionService.fetchActivityReflection(forLoggedActivity:)`).
    /// `nil` when no `LoggedActivity` exists yet — not an error, the
    /// same "nothing to show yet" meaning used throughout this
    /// codebase. A `LoggedActivityId` is a globally unique typed ID
    /// scoped to exactly one athlete, so this lookup can never surface
    /// another athlete's or another activity's data.
    public func loggedActivityDetail(forPlannedActivity plannedActivityId: PlannedActivityId) throws -> LoggedActivityDetail? {
        guard let loggedActivity = try trainingService.fetchLoggedActivities(forPlannedActivity: plannedActivityId).first else {
            return nil
        }
        let reflection = try reflectionService.fetchActivityReflection(forLoggedActivity: loggedActivity.loggedActivityId)
        return LoggedActivityDetail(loggedActivity: loggedActivity, reflection: reflection)
    }

    /// Resolves one exact logged result for review, including standalone
    /// manual logs that have no PlannedActivity relationship.
    public func loggedActivityDetail(
        loggedActivityId: LoggedActivityId,
        athleteId: AthleteId
    ) throws -> LoggedActivityDetail {
        let loggedActivity = try trainingService.fetchLoggedActivity(
            byId: loggedActivityId,
            athleteId: athleteId
        )
        let reflection = try reflectionService.fetchActivityReflection(forLoggedActivity: loggedActivityId)
        return LoggedActivityDetail(loggedActivity: loggedActivity, reflection: reflection)
    }

    /// Planned/Logged Activity lifecycle consistency cleanup (Edit
    /// Logged Activity -> RPE + Form), extended by review follow-up to
    /// also correct actual duration: the correction counterpart to
    /// `logActivity` — corrects duration and RPE on the `LoggedActivity`
    /// itself, and creates-or-updates the linked `ActivityReflection`'s
    /// Form value, reusing the SAME `LoggedActivityWithSessionForm`/
    /// `SessionFormOutcome` result shape `logActivity` already returns
    /// rather than inventing a second one.
    ///
    /// IMPORTANT — Form contract: unlike RPE (never required),
    /// `sessionForm` here follows the EXACT SAME canonical rule as
    /// initial logging (`TrainingValidator.requiresForm(for:)`): when
    /// the `LoggedActivity`'s own `status` is `.completed`/
    /// `.partiallyCompleted`, this method does NOT itself enforce that
    /// rule (services stay free of UI-layer validation, same separation
    /// `logActivity` already establishes) — the caller
    /// (`ActivityDetailViewModel.saveLoggedActivityEdit()`) is
    /// responsible for calling `TrainingValidator.validateForm(_:for:)`
    /// BEFORE this method runs, exactly mirroring how
    /// `LogActivityViewModel.save()` already validates before calling
    /// `logActivity`. This method must never be the only thing standing
    /// between a completed activity and a cleared Form value.
    ///
    /// `sessionForm: nil` when a reflection ALREADY exists clears its
    /// Form rating back to unset — the reflection itself is not
    /// deleted, since other reflection content (energy/satisfaction/
    /// notes) may still exist on it. `sessionForm: nil` when NO
    /// reflection exists yet (a legacy logged activity, or one logged
    /// as not-completed where Form was never required) creates nothing —
    /// "do not fabricate values": a log with no Form entered stays that
    /// way until the user actually enters one.
    ///
    /// Athlete-scoped throughout — never touches a `LoggedActivity`/
    /// `ActivityReflection` belonging to a different athlete.
    @discardableResult
    public func correctLoggedActivity(
        loggedActivityId: LoggedActivityId,
        athleteId: AthleteId,
        authorId: ActorId,
        durationMinutes: Int,
        perceivedExertion: Int?,
        sessionForm: Int?,
        sessionFormVisibility: VisibilityPolicy = .sharedWithGuardians
    ) throws -> LoggedActivityWithSessionForm {
        let loggedActivity = try trainingService.correctLoggedActivity(
            loggedActivityId,
            athleteId: athleteId,
            durationMinutes: durationMinutes,
            perceivedExertion: perceivedExertion
        )
        // Same placement reasoning as logActivity above: the canonical
        // duration/RPE write already succeeded, independent of the
        // Form sub-write below.
        activityChangeBroadcaster?.activityChanged(for: athleteId)

        if let existingReflection = try reflectionService.fetchActivityReflection(forLoggedActivity: loggedActivityId) {
            do {
                let updated = try reflectionService.updateActivityReflection(
                    existingReflection.reflectionId,
                    athleteId: athleteId,
                    bodyFeeling: sessionForm
                )
                return LoggedActivityWithSessionForm(loggedActivity: loggedActivity, sessionFormOutcome: .saved(updated))
            } catch {
                return LoggedActivityWithSessionForm(loggedActivity: loggedActivity, sessionFormOutcome: .failed(error))
            }
        }

        guard let sessionForm else {
            return LoggedActivityWithSessionForm(loggedActivity: loggedActivity, sessionFormOutcome: .notRequested)
        }

        do {
            let reflection = try recordSessionForm(
                athleteId: athleteId,
                loggedActivityId: loggedActivityId,
                authorId: authorId,
                bodyFeeling: sessionForm,
                visibility: sessionFormVisibility
            )
            return LoggedActivityWithSessionForm(loggedActivity: loggedActivity, sessionFormOutcome: .saved(reflection))
        } catch {
            return LoggedActivityWithSessionForm(loggedActivity: loggedActivity, sessionFormOutcome: .failed(error))
        }
    }

    /// Reversibility principle (Reopen Activity): a pure passthrough to
    /// `TrainingService.reopenNoTrainingOutcome`, while coordinating a
    /// real cross-domain SwiftData unit of work. Reflection stages its
    /// owned reflection deletion and Training stages its owned logged
    /// outcome deletion in the same verified `ModelContext`; one save
    /// commits both, while any failure rolls both back. The planned
    /// activity is never touched, and invalidation is emitted only after
    /// the shared commit succeeds.
    public func reopenNoTrainingOutcome(_ loggedActivityId: LoggedActivityId, athleteId: AthleteId) throws {
        try reopenNoTrainingOutcome(loggedActivityId, athleteId: athleteId, failAt: nil, saveOverride: nil)
    }

    enum ReopenFailurePoint {
        case beforeReflectionDeletion
        case afterReflectionDeletion
    }

    struct SimulatedReopenFailure: Error {}

    func reopenNoTrainingOutcome(
        _ loggedActivityId: LoggedActivityId,
        athleteId: AthleteId,
        failAt: ReopenFailurePoint?,
        saveOverride: (() throws -> Void)? = nil
    ) throws {
        guard let modelContext,
              trainingService.uses(modelContext: modelContext),
              reflectionService.uses(modelContext: modelContext) else {
            throw ReopenError.missingSharedModelContext
        }
        // A ModelContext save/rollback covers every pending mutation in
        // that context. Reopen may therefore claim this transaction
        // boundary only while it is clean: saving first would commit
        // another workflow's work, while rolling back later could erase
        // it. Refuse before fetching/staging anything and leave the
        // existing pending state entirely untouched.
        guard !modelContext.hasChanges else {
            throw ReopenError.transactionBoundaryUnavailable
        }
        let detail = try loggedActivityDetail(loggedActivityId: loggedActivityId, athleteId: athleteId)
        guard detail.loggedActivity.status == .cancelled || detail.loggedActivity.status == .missed else {
            throw TrainingServiceError.activityNotReopenable
        }

        let previousAutosaveSetting = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        defer { modelContext.autosaveEnabled = previousAutosaveSetting }

        do {
            if failAt == .beforeReflectionDeletion { throw SimulatedReopenFailure() }
            if let reflection = detail.reflection {
                try reflectionService.stageDeleteActivityReflection(
                    reflection.reflectionId,
                    athleteId: athleteId
                )
            }
            if failAt == .afterReflectionDeletion { throw SimulatedReopenFailure() }
            try trainingService.stageReopenNoTrainingOutcome(loggedActivityId, athleteId: athleteId)
            if let saveOverride {
                try saveOverride()
            } else {
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
            throw error
        }

        activityChangeBroadcaster?.activityChanged(for: athleteId)
    }
}
