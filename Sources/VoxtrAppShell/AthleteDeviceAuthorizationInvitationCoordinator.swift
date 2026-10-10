import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrParentAuthentication

/// Every distinct reason a Parent-side sensitive mutation
/// (`start`/`decide`) could not even be attempted, surfaced separately
/// from an ordinary business failure — review round 2. Mirrors
/// `ParentAuthenticationError`'s own four auth-shaped cases exactly
/// (deliberately NOT `.network`/`.malformedResponse`, which remain
/// plain `.failed` messages: those are not "sign in again" situations).
public enum AthleteParentAuthenticationRequirement: Equatable {
    case notSignedIn
    case sessionInvalid
    case sessionExpired
    /// The stored session is still live, just not fresh enough for this
    /// SENSITIVE operation — only a brand-new SIWA handshake, never a
    /// refresh/rotation, can satisfy this (matches
    /// `ParentAuthenticationError.reauthenticationRequired`'s own
    /// contract exactly).
    case reauthenticationRequired
}

/// Athlete Connection V1 (backend device authorization): the ParentApp-
/// side pairing state machine — create invitation → display QR → poll
/// `connection-request-list` for submitted requests → Parent compares the
/// on-screen code against the Athlete's own device → explicit approve/
/// reject. This slice ends there: a `.decided` outcome never loads
/// athlete data or activates business membership (per this task's own
/// explicit boundary).
///
/// ADDITIVE, not a replacement, alongside the existing, unmodified
/// `AthleteConnectionOwnerHandoffService`/`AthleteConnectionQRPairingView`
/// CKShare flow — see `AthleteDeviceAuthorizationQRPayload`'s own doc
/// comment.
///
/// AUTHENTICATION RECOVERY (review round 2): `start`/`decide` are both
/// SENSITIVE Parent operations. A `ParentAuthenticationError` from
/// either surfaces as a distinct `.authenticationRequired` state —
/// never flattened into a generic "couldn't create/record" message —
/// and the EXACT operation that failed (which athlete/workspace, or
/// which invitation/request/decision/display code) is preserved in
/// `pendingOperation` so `retryAfterReauthentication()` can resume it
/// after the Parent signs in again via the existing SIWA flow. Nothing
/// here retries automatically: the caller must call
/// `retryAfterReauthentication()` explicitly, and a session refresh
/// alone can never satisfy `reauthenticationRequired` — only a fresh
/// SIWA handshake can.
///
/// OWNED CANCELLATION + GENERATIONS (review round 2): polling runs as
/// exactly one `Task` this coordinator itself owns (`currentTask`).
/// `stop()` cancels it and bumps `generation`, so a late-arriving poll
/// tick from an OLDER attempt can never overwrite a NEWER invitation's
/// state. Polling also ends on its own once `state` leaves
/// `.awaitingRequests` (a decision was made) or the invitation's own
/// `expiresAt` has passed — never silently continuing to poll a dead
/// invitation.
///
/// SINGLE-FLIGHT DECISIONS: `isDecisionPending` is `true` from the
/// moment `decide(...)` is called until it settles — the caller (the
/// View) disables every Approve/Reject action while it is `true`, and
/// `decide(...)` itself ignores an overlapping call rather than racing
/// two decisions for the same invitation.
///
/// Calm by Default: `awaitingRequests` carries the real, current list of
/// submitted requests (possibly empty) — never a fake progress
/// percentage or "x seconds remaining" countdown.
@MainActor
@Observable
public final class AthleteDeviceAuthorizationInvitationCoordinator {

    public enum State: Equatable {
        case idle
        case preparing
        case awaitingRequests(invitation: AthleteDeviceAuthorizationInvitation, requests: [ConnectionRequestSummary])
        /// Parent hydration-upload integration: reachable only for a
        /// NON-approved decision (`.rejected` and every invitation-state
        /// conflict outcome) — an `.approved` outcome never lands here
        /// at all, it routes straight into the upload sequence below
        /// instead (see `decide()`'s own body). Approval and successful
        /// upload are deliberately distinct states; an approved request
        /// with a failed/pending upload is never represented by this
        /// case.
        case decided(ConnectionRequestDecisionOutcome)
        /// The exact request just approved is being uploaded via the
        /// existing `hydration-upload` endpoint.
        case uploadingHydration(connectionRequestId: UUID)
        /// A genuine, distinct backend outcome was reached — never
        /// collapsed; see `HydrationUploadOutcome`'s own doc comment for
        /// what each one actually means (some, like `.staged`, are
        /// pending-claim successes, not failures).
        case hydrationUploaded(connectionRequestId: UUID, outcome: HydrationUploadOutcome)
        /// Local projection-resolution failure, or a plain network/
        /// malformed-response failure from the upload call itself —
        /// never a reason to show "sign in again" (that is
        /// `.authenticationRequired` instead). Actionable: `retryHydrationUpload()`
        /// resends the EXACT SAME frozen payload (resolved exactly once,
        /// at the moment this request was approved) — never recomputed
        /// from current/possibly-changed profile data.
        case hydrationUploadFailed(connectionRequestId: UUID, message: String)
        case authenticationRequired(AthleteParentAuthenticationRequirement)
        case failed(String)
    }

    /// Exactly what `retryAfterReauthentication()` resumes — preserves
    /// the selected athlete/workspace for a failed `start`, the exact
    /// invitation/request/decision/display code for a failed `decide`,
    /// the exact invitation already being polled for an auth failure
    /// hit mid-poll (`listConnectionRequests`), or the exact
    /// already-resolved, frozen hydration-upload payload for a failed
    /// `hydration-upload` call, across the reauthentication round trip.
    private enum PendingOperation {
        case start(athleteId: AthleteId, workspaceId: WorkspaceId, invitedBy: ActorId)
        case decide(invitation: AthleteDeviceAuthorizationInvitation, requestId: UUID, decision: ConnectionRequestDecision, displayCode: String)
        /// An authentication failure happened while polling an ALREADY-
        /// created invitation (never while creating one — that's
        /// `.start`) — resuming this must pick the SAME invitation back
        /// up, never create a new one.
        case resumePolling(invitation: AthleteDeviceAuthorizationInvitation)
        /// `projection`, when non-`nil`, is the EXACT, already-resolved
        /// 11-field payload from the moment this request was approved —
        /// retrying (via reauthentication or `retryHydrationUpload()`)
        /// resends this SAME value, never re-resolving it from current
        /// repository state, per the backend's own same-byte-
        /// idempotent/different-byte-rejected contract. `nil` means
        /// resolution ITSELF failed before any payload existed to
        /// freeze — retrying must re-attempt resolution from scratch
        /// (safe: resolution is pure/idempotent, nothing was frozen
        /// yet), never invent/fabricate a stand-in payload.
        case uploadHydration(connectionRequestId: UUID, invitation: AthleteDeviceAuthorizationInvitation, projection: AthleteConnectionInvitationCloudRecordPayload?)
    }

    public private(set) var state: State = .idle
    public private(set) var isDecisionPending = false

    private let invitationService: AthleteDeviceAuthorizationInvitationService
    private let parentAuthenticationService: ParentAuthenticationService
    private let hydrationUploadService: ParentHydrationUploadService
    private let clock: AthleteDeviceAuthorizationPollingClock
    private var currentTask: Task<Void, Never>?
    private var generation = 0
    private var pendingOperation: PendingOperation?

    /// Same cadence as the Athlete-side poll
    /// (`AthleteDeviceAuthorizationPairingCoordinator.pollIntervalSeconds`)
    /// — ample margin under the backend's own 60-second challenge nonce
    /// TTL, responsive enough that a newly-submitted request appears
    /// promptly on the Parent's screen.
    static let pollIntervalSeconds: Double = 3

    public init(
        invitationService: AthleteDeviceAuthorizationInvitationService,
        parentAuthenticationService: ParentAuthenticationService,
        hydrationUploadService: ParentHydrationUploadService,
        clock: AthleteDeviceAuthorizationPollingClock = SystemAthleteDeviceAuthorizationPollingClock()
    ) {
        self.invitationService = invitationService
        self.parentAuthenticationService = parentAuthenticationService
        self.hydrationUploadService = hydrationUploadService
        self.clock = clock
    }

    /// Creates a fresh invitation for the selected athlete and begins
    /// polling for submitted requests. `invitedBy` is the Parent's own
    /// `ActorId`, threaded straight to `prepareInvitation`'s own
    /// `createInvitedAthleteParticipant(invitedBy:)` call when a new
    /// participant must be created — same convention as
    /// `AthleteConnectionOwnerHandoffService.prepareInvitation`.
    public func start(forAthlete athleteId: AthleteId, workspaceId: WorkspaceId, invitedBy: ActorId) async {
        stopPolling()
        generation += 1
        let myGeneration = generation
        // Cleared synchronously, before any `await` below — a stale
        // pending operation from a PRIOR invitation/decision/upload on
        // this same coordinator instance must never be resumable once a
        // brand-new operation has begun (same rationale as `stop()`'s
        // own clear).
        pendingOperation = nil
        state = .preparing

        let invitation: AthleteDeviceAuthorizationInvitation
        do {
            invitation = try await invitationService.prepareInvitation(
                forAthlete: athleteId,
                workspaceId: workspaceId,
                invitedBy: invitedBy
            )
        } catch let error as AthleteDeviceAuthorizationInvitationError {
            guard isCurrent(myGeneration) else { return }
            handlePrepareFailure(error, athleteId: athleteId, workspaceId: workspaceId, invitedBy: invitedBy)
            return
        } catch {
            guard isCurrent(myGeneration) else { return }
            state = .failed("Couldn't create a connection code. Please try again.")
            return
        }
        guard isCurrent(myGeneration) else { return }
        pendingOperation = nil
        state = .awaitingRequests(invitation: invitation, requests: [])
        beginPolling(invitation: invitation, myGeneration: myGeneration)
    }

    /// Re-runs whichever operation (`start`/`decide`) most recently
    /// failed with an authentication requirement — the caller (the
    /// View) calls this ONLY after the Parent has explicitly completed
    /// a fresh SIWA handshake via the existing sign-in flow; nothing
    /// here retries on its own.
    public func retryAfterReauthentication() async {
        guard let operation = pendingOperation else { return }
        pendingOperation = nil
        switch operation {
        case .start(let athleteId, let workspaceId, let invitedBy):
            await start(forAthlete: athleteId, workspaceId: workspaceId, invitedBy: invitedBy)
        case .decide(let invitation, let requestId, let decision, let displayCode):
            await decide(invitation: invitation, requestId: requestId, decision: decision, displayCode: displayCode)
        case .resumePolling(let invitation):
            generation += 1
            let myGeneration = generation
            state = .awaitingRequests(invitation: invitation, requests: [])
            beginPolling(invitation: invitation, myGeneration: myGeneration)
        case .uploadHydration(let connectionRequestId, let invitation, let projection):
            await resumeUploadHydration(connectionRequestId: connectionRequestId, invitation: invitation, projection: projection)
        }
    }

    /// Manual retry for a PLAIN (non-authentication) hydration-upload
    /// failure — a network hiccup or malformed response from the
    /// `hydration-upload` call itself, or a local projection-resolution
    /// failure. Independent of `retryAfterReauthentication()`'s own
    /// reauthentication-specific trigger, but shares its exact same
    /// single-flight shape: clearing `pendingOperation` before the
    /// retry's own `await` means a second, overlapping tap finds
    /// nothing to resume and simply returns. Callable any time
    /// `pendingOperation` holds `.uploadHydration`, regardless of
    /// whether `.authenticationRequired` or `.hydrationUploadFailed` is
    /// the CURRENT state.
    public func retryHydrationUpload() async {
        guard case .uploadHydration(let connectionRequestId, let invitation, let projection) = pendingOperation else { return }
        pendingOperation = nil
        await resumeUploadHydration(connectionRequestId: connectionRequestId, invitation: invitation, projection: projection)
    }

    /// Shared by both retry entry points: with an already-resolved
    /// `projection`, resumes directly at the upload step; with `nil`
    /// (resolution itself failed last time), re-attempts resolution
    /// from scratch via `attemptHydrationUpload` — never fabricates a
    /// stand-in payload to satisfy `retryUpload`'s own signature.
    private func resumeUploadHydration(
        connectionRequestId: UUID,
        invitation: AthleteDeviceAuthorizationInvitation,
        projection: AthleteConnectionInvitationCloudRecordPayload?
    ) async {
        if let projection {
            await retryUpload(connectionRequestId: connectionRequestId, invitation: invitation, projection: projection)
        } else {
            generation += 1
            let myGeneration = generation
            await attemptHydrationUpload(connectionRequestId: connectionRequestId, invitation: invitation, myGeneration: myGeneration)
        }
    }

    /// Stops polling without changing `state` — the caller (the View,
    /// via `.onDisappear`/dismissal) is responsible for calling this
    /// when the screen goes away, so no orphaned poll loop keeps running
    /// after the Parent has dismissed the QR screen.
    ///
    /// Also clears `pendingOperation` (review round: a dismissed/stopped
    /// flow must never be resumable). Without this, a reauthentication
    /// callback already queued before `stop()` ran (`onReauthenticated`
    /// → `Task { await coordinator.retryAfterReauthentication() }`) could
    /// still fire AFTER the Parent dismissed this entire screen, mint a
    /// fresh generation (nothing else bumps it once `stop()` has run),
    /// and resurrect — as a real, uncancelled network upload — an
    /// approval the Parent already walked away from. Since a fresh
    /// coordinator is created on every new presentation (see this type's
    /// own call site), there is no legitimate case where a pending
    /// operation needs to survive a `stop()` on the SAME instance.
    public func stop() {
        stopPolling()
        generation += 1
        pendingOperation = nil
    }

    private func stopPolling() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func isCurrent(_ myGeneration: Int) -> Bool {
        !Task.isCancelled && myGeneration == generation
    }

    private func beginPolling(invitation: AthleteDeviceAuthorizationInvitation, myGeneration: Int) {
        currentTask = Task { [weak self] in
            guard let self else { return }
            while self.isCurrent(myGeneration) {
                // The invitation's own `expiresAt` ends polling locally
                // without even calling the network — never silently
                // polling a dead invitation forever.
                if invitation.expiresAt < Date() {
                    self.state = .failed("This connection code has expired. Create a new one.")
                    return
                }
                await self.refreshRequests(invitation: invitation, myGeneration: myGeneration)
                guard self.isCurrent(myGeneration) else { return }
                try? await self.clock.sleep(for: Self.pollIntervalSeconds)
            }
        }
    }

    private func refreshRequests(invitation: AthleteDeviceAuthorizationInvitation, myGeneration: Int) async {
        // A decision may have just been made — once `state` has moved
        // past `.awaitingRequests`, a late-arriving poll tick must not
        // overwrite it.
        guard case .awaitingRequests = state else { return }
        let outcome: ConnectionRequestListOutcome
        do {
            outcome = try await parentAuthenticationService.listConnectionRequests(invitationId: invitation.invitationId)
        } catch let error as ParentAuthenticationError {
            guard isCurrent(myGeneration) else { return }
            guard let requirement = Self.mapAuthRequirement(error) else {
                // A plain `.network`/`.malformedResponse` — a transient
                // hiccup, not an auth problem; the next poll tick
                // retries, never surfaced as a hard failure for one
                // missed poll.
                return
            }
            stopPolling()
            // Preserves the SAME invitation already being polled —
            // `retryAfterReauthentication()` resumes polling it
            // directly, never creating a new invitation just because
            // the Parent's session went stale mid-poll.
            pendingOperation = .resumePolling(invitation: invitation)
            state = .authenticationRequired(requirement)
            return
        } catch {
            // A transient network hiccup — the next poll tick retries;
            // never surfaced as a hard failure for a single missed poll.
            return
        }
        guard isCurrent(myGeneration), case .awaitingRequests = state else { return }
        switch outcome {
        case .ok(let requests):
            state = .awaitingRequests(invitation: invitation, requests: requests)
        case .invitationNotFound, .ownerBindingNotActive:
            stopPolling()
            state = .failed("This connection code is no longer available.")
        }
    }

    /// Approves or rejects exactly the request identified by `requestId`,
    /// carrying back `displayCode` exactly as shown on screen for that
    /// request — the Parent's own visual comparison against the
    /// Athlete's device, never retyped or re-derived. Single-flight:
    /// ignored while a previous `decide(...)` call is still pending.
    public func decide(
        invitation: AthleteDeviceAuthorizationInvitation,
        requestId: UUID,
        decision: ConnectionRequestDecision,
        displayCode: String
    ) async {
        guard !isDecisionPending else { return }
        isDecisionPending = true
        defer { isDecisionPending = false }

        stopPolling()
        generation += 1
        let myGeneration = generation
        do {
            let outcome = try await parentAuthenticationService.decideConnectionRequest(
                invitationId: invitation.invitationId,
                connectionRequestId: requestId,
                decision: decision,
                displayCode: displayCode
            )
            guard isCurrent(myGeneration) else { return }
            pendingOperation = nil
            switch outcome {
            case .approved:
                // Invoke upload only after this actual approval
                // success, for this exact request — never on reject or
                // any other outcome. Awaited inline, inside this same
                // `decide()` call, so `isDecisionPending`'s own
                // `defer` above continues to guard the whole
                // decide-then-upload sequence, not just the decision
                // itself.
                await attemptHydrationUpload(connectionRequestId: requestId, invitation: invitation, myGeneration: myGeneration)
            default:
                state = .decided(outcome)
            }
        } catch let error as ParentAuthenticationError {
            guard isCurrent(myGeneration) else { return }
            if let requirement = Self.mapAuthRequirement(error) {
                pendingOperation = .decide(invitation: invitation, requestId: requestId, decision: decision, displayCode: displayCode)
                state = .authenticationRequired(requirement)
            } else {
                state = .failed("Couldn't record that decision. Please try again.")
            }
        } catch {
            guard isCurrent(myGeneration) else { return }
            state = .failed("Couldn't record that decision. Please try again.")
        }
    }

    /// FIRST attempt only, immediately after an actual approval success
    /// — resolves the 11-field projection ONCE (never again for this
    /// exact request; every subsequent retry reuses the value this
    /// resolves) and then uploads it. `myGeneration` is the SAME
    /// generation `decide()` already minted for its own call, so a
    /// `stop()`/newer `start()`/`decide()` during resolution OR upload
    /// discards this attempt's result exactly like every other guarded
    /// step on this type.
    private func attemptHydrationUpload(
        connectionRequestId: UUID,
        invitation: AthleteDeviceAuthorizationInvitation,
        myGeneration: Int
    ) async {
        guard isCurrent(myGeneration) else { return }
        state = .uploadingHydration(connectionRequestId: connectionRequestId)

        let projection: AthleteConnectionInvitationCloudRecordPayload
        do {
            projection = try hydrationUploadService.resolveProjection(
                workspaceId: invitation.workspaceId,
                intendedParticipantId: invitation.participantId,
                intendedAthleteId: invitation.athleteId
            )
        } catch {
            // A local identity-resolution problem, never a reason to
            // show "sign in again" — actionable via
            // `retryHydrationUpload()`, which re-attempts resolution
            // fresh (nothing was frozen yet, so re-resolving here is
            // safe and correct, unlike retrying the upload itself).
            // `projection: nil` — nothing to freeze yet; never a
            // fabricated stand-in payload.
            guard isCurrent(myGeneration) else { return }
            pendingOperation = .uploadHydration(connectionRequestId: connectionRequestId, invitation: invitation, projection: nil)
            state = .hydrationUploadFailed(connectionRequestId: connectionRequestId, message: "Couldn't prepare connection details. Please try again.")
            return
        }
        guard isCurrent(myGeneration) else { return }
        await runUpload(connectionRequestId: connectionRequestId, invitation: invitation, projection: projection, myGeneration: myGeneration)
    }

    /// Retry entry point for an ALREADY-resolved, frozen projection —
    /// both `retryAfterReauthentication()` and `retryHydrationUpload()`
    /// funnel here. ALWAYS mints a fresh generation, matching
    /// `resumePolling`'s own established precedent for every other
    /// retry path on this type.
    private func retryUpload(
        connectionRequestId: UUID,
        invitation: AthleteDeviceAuthorizationInvitation,
        projection: AthleteConnectionInvitationCloudRecordPayload
    ) async {
        generation += 1
        let myGeneration = generation
        state = .uploadingHydration(connectionRequestId: connectionRequestId)
        await runUpload(connectionRequestId: connectionRequestId, invitation: invitation, projection: projection, myGeneration: myGeneration)
    }

    /// The actual network call, shared by the first attempt and every
    /// retry. `projection` is never recomputed here — it is always
    /// exactly what the caller already resolved/froze.
    private func runUpload(
        connectionRequestId: UUID,
        invitation: AthleteDeviceAuthorizationInvitation,
        projection: AthleteConnectionInvitationCloudRecordPayload,
        myGeneration: Int
    ) async {
        do {
            let outcome = try await hydrationUploadService.upload(connectionRequestId: connectionRequestId, payload: projection)
            guard isCurrent(myGeneration) else { return }
            pendingOperation = nil
            state = .hydrationUploaded(connectionRequestId: connectionRequestId, outcome: outcome)
        } catch let error as ParentAuthenticationError {
            guard isCurrent(myGeneration) else { return }
            pendingOperation = .uploadHydration(connectionRequestId: connectionRequestId, invitation: invitation, projection: projection)
            if let requirement = Self.mapAuthRequirement(error) {
                state = .authenticationRequired(requirement)
            } else {
                state = .hydrationUploadFailed(connectionRequestId: connectionRequestId, message: "Couldn't upload connection details. Please try again.")
            }
        } catch {
            guard isCurrent(myGeneration) else { return }
            pendingOperation = .uploadHydration(connectionRequestId: connectionRequestId, invitation: invitation, projection: projection)
            state = .hydrationUploadFailed(connectionRequestId: connectionRequestId, message: "Couldn't upload connection details. Please try again.")
        }
    }

    private func handlePrepareFailure(
        _ error: AthleteDeviceAuthorizationInvitationError,
        athleteId: AthleteId,
        workspaceId: WorkspaceId,
        invitedBy: ActorId
    ) {
        switch error {
        case .authenticationFailed(let authError):
            if let requirement = Self.mapAuthRequirement(authError) {
                pendingOperation = .start(athleteId: athleteId, workspaceId: workspaceId, invitedBy: invitedBy)
                state = .authenticationRequired(requirement)
            } else {
                state = .failed("Couldn't create a connection code. Please try again.")
            }
        case .participantLookupFailed, .duplicateAthleteParticipant, .participantCreationFailed, .ownerBindingNotActive:
            state = .failed("Couldn't create a connection code. Please try again.")
        }
    }

    /// `nil` for `.network`/`.malformedResponse` — those are ordinary
    /// failures, never a reason to show a "sign in again" prompt.
    private static func mapAuthRequirement(_ error: ParentAuthenticationError) -> AthleteParentAuthenticationRequirement? {
        switch error {
        case .notSignedIn: return .notSignedIn
        case .sessionInvalid: return .sessionInvalid
        case .sessionExpired: return .sessionExpired
        case .reauthenticationRequired: return .reauthenticationRequired
        case .network, .malformedResponse: return nil
        }
    }
}
