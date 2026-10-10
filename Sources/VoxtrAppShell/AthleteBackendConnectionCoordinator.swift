import Foundation
import os
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrParentDomain

/// Athlete hydration, activation and runtime connection UI integration
/// slice (transition-plan §5.2, task brief
/// `Docs/Tasks/AthleteHydrationActivationIntegration-2026-10-10.md`).
///
/// NAMED DISTINCTLY from `AthleteRuntimeSession` (the unrelated,
/// unmodified CKShare-acceptance runtime-presence holder — see that
/// type's own doc comment and the runtime contract's own §0 naming
/// note) and from `AthleteDeviceAuthorizationPairingCoordinator` (the
/// SEPARATE, already-shipped claim-submit pairing state machine this
/// coordinator picks up exactly where that one ends —
/// `.authorized(grantId:)`). This is the ONE orchestrator for
/// everything after that point: hydration → canonical
/// acceptance/binding/activation, then ongoing restoration/online
/// validation, for the backend device-authorization path specifically.
///
/// ORCHESTRATION ONLY — reuses, never duplicates, every existing
/// canonical collaborator: `AthleteBackendHydrationAdapter` (hydration),
/// `AcceptWorkspaceInvitationService` (the sole `.invited → .active`
/// transition), `AthleteConnectionIdentityBindingService` (B2.3, exact-ID
/// binding), `AthleteSessionActivationService` (B2.4, revalidate +
/// resolve `CurrentSessionActor`), `AthleteDeviceAuthorizationSessionManager`
/// (session issuance/renewal policy, including this task's own new
/// `ensureFreshlyVerifiedSession(deviceGrantId:)` seam). The sequencing
/// below mirrors `AthleteConnectionLifecycleService`'s own established
/// hydrate → accept → bind → activate chain for the legacy CKShare path
/// — same shape, different transport/entry point, never a second
/// implementation of any of those four steps.
///
/// LOCAL CHECKPOINT, NEVER A SECOND IDENTITY SOURCE: persists only the
/// minimum stable IDs needed to re-attempt LOCAL re-validation on a
/// later relaunch/foreground — see `AthleteBackendConnectionCheckpointStore`'s
/// own doc comment for exactly why this is needed and what it is not.
/// Written ONLY after `bind`/`activate` have ALREADY succeeded for this
/// exact attempt — never before, and never on any failure path — so a
/// saved checkpoint is always backed by a real, already-confirmed local
/// activation, never a hopeful guess.
///
/// FOUR HONEST STATES (CloudKit transition plan §4.6), never collapsed:
/// `.connected(_, verified: true)` is state 2 (freshly verified this
/// launch/foreground cycle, via a genuine `session_issue`/`session_renew`
/// round trip); `.connected(_, verified: false)` is state 3 (cached,
/// unverified — D3's calm "connection cannot be verified," no new
/// protected sync); `.grantRevoked` is the SPECIFIC "Parent has revoked"
/// outcome (the permanent hydration-outcome marker, reachable only from
/// a hydration call); `.connectionUnavailable` is the NEUTRAL
/// "connection unavailable, re-approval required" outcome for
/// `SessionFailure.grantUnavailable`, which — per the transition plan's
/// own correction — is NOT itself proof of a Parent revocation. Every
/// other case names its own distinct, honest reason (hydration window
/// expiry, installation-key loss, a not-yet-confirmed ack, a transient
/// network/configuration failure, or a genuine local graph/persistence
/// problem) rather than folding into either of those two.
///
/// CANCELLATION + GENERATIONS: mirrors `AthleteDeviceAuthorizationPairingCoordinator`'s
/// own OWNED CANCELLATION pattern exactly — one owned `Task`, one
/// `generation` counter bumped by every new attempt/explicit
/// cancel/sign-out, `isCurrent(_:)` rechecked after every single
/// `await` before touching `state` or persisted storage. A newer
/// attempt (a fresh `activate(deviceGrantId:)` for a replaced
/// selection, an explicit sign-out, the screen disappearing) can never
/// be overwritten by an older one's late-arriving result.
@MainActor
@Observable
public final class AthleteBackendConnectionCoordinator {

    public enum State: Equatable {
        case idle
        case activating
        /// `verified == true`: state 2 (freshly verified this
        /// launch/foreground cycle). `verified == false`: state 3
        /// (cached/unverified, D3) — the actor/local rows remain
        /// viewable, but no new protected sync is attempted while in
        /// this state.
        case connected(CurrentSessionActor, verified: Bool)
        /// First-time activation genuinely succeeded this exact attempt
        /// (accept/bind/activate all committed for real) but the local
        /// checkpoint needed to resume a LATER `.alreadyCompleted`
        /// hydration response could not be saved (PR #120 R4) — unlike
        /// `AthleteDeviceAuthorizationSessionManager`'s own session-save
        /// failures (wasteful but never incorrect, since a fresh
        /// `session_issue` is always possible again), a missing
        /// checkpoint here is a genuine future restorability gap: the
        /// GET step's permanent-marker short-circuit returns no payload
        /// (`AthleteBackendHydrationOutcome.alreadyCompleted`'s own doc
        /// comment), so a relaunch before this installation's next
        /// successful ACK would otherwise have nothing to resume from
        /// and would show `.recoveryRequired` instead. Never collapsed
        /// into plain `.connected`, which would promise a restorability
        /// guarantee this attempt could not actually keep; the `actor`
        /// is still genuinely usable right now.
        case connectedButCheckpointUnsaved(CurrentSessionActor, verified: Bool)
        /// The SPECIFIC, unambiguous "Parent has revoked" outcome —
        /// reachable only from the hydration lifecycle's own permanent
        /// `hydration_outcome = 'revoked'` marker. Never produced by a
        /// mere `SessionFailure.grantUnavailable`.
        case grantRevoked
        /// The NEUTRAL "connection unavailable, re-approval required"
        /// outcome — `SessionFailure.grantUnavailable`, which per the
        /// transition plan's own correction is NOT itself proof of a
        /// Parent revocation (it also covers a rejected presented
        /// session). Never worded as if the Parent definitely acted.
        case connectionUnavailable
        /// Nothing uploaded yet for this grant, or a transient
        /// non-security-sensitive hydration fold — retryable, never a
        /// security conclusion.
        case waitingForParentApproval
        /// The fixed D2 hydration recovery deadline has passed — a
        /// different clock from session/grant expiry, never worded as
        /// either of those.
        case hydrationWindowExpired
        /// This installation's signing key/marker no longer matches —
        /// reinstall or orphaned Keychain material. Requires fresh
        /// pairing; never silently replaced with a new key.
        case installationKeyUnavailable
        /// Local hydration already committed real rows THIS attempt,
        /// but the immediately-following ack did not confirm — safely
        /// retryable (the local upsert is idempotent-resumable); never
        /// represented as a completed connection.
        case ackNotConfirmed
        /// A transport/configuration-layer outcome (network,
        /// malformed response, missing gateway configuration) —
        /// never evidence of any Parent action.
        case temporarilyUnavailable
        /// A genuine local problem: the local graph no longer supports
        /// a checkpoint this installation previously trusted (e.g. the
        /// participant was removed/re-linked/conflicts since), or the
        /// server reports hydration already complete but this
        /// installation holds no matching local checkpoint to resume
        /// from — `.alreadyCompleted` cannot fabricate lost bootstrap
        /// data, so this is surfaced honestly as a recovery/re-approval
        /// requirement rather than invented success.
        case recoveryRequired
    }

    public private(set) var state: State = .idle

    private let hydrationAdapter: AthleteBackendHydrating
    private let sessionManager: AthleteFreshSessionVerifying
    private let athleteRepository: AthleteRepository
    private let acceptanceService: AcceptWorkspaceInvitationService
    private let identityBindingService: AthleteConnectionIdentityBindingService
    private let sessionActivationService: AthleteSessionActivating
    private let checkpointStore: AthleteBackendConnectionCheckpointStoring
    private let log = VoxtrLog.logger(.appShell)

    private var currentTask: Task<Void, Never>?
    private var generation = 0

    public init(
        hydrationAdapter: AthleteBackendHydrating,
        sessionManager: AthleteFreshSessionVerifying,
        athleteRepository: AthleteRepository,
        acceptanceService: AcceptWorkspaceInvitationService,
        identityBindingService: AthleteConnectionIdentityBindingService,
        sessionActivationService: AthleteSessionActivating,
        checkpointStore: AthleteBackendConnectionCheckpointStoring = KeychainAthleteBackendConnectionCheckpointStore()
    ) {
        self.hydrationAdapter = hydrationAdapter
        self.sessionManager = sessionManager
        self.athleteRepository = athleteRepository
        self.acceptanceService = acceptanceService
        self.identityBindingService = identityBindingService
        self.sessionActivationService = sessionActivationService
        self.checkpointStore = checkpointStore
    }

    /// Entry point 1: called once `AthleteDeviceAuthorizationPairingCoordinator`
    /// reaches `.authorized(grantId:)` — the first-time hydration →
    /// accept → bind → activate chain for a brand-new (or resumed)
    /// grant. Cancels any in-flight attempt first, exactly like a fresh
    /// scan always starting a new pairing attempt.
    public func activate(deviceGrantId: UUID) {
        startNewAttempt { [weak self] myGeneration in
            await self?.runActivation(deviceGrantId: deviceGrantId, myGeneration: myGeneration)
        }
    }

    /// Entry point 2: called on every AthleteApp launch and foreground
    /// (§5.2) — never takes a `deviceGrantId` parameter, since nothing
    /// external hands one in at that moment; it is derived from this
    /// installation's own persisted checkpoint. No-op (stays `.idle`)
    /// if no checkpoint exists — nothing to restore, never fabricated.
    public func restoreOnLaunchOrForeground() {
        guard let checkpoint = checkpointStore.loadCheckpoint() else {
            cancelCurrentAttempt()
            state = .idle
            return
        }
        startNewAttempt { [weak self] myGeneration in
            await self?.runRestoration(checkpoint: checkpoint, myGeneration: myGeneration)
        }
    }

    /// Cancels any in-flight work without changing `state` or touching
    /// persisted storage — mirrors
    /// `AthleteDeviceAuthorizationPairingCoordinator.cancel()`'s own
    /// "screen disappeared" semantics exactly: a merely-dismissed
    /// screen is not the Athlete discarding anything.
    public func cancel() {
        cancelCurrentAttempt()
    }

    /// Explicit sign-out/invalidation: cancels in-flight work, clears
    /// both the local checkpoint and the device-authorization session
    /// manager's own stored session, and returns to `.idle`. Never
    /// deletes the hydrated SwiftData rows themselves (§4.6/§4.5 of the
    /// CloudKit transition plan: local business data is never erased
    /// by a runtime-state correction).
    public func signOutOrInvalidate() {
        cancelCurrentAttempt()
        checkpointStore.clearCheckpoint()
        sessionManager.clearStoredSession()
        state = .idle
    }

    private func cancelCurrentAttempt() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
    }

    private func startNewAttempt(_ operation: @escaping (Int) async -> Void) {
        cancelCurrentAttempt()
        let myGeneration = generation
        state = .activating
        currentTask = Task { [weak self] in
            await operation(myGeneration)
            if let self, self.generation == myGeneration {
                self.currentTask = nil
            }
        }
    }

    /// `true` only while THIS call's own attempt is still the current
    /// one and has not been cancelled — checked after every `await`
    /// before touching `state` or persisted storage, matching
    /// `AthleteDeviceAuthorizationPairingCoordinator.isCurrent(_:)`'s
    /// own established pattern exactly.
    private func isCurrent(_ myGeneration: Int) -> Bool {
        !Task.isCancelled && myGeneration == generation
    }

    // MARK: - First-time activation

    private func runActivation(deviceGrantId: UUID, myGeneration: Int) async {
        let outcome: AthleteBackendHydrationOutcome
        do {
            outcome = try await hydrationAdapter.hydrate(deviceGrantId: deviceGrantId)
        } catch {
            guard isCurrent(myGeneration) else { return }
            state = Self.classify(hydrationFailure: error, log: log)
            return
        }
        guard isCurrent(myGeneration) else { return }

        switch outcome {
        case .hydratedAndAcked(let workspaceId, let participantId, let athleteId):
            await completeLocalActivation(
                deviceGrantId: deviceGrantId, workspaceId: workspaceId, participantId: participantId, athleteId: athleteId,
                myGeneration: myGeneration
            )
        case .alreadyCompleted:
            // The GET step's own permanent-marker short-circuit carries
            // no target (see `AthleteBackendHydrationOutcome.alreadyCompleted`'s
            // own doc comment) — resume ONLY from a previously-saved
            // checkpoint for this EXACT grant; never guess a target
            // from whatever family happens to be on this device.
            guard let checkpoint = checkpointStore.loadCheckpoint(), checkpoint.deviceGrantId == deviceGrantId else {
                guard isCurrent(myGeneration) else { return }
                state = .recoveryRequired
                return
            }
            await completeLocalActivation(
                deviceGrantId: deviceGrantId, workspaceId: checkpoint.workspaceId, participantId: checkpoint.participantId,
                athleteId: checkpoint.athleteId, myGeneration: myGeneration
            )
        case .deadlinePassed:
            state = .hydrationWindowExpired
        case .grantRevoked:
            state = .grantRevoked
        case .notYetAvailable:
            state = .waitingForParentApproval
        }
    }

    /// The accept → bind → activate continuation, shared by a fresh
    /// `.hydratedAndAcked` result and an `.alreadyCompleted` result
    /// resumed from a prior checkpoint. Re-fetches eligibility/participant
    /// facts fresh (never trusted from an earlier moment), rejects a
    /// cross-workspace athlete link by construction (see the
    /// `AthleteEligibilityFacts` built below), rejects a bound athlete
    /// that does not match the claimed/checkpointed target (PR #120 R3
    /// — see the explicit guard below), persists the local checkpoint
    /// ONLY after `bind`/`activate` have themselves already succeeded,
    /// and — PR #120 R5 — never labels the result "freshly verified"
    /// from the hydration call alone: `performFreshVerification` always
    /// performs its own genuine `session_issue`/`session_renew` round
    /// trip before this method decides the final `verified` flag,
    /// exactly like the restoration flow's own step 2.
    private func completeLocalActivation(
        deviceGrantId: UUID, workspaceId: UUID, participantId: UUID, athleteId: UUID, myGeneration: Int
    ) async {
        let targetAthleteId = AthleteId(rawValue: athleteId)
        let targetWorkspaceId = WorkspaceId(rawValue: workspaceId)

        let athlete: AthleteProfile?
        do {
            athlete = try athleteRepository.fetchAthlete(byId: targetAthleteId)
        } catch {
            guard isCurrent(myGeneration) else { return }
            log.error("Athlete backend connection: eligibility lookup failed: \(String(describing: error), privacy: .public)")
            state = .recoveryRequired
            return
        }
        guard isCurrent(myGeneration) else { return }

        // Built from the FETCHED athlete's own REAL `workspaceId` —
        // never the claimed/target one — so the eligibility service's
        // own `athleteNotInWorkspace` check genuinely compares "where
        // this athlete actually lives" against "the workspace this
        // grant claims," rather than trivially comparing the claimed
        // value to itself. Re-fetched fresh every call, matching this
        // task's own "re-fetch current eligibility... including actual
        // AthleteProfile.workspaceId" requirement exactly.
        let eligibilityFacts = athlete.map {
            AthleteEligibilityFacts(workspaceId: WorkspaceId(rawValue: $0.workspaceId), isArchived: $0.isArchived)
        }

        switch acceptanceService.accept(athleteId: targetAthleteId, workspaceId: targetWorkspaceId, eligibilityFacts: eligibilityFacts) {
        case .repositoryFailed:
            guard isCurrent(myGeneration) else { return }
            state = .recoveryRequired
            return
        case .accepted, .alreadyAccepted, .invitationNotFound, .invitationRevoked, .invitationDeclined, .notEligible:
            // Every outcome other than a genuine repository failure
            // falls through to `bind`, which independently re-inspects
            // the TRUE persisted participant state and fails with its
            // own explicit, correct case if acceptance did not actually
            // succeed — the same deliberate non-duplication
            // `AthleteConnectionLifecycleService`'s own ACCEPTANCE STEP
            // doc comment establishes for the legacy path.
            break
        }
        guard isCurrent(myGeneration) else { return }

        let bound: BoundAthleteIdentity
        do {
            bound = try identityBindingService.bind(acceptedWorkspaceId: workspaceId, intendedParticipantId: participantId)
        } catch {
            guard isCurrent(myGeneration) else { return }
            log.error("Athlete backend connection: identity binding failed: \(String(describing: error), privacy: .public)")
            state = .recoveryRequired
            return
        }
        guard isCurrent(myGeneration) else { return }

        // R3 (ChatGPT review on PR #120): `bind` matches by
        // `participantId` alone and resolves whatever athlete that
        // participant is CURRENTLY linked to — never trusted here as
        // automatically matching the `athleteId` this call was given
        // (from a fresh hydration payload, or a prior checkpoint). A
        // stale/corrupt checkpoint or a relink since it was saved could
        // otherwise silently activate a DIFFERENT athlete than the one
        // this exact grant names — rejected explicitly, never silently
        // accepted.
        guard bound.athleteId.rawValue == athleteId else {
            guard isCurrent(myGeneration) else { return }
            log.error("Athlete backend connection: bound athlete does not match the claimed target — recovery required")
            state = .recoveryRequired
            return
        }

        let actor: CurrentSessionActor
        do {
            actor = try sessionActivationService.activate(boundIdentity: bound)
        } catch {
            guard isCurrent(myGeneration) else { return }
            log.error("Athlete backend connection: session activation failed: \(String(describing: error), privacy: .public)")
            state = .recoveryRequired
            return
        }
        guard isCurrent(myGeneration) else { return }

        // Write ordering: the checkpoint is attempted ONLY here, after
        // local acceptance/binding/activation have ALL already
        // succeeded for real — never before, and never on any failure
        // path above. R4 (ChatGPT review on PR #120): UNLIKE
        // `AthleteDeviceAuthorizationSessionManager.persist(_:)`'s own
        // save failures (wasteful but never incorrect — a fresh
        // `session_issue` is always possible again), a missing
        // checkpoint here is a genuine future restorability gap — the
        // GET step's permanent-marker short-circuit returns no payload,
        // so a relaunch before this installation's next successful ACK
        // would otherwise have nothing to resume from. Never swallowed
        // via `try?`: surfaced as the distinct `.connectedButCheckpointUnsaved`
        // warning below rather than silently promising a restorability
        // guarantee this attempt could not keep.
        let checkpointSaved: Bool
        do {
            try checkpointStore.saveCheckpoint(AthleteBackendConnectionCheckpoint(
                deviceGrantId: deviceGrantId, workspaceId: workspaceId, participantId: participantId, athleteId: athleteId
            ))
            checkpointSaved = true
        } catch {
            log.error("Athlete backend connection: checkpoint save failed after genuine local activation: \(String(describing: error), privacy: .public)")
            checkpointSaved = false
        }
        guard isCurrent(myGeneration) else { return }

        // R5 (ChatGPT review on PR #120): hydration GET/ACK succeeding
        // never itself proves a genuine `session_issue`/`session_renew`
        // round trip happened THIS attempt — `hydrationAdapter.hydrate(_:)`
        // calls `ensureActiveSession`, whose own intended cached-token
        // fast path may skip the network entirely. "Freshly verified"
        // is only ever earned by `performFreshVerification`'s own
        // explicit, forced round trip — exactly the same check the
        // restoration flow's step 2 performs — never assumed from local
        // success alone.
        switch await performFreshVerification(deviceGrantId: deviceGrantId, myGeneration: myGeneration) {
        case .verified:
            guard isCurrent(myGeneration) else { return }
            state = checkpointSaved ? .connected(actor, verified: true) : .connectedButCheckpointUnsaved(actor, verified: true)
        case .unverified:
            guard isCurrent(myGeneration) else { return }
            state = checkpointSaved ? .connected(actor, verified: false) : .connectedButCheckpointUnsaved(actor, verified: false)
        case .denied(let deniedState):
            guard isCurrent(myGeneration) else { return }
            state = deniedState
        }
    }

    // MARK: - Restoration (launch/foreground)

    private func runRestoration(checkpoint: AthleteBackendConnectionCheckpoint, myGeneration: Int) async {
        // Step 1 (§5.2): present cached/unverified (state 3) FIRST,
        // from a pure, local, no-network re-validation — never
        // silently upgraded to "freshly verified" on the strength of
        // this step alone.
        guard let cachedActor = try? locallyRevalidate(checkpoint: checkpoint) else {
            guard isCurrent(myGeneration) else { return }
            state = .recoveryRequired
            return
        }
        guard isCurrent(myGeneration) else { return }
        state = .connected(cachedActor, verified: false)

        // Step 2 (§5.2's own correction): a GENUINE `session_issue`/
        // `session_renew` round trip — never a hydration call, and
        // never satisfied by `ensureActiveSession()`'s own cached-token
        // fast path. `performFreshVerification` is shared with
        // first-time activation's own identical requirement (R5).
        switch await performFreshVerification(deviceGrantId: checkpoint.deviceGrantId, myGeneration: myGeneration) {
        case .denied(let deniedState):
            guard isCurrent(myGeneration) else { return }
            state = deniedState
            return
        case .unverified:
            // Stay at the cached/unverified presentation already shown
            // in step 1 — a transient/local-generation issue is never
            // itself evidence of denial, and never silently promoted to
            // "verified" either.
            return
        case .verified:
            break
        }
        guard isCurrent(myGeneration) else { return }

        // Online check succeeded — re-validate the LOCAL graph fresh
        // again (never trust the step-1 snapshot) before promoting to
        // "freshly verified."
        guard let freshActor = try? locallyRevalidate(checkpoint: checkpoint) else {
            guard isCurrent(myGeneration) else { return }
            state = .recoveryRequired
            return
        }
        guard isCurrent(myGeneration) else { return }
        state = .connected(freshActor, verified: true)
    }

    /// Shared by first-time activation (R5) and restoration's own step
    /// 2: forces a genuine `session_issue`/`session_renew` round trip
    /// via `ensureFreshlyVerifiedSession`, classifying the result into
    /// exactly one of three outcomes this coordinator itself needs —
    /// never a fourth hidden possibility. Threads this attempt's own
    /// `isCurrent(myGeneration)` through as `isStillWanted` (R2): if a
    /// NEWER attempt has already superseded this one by the time the
    /// forced renew/issue would otherwise submit or persist, the
    /// session manager itself refuses to do either, rather than merely
    /// having its late result ignored here afterward.
    private func performFreshVerification(deviceGrantId: UUID, myGeneration: Int) async -> FreshVerificationOutcome {
        do {
            _ = try await sessionManager.ensureFreshlyVerifiedSession(
                deviceGrantId: deviceGrantId, isStillWanted: { [weak self] in self?.isCurrent(myGeneration) ?? false }
            )
            return .verified
        } catch let failure as AthleteDeviceAuthorizationSessionManager.SessionFailure {
            switch failure {
            case .grantUnavailable:
                // NEUTRAL copy only — never "Parent has revoked" (that
                // specific claim is reachable only via a hydration
                // call's own permanent marker, never this session-only
                // check — see `.connectionUnavailable`'s own doc
                // comment).
                return .denied(.connectionUnavailable)
            case .installationKeyUnavailable:
                return .denied(.installationKeyUnavailable)
            case .network, .malformedResponse, .gatewayConfigurationMissing, .sessionCleared:
                return .unverified
            }
        } catch {
            log.error("Athlete backend connection: unexpected online-validation failure: \(String(describing: error), privacy: .public)")
            return .unverified
        }
    }

    /// Pure, local, no-network re-validation of an already-persisted
    /// checkpoint — reuses B2.3/B2.4 exactly as a fresh activation
    /// would, never a separate "trust the checkpoint" shortcut. Throws
    /// whatever `bind`/`activate` themselves throw if the local graph
    /// no longer supports this checkpoint (participant
    /// removed/revoked/re-linked since it was saved), or
    /// `CheckpointAthleteMismatchError` (R3) if the participant this
    /// checkpoint names is now bound to a DIFFERENT athlete than the
    /// checkpoint itself claims — never silently resolved to whichever
    /// athlete the participant currently happens to link to.
    private func locallyRevalidate(checkpoint: AthleteBackendConnectionCheckpoint) throws -> CurrentSessionActor {
        let bound = try identityBindingService.bind(
            acceptedWorkspaceId: checkpoint.workspaceId, intendedParticipantId: checkpoint.participantId
        )
        guard bound.athleteId.rawValue == checkpoint.athleteId else {
            throw CheckpointAthleteMismatchError()
        }
        return try sessionActivationService.activate(boundIdentity: bound)
    }

    /// Classifies anything `AthleteBackendHydrationAdapter.hydrate(deviceGrantId:)`
    /// can throw into one of this type's own honest, named states —
    /// `nonisolated static` and taking `log` explicitly so it carries
    /// no isolation requirement of its own (pure classification, no
    /// side effects beyond the one diagnostic log line for a genuinely
    /// unrecognized error).
    private static func classify(hydrationFailure error: Error, log: Logger) -> State {
        if let failure = error as? AthleteDeviceAuthorizationSessionManager.SessionFailure {
            switch failure {
            case .grantUnavailable: return .connectionUnavailable
            case .installationKeyUnavailable: return .installationKeyUnavailable
            case .network, .malformedResponse, .gatewayConfigurationMissing, .sessionCleared: return .temporarilyUnavailable
            }
        }
        if let failure = error as? AthleteDeviceAuthorizationSessionError {
            switch failure {
            case .signingKeyUnavailable: return .installationKeyUnavailable
            case .network, .malformedResponse, .gatewayConfigurationMissing: return .temporarilyUnavailable
            }
        }
        if let failure = error as? AthleteBackendHydrationError {
            switch failure {
            case .ackNotConfirmed: return .ackNotConfirmed
            case .sessionInvalidatedOrCancelled: return .temporarilyUnavailable
            case .malformedHydrationPayload: return .temporarilyUnavailable
            }
        }
        // Anything else (e.g. `AthleteIdentityHydrationError` from the
        // adapter's own local `hydrate(_:)` call) is a genuine local
        // persistence/graph problem — never reinterpreted as a security
        // denial.
        log.error("Athlete backend connection: unrecognized hydration failure: \(String(describing: error), privacy: .public)")
        return .recoveryRequired
    }

    /// `performFreshVerification`'s own three possible outcomes — never
    /// a fourth hidden case; see that method's own doc comment.
    private enum FreshVerificationOutcome {
        case verified
        case unverified
        case denied(State)
    }

    /// R3 (ChatGPT review on PR #120): thrown by `locallyRevalidate`
    /// when the participant a checkpoint names is bound to a DIFFERENT
    /// athlete than the checkpoint itself claims — e.g. a relink since
    /// the checkpoint was saved, or a corrupted/stale checkpoint. Never
    /// surfaced beyond this file: every caller already swallows
    /// `locallyRevalidate`'s throw via `try?` and reports
    /// `.recoveryRequired`, exactly as it would for any other local
    /// graph inconsistency.
    private struct CheckpointAthleteMismatchError: Error {}
}

/// Test-substitution seam for `AthleteBackendHydrationAdapter.hydrate(deviceGrantId:)`
/// — mirrors `AthleteSessionActivating`'s own established precedent in
/// `AthleteConnectionLifecycleService.swift` exactly: a single-method
/// protocol extracted for one concrete, already-canonical orchestration
/// class, with that class conforming via a zero-behavior-change
/// extension below, so a deterministic test can drive this
/// coordinator's own sequencing/classification logic without a full
/// network-transport fixture for the hydration step itself (that
/// adapter's OWN session/wire-mapping/ack-gating logic remains covered
/// by `AthleteBackendHydrationAdapterTests.swift`, never re-tested
/// here).
public protocol AthleteBackendHydrating {
    func hydrate(deviceGrantId: UUID) async throws -> AthleteBackendHydrationOutcome
}

extension AthleteBackendHydrationAdapter: AthleteBackendHydrating {}

/// Test-substitution seam for `AthleteDeviceAuthorizationSessionManager`
/// — same precedent and same reasoning as `AthleteBackendHydrating`
/// immediately above, covering exactly the two session-manager members
/// this coordinator itself calls directly: the restoration flow's own
/// forced online re-verification, and `signOutOrInvalidate()`'s session
/// teardown.
public protocol AthleteFreshSessionVerifying {
    func ensureFreshlyVerifiedSession(deviceGrantId: UUID, isStillWanted: @escaping () -> Bool) async throws -> String
    func clearStoredSession()
}

extension AthleteDeviceAuthorizationSessionManager: AthleteFreshSessionVerifying {}
