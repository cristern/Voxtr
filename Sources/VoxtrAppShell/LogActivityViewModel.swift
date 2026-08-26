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
///
/// VX-022 (Session Form): the "Form" field — a separate 1-5 self-rating,
/// captured alongside the log and stored as `ActivityReflection.bodyFeeling`
/// via `TrainingReflectionCoordinationService` — not a new field on
/// `LoggedActivity` itself. See that type's own doc comment for the
/// exact atomicity/retry contract `save()` below implements.
///
/// Required for a COMPLETED log (the approved V1 contract: "Form is
/// required for completed training/match/competition logging") —
/// `save()` blocks with `TrainingValidator.validateForm` before
/// anything is created whenever `isCompleted` is true. When logging as
/// NOT completed (`isCompleted == false`, i.e. `.missed`), nothing
/// happened to rate, so Form is not required in that case.
@MainActor
@Observable
public final class LogActivityViewModel {
    public let plannedActivity: PlannedActivity
    public let athleteDisplayName: String
    public private(set) var errorMessage: String?
    public private(set) var didLog: Bool = false
    /// True once a Session Form value was entered but has not yet been
    /// successfully saved (either the first attempt failed, or it
    /// hasn't been attempted). While true, the entered `sessionForm`
    /// value is retained, never discarded — the next `save()` call
    /// retries recording it against the SAME already-logged activity,
    /// never re-logs.
    public private(set) var sessionFormPendingRetry: Bool = false

    /// Planned/Logged Activity lifecycle consistency cleanup: actual
    /// duration is required for a completed log, not required for a
    /// not-completed (missed) one — see `TrainingValidator.validateActualDuration`.
    /// `nil` unless the planned activity itself has a planned duration
    /// (prefilled below as a suggested starting point the parent can
    /// still correct) — never fabricated as a hardcoded fallback the
    /// way this used to default to 60. The saved value is canonical
    /// training truth; it is never re-derived from the plan afterward.
    public var durationMinutes: Int?
    public var perceivedExertion: Int?
    public var notes: String = ""
    public var isCompleted: Bool = true
    /// "Form" in the UI — required when `isCompleted` is true; see this
    /// type's own doc comment.
    public var sessionForm: Int?

    private let athleteId: AthleteId
    private let authorId: ActorId
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    private let onLogged: () -> Void
    /// Review follow-up (blank-screen-after-Save closeout, round 3): a
    /// SEPARATE, optional signal from `onLogged` above — callers with a
    /// mounted screen whose OWN canonical state must be refreshed before
    /// a successful Save can safely let its sheet close
    /// (`ActivityDetailViewModel`, currently the only such caller)
    /// supply this closure; its return value determines whether `save()`
    /// itself reports success, exactly as if refreshing that mounted
    /// state were as load-bearing as the persistence writes above it —
    /// which it is, per the approved contract ("a successful Save that
    /// dismisses the sheet -> mounted Activity Detail already reflects
    /// canonical logged state"). Defaulted to `nil`, treated as an
    /// unconditional success (`?? true`) — `onLogged`'s existing
    /// `() -> Void` contract and every existing construction site
    /// (production and test) keep compiling and behaving unchanged; this
    /// is additive, never a replacement for `onLogged`.
    private let refreshMountedState: (() -> Bool)?
    /// Set once the first `save()` call successfully logs the activity —
    /// from then on, `save()` retries only the Session Form write (see
    /// `sessionFormPendingRetry`) and/or `refreshMountedState` above,
    /// never `logActivity` again, so a retry can never create a
    /// duplicate `LoggedActivity`.
    private var loggedActivityId: LoggedActivityId?

    public init(
        plannedActivity: PlannedActivity,
        athleteId: AthleteId,
        athleteDisplayName: String,
        authorId: ActorId,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        onLogged: @escaping () -> Void,
        refreshMountedState: (() -> Bool)? = nil
    ) {
        self.plannedActivity = plannedActivity
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.authorId = authorId
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.onLogged = onLogged
        self.refreshMountedState = refreshMountedState
        // Prefilled from the plan itself where a sensible starting
        // value exists — the parent only adjusts if reality differed.
        // `nil` (not a fabricated fallback) when the plan itself has no
        // duration; `save()` requires an explicit value before a
        // completed log can succeed.
        self.durationMinutes = plannedActivity.plannedDurationMinutes
    }

    /// Test-only seam (round 4 review follow-up): puts this view model
    /// directly into the exact "already logged, Session Form retry
    /// pending" state a genuine Session Form write failure leaves
    /// behind — the state `save()`'s retry branch (`if let
    /// loggedActivityId`) is written for. No production caller ever
    /// needs this: every real caller reaches that state exclusively
    /// through a genuine failed `save()` call, never by construction.
    /// It exists because a genuine FIRST-attempt Session Form failure
    /// cannot be produced through this type's own public API without
    /// either bypassing `TrainingValidator`'s required (1...5) Form
    /// gate at the call site that matters (undermining the very
    /// validation this fix does not touch) or encoding a domain-invalid
    /// Missed+Form scenario (explicitly disallowed) — this lets a test
    /// exercise the retry branch's real, unvalidated `recordSessionForm`
    /// call directly instead, the same "deliberately out-of-range value"
    /// technique already established elsewhere in this codebase for
    /// simulating a Session Form write failure. Package-internal only —
    /// reachable from tests via `@testable import`, never `public`.
    func presetForFormRetryTesting(loggedActivityId: LoggedActivityId, sessionForm: Int?) {
        self.loggedActivityId = loggedActivityId
        self.sessionFormPendingRetry = true
        self.sessionForm = sessionForm
        self.didLog = true
    }

    @discardableResult
    public func save() -> Bool {
        errorMessage = nil

        if let loggedActivityId {
            // Retry path: the activity itself was already logged
            // successfully on a prior attempt. Never re-invokes
            // logActivity, so this can never create a duplicate
            // `LoggedActivity`. Only the Session Form write is retried
            // here (`sessionFormPendingRetry`) — `finishSave(formFailed:)`
            // below is what always fires `onLogged()` and always attempts
            // `refreshMountedState`, regardless of whether the Form retry
            // itself succeeds, per the review follow-up (round 4) fixed
            // there.
            var formFailed = false
            if sessionFormPendingRetry {
                if let sessionForm {
                    do {
                        _ = try trainingReflectionCoordinationService.recordSessionForm(
                            athleteId: athleteId,
                            loggedActivityId: loggedActivityId,
                            authorId: authorId,
                            bodyFeeling: sessionForm
                        )
                        sessionFormPendingRetry = false
                    } catch {
                        sessionFormPendingRetry = true
                        formFailed = true
                    }
                } else {
                    sessionFormPendingRetry = false
                }
            }
            return finishSave(formFailed: formFailed)
        }

        // Planned/Logged Activity lifecycle consistency cleanup: actual
        // duration is required for a completed log — checked here,
        // before anything is created, mirroring the Form check below
        // exactly. Not required when logging as not completed (missed —
        // nothing happened to measure).
        let outcomeStatus: ActivityStatus = isCompleted ? .completed : .missed
        let durationIsRequired = TrainingValidator.requiresActualDuration(for: outcomeStatus)
        let formIsRequired = TrainingValidator.requiresForm(for: outcomeStatus)
        if let durationError = TrainingValidator.validateActualDuration(durationMinutes, for: outcomeStatus) {
            errorMessage = durationError
            return false
        }

        // VX-022 / review follow-up: Form is required for a COMPLETED
        // log — checked here, before anything is created, so a
        // completed log can never be reported as saved without it. Not
        // required when logging as not completed (nothing happened to
        // rate). Now routed through the SAME status-aware
        // `TrainingValidator.validateForm(_:for:)` the Edit Logged
        // Activity correction path uses, rather than this call site
        // encoding its own separate `isCompleted` exception.
        if let formError = TrainingValidator.validateForm(sessionForm, for: outcomeStatus) {
            errorMessage = formError
            return false
        }

        do {
            let result = try trainingReflectionCoordinationService.logActivity(
                athleteId: athleteId,
                plannedActivityId: plannedActivity.plannedActivityId,
                sportId: plannedActivity.sportId.map(SportId.init(rawValue:)),
                categoryIds: plannedActivity.categoryIds.map(ActivityCategoryId.init(rawValue:)),
                activityType: plannedActivity.activityType,
                title: plannedActivity.title,
                startedAt: Self.startedAt(for: plannedActivity),
                // Review follow-up (duration placeholder audit): when
                // duration is NOT required (missed), `1` — the schema's
                // own documented minimum placeholder — is sent
                // UNCONDITIONALLY, never whatever happens to be sitting
                // in `durationMinutes` (commonly the plan's own
                // prefilled value, still present if the parent flipped
                // "Completed" off without clearing the field). Sending
                // that value here would fabricate a specific, plausible
                // "actual" duration for a session that never happened —
                // exactly what the placeholder convention exists to
                // prevent. Only genuinely required (completed) values —
                // validated above, so guaranteed non-nil and in range —
                // are ever sent through as entered.
                durationMinutes: durationIsRequired ? (durationMinutes.map { max(1, min(1440, $0)) } ?? 1) : 1,
                status: outcomeStatus,
                perceivedExertion: perceivedExertion,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes,
                authorId: authorId,
                // Review follow-up (Form-leak audit): mirrors the
                // duration gate immediately above exactly. Switching the
                // Outcome picker from Completed to Missed does not clear
                // `sessionForm` in the View (only the duration picker is
                // hidden for Missed) — a value entered while Completed
                // was selected would otherwise still be sitting in
                // `sessionForm` here and get recorded as this Missed
                // log's Form rating, even though nothing happened to
                // rate. `TrainingReflectionCoordinationService.logActivity`
                // records whatever non-nil value it is given regardless
                // of `status`, so this call site — not that shared
                // primitive — is where "Form does not apply to this
                // outcome" must be enforced.
                sessionForm: formIsRequired ? sessionForm : nil
            )
            self.loggedActivityId = result.loggedActivity.loggedActivityId
            if !formIsRequired {
                // Review follow-up (Form-leak audit): also clears the
                // local edit state, not just what was sent above — a
                // defensive re-invocation of save() would otherwise hit
                // the retry branch further up, which reads THIS property
                // directly and would resurrect the stale value against
                // the LoggedActivity just created as Missed.
                sessionForm = nil
            }
            didLog = true

            let formFailed: Bool
            switch result.sessionFormOutcome {
            case .notRequested, .saved:
                sessionFormPendingRetry = false
                formFailed = false
            case .failed:
                sessionFormPendingRetry = true
                formFailed = true
            }

            return finishSave(formFailed: formFailed)
        } catch TrainingServiceError.plannedActivityAlreadyLinked {
            errorMessage = "This activity has already been logged."
            return false
        } catch {
            errorMessage = "Could not save this log. Please try again."
            return false
        }
    }

    /// Review follow-up (round 4): the exact regression the review
    /// caught — once the base `LoggedActivity` itself has genuinely
    /// persisted, `onLogged()` and `refreshMountedState()` must ALWAYS
    /// run, even when Session Form persistence failed (or is still
    /// pending retry). Before this fix, a Form failure returned early
    /// and skipped both — so a user who logged successfully, hit a Form
    /// failure, then chose Cancel instead of retrying, would leave the
    /// mounted Activity Detail (and the parent surface behind it) never
    /// told the activity was logged at all: a genuine One Truth
    /// violation, since the canonical `LoggedActivity` already exists.
    /// Called from BOTH the initial-log path and the retry path, each of
    /// which independently determines whether Form itself failed on
    /// THIS pass — this function's only job is what happens after that:
    /// fire both signals unconditionally, then decide `save()`'s own
    /// result from whichever of the two independent outcomes (Form,
    /// mounted refresh) is worse, without ever fabricating success for
    /// either. `sessionFormPendingRetry` (set by the caller before this
    /// runs) and `refreshMountedState` being a pure, idempotent read are
    /// what make a subsequent retry safe here — this function itself
    /// never re-invokes `logActivity` or `recordSessionForm`.
    private func finishSave(formFailed: Bool) -> Bool {
        onLogged()
        let refreshSucceeded = refreshMountedState?() ?? true
        switch (formFailed, refreshSucceeded) {
        case (true, false):
            errorMessage = "Activity logged. Form could not be saved and the screen could not refresh — tap Save to try again."
            return false
        case (true, true):
            errorMessage = "Activity logged. Form could not be saved — tap Save to try again."
            return false
        case (false, false):
            errorMessage = "Activity logged. Could not refresh — tap Save to try again."
            return false
        case (false, true):
            return true
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
