import Foundation

/// Injectable so deterministic tests never actually sleep — mirrors
/// `ParentSignInCoordinator`'s own `ParentSignInClock` seam exactly, for
/// the same reason. `Sendable` (matching `ParentSignInClock`'s own
/// declaration exactly): both `AthleteDeviceAuthorizationPairingCoordinator`
/// and `AthleteDeviceAuthorizationInvitationCoordinator` are `@MainActor`
/// and store their own `clock` as a stored property, then call
/// `clock.sleep(for:)` from inside an owned `Task` — without `Sendable`
/// here, Swift 6's strict concurrency checking treats that as sending a
/// main-actor-isolated, non-Sendable value across an isolation boundary
/// into `sleep(for:)`'s own nonisolated context, which is a real compile
/// error (confirmed by Codemagic), not a hypothetical one.
public protocol AthleteDeviceAuthorizationPollingClock: Sendable {
    func sleep(for seconds: Double) async throws
}

public struct SystemAthleteDeviceAuthorizationPollingClock: AthleteDeviceAuthorizationPollingClock {
    public init() {}
    public func sleep(for seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Athlete Connection V1 (backend device authorization): the Athlete
/// installation's own pairing state machine — scan → submit request →
/// show comparison code → poll for Parent approval → sign and submit the
/// claim proof → confirmed backend device authorization. This slice ends
/// exactly there: `.authorized(grantId:)` carries only the backend's own
/// opaque grant id, never athlete business data, and nothing here calls
/// `AthleteIdentityHydrationService`/`AthleteConnectionLifecycleService`
/// or activates any business membership (per this task's own explicit
/// boundary — see `ADR-AthleteConnection-BackendAuthorization.md`).
///
/// DELIBERATELY SEPARATE from `AthleteConnectionScanCoordinator` (the
/// existing, unmodified CKShare-based pairing coordinator) — this is an
/// ADDITIVE V1 slice alongside that still-live flow, not a replacement of
/// it; see `AthleteDeviceAuthorizationQRPayload`'s own doc comment for
/// why the two payload shapes can never collide.
///
/// OWNED CANCELLATION + GENERATIONS: every attempt runs as exactly one
/// `Task` this coordinator itself owns (`currentTask`). `cancel()`
/// cancels it AND bumps `generation`, so any work from an OLDER attempt
/// that is still unwinding when a NEWER one starts (a fresh scan, an
/// explicit `reset()`, or the screen being dismissed and re-presented)
/// can never publish its own stale result over the newer attempt's
/// state — every `state =` write is guarded by a check that the work's
/// own captured generation still matches `generation` AND the task has
/// not been cancelled, performed after EVERY `await` (network call,
/// sleep, signing) and again right before publishing.
///
/// REVIEW ROUND 3 — RECEIPTS ARE NEVER PROOF OF CURRENT AUTHORIZATION:
/// `AthleteDeviceAuthorizationReceiptStoring` persists only the minimal
/// installation-scoped metadata needed to resume after an interruption
/// (invitation/request id, the comparison code, and — once known — grant
/// id/recovery deadline). A receipt that already recorded a grant is
/// NEVER, by itself, enough to report `.authorized` again — only a fresh
/// backend reconfirmation (a new challenge + a signed claim, which the
/// backend answers with `already_granted` for a still-valid grant) is.
/// See `resumePendingAttemptIfAny()`'s own doc comment for the full
/// reasoning, and `AthleteDeviceAuthorizationReceipt`'s own doc comment
/// for why `recoveryDeadline` is never used as local authorization proof
/// either.
///
/// AMBIGUOUS CLAIM FAILURE RECOVERY: a network failure during
/// `claim-submit` is inherently ambiguous — the backend may have
/// processed the signed proof before the connection dropped. This
/// coordinator NEVER resubmits the connection request or requires a new
/// invitation for that case; it requests a FRESH challenge for the SAME
/// `connectionRequestId`/key and retries, exactly as the Normative
/// Security Contract's own retry model describes. A PERMANENT local
/// failure (no usable signing key, missing gateway configuration) is a
/// different thing entirely — retrying it automatically, up to the full
/// poll budget, can never succeed, so it stops the loop immediately
/// (`.interrupted`) rather than silently burning through 100 attempts;
/// the Athlete can still choose to retry explicitly once whatever is
/// wrong is fixed, via `continuePendingAttempt()`.
///
/// Calm by Default: no fake progress percentages or countdowns while
/// polling — `.awaitingApproval`/`.claiming` are the only "please wait"
/// states shown, each with a plain, honest message. `claim-challenge`
/// returning `request_not_available` repeatedly, or the poll budget
/// running out, NEVER proves the Parent didn't approve — the copy below
/// says so honestly rather than implying a negative result that isn't
/// actually known.
@MainActor
@Observable
public final class AthleteDeviceAuthorizationPairingCoordinator {

    public enum State: Equatable {
        case idle
        /// Resuming a receipt that has NOT yet recorded a grant —
        /// polling for approval exactly as a fresh submission would.
        case resuming
        /// Resuming a receipt that already recorded a PAST grant — this
        /// is shown while that is being reconfirmed with the backend via
        /// a fresh challenge + signed claim, NEVER while simply trusting
        /// the stored `grantId` on its own. Distinct from `.authorized`
        /// on purpose: nothing here is "current" until the backend says
        /// so again, this session.
        case reconfirmingPreviousGrant(grantId: UUID)
        case submitting
        case awaitingApproval(connectionRequestId: UUID, displayCode: String)
        case claiming
        case authorized(grantId: UUID)
        /// A resumable interruption — a transient network failure while
        /// polling/claiming, a permanent local failure (missing signing
        /// key, missing gateway configuration), or poll-budget
        /// exhaustion — while a receipt for the SAME request/key still
        /// exists. `displayCode` (from the receipt, if it has one) lets
        /// the screen keep showing the Parent's own comparison code
        /// while offering an explicit "Continue connection" (same
        /// request/key, fresh challenge — see `continuePendingAttempt()`)
        /// alongside "Scan again" (an explicit new attempt — see
        /// `reset()`'s own doc comment for what that discards).
        case interrupted(displayCode: String?)
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Set only when the backend has ALREADY confirmed a grant THIS
    /// session but the local receipt recording it could not be saved —
    /// `state` still truthfully reports `.authorized`, since that part
    /// is real; this communicates the narrower, separate fact that a
    /// future relaunch may not be able to show that without a new scan.
    /// `nil` whenever no such warning applies (including for every
    /// ordinary successful save) — cleared at the start of every new
    /// attempt.
    public private(set) var unpersistedAuthorizationWarning: String?

    private let service: AthleteDeviceAuthorizationService
    private let clock: AthleteDeviceAuthorizationPollingClock
    private let receiptStore: AthleteDeviceAuthorizationReceiptStoring
    private var currentTask: Task<Void, Never>?
    private var generation = 0

    /// Ample margin under the backend's own 60-second challenge nonce
    /// TTL, and short enough that the Athlete screen feels responsive
    /// once the Parent actually approves.
    static let pollIntervalSeconds: Double = 3
    /// ~5 minutes of polling at the interval above — long enough for a
    /// Parent to notice and approve, bounded so this screen never waits
    /// forever on a request nobody is going to act on. Shared by both
    /// the "still pending" and the "ambiguous claim failure, retry with
    /// a fresh challenge" cases — both count against the same budget.
    static let maxPollAttempts = 100

    public init(
        service: AthleteDeviceAuthorizationService,
        clock: AthleteDeviceAuthorizationPollingClock = SystemAthleteDeviceAuthorizationPollingClock(),
        receiptStore: AthleteDeviceAuthorizationReceiptStoring = KeychainAthleteDeviceAuthorizationReceiptStore()
    ) {
        self.service = service
        self.clock = clock
        self.receiptStore = receiptStore
    }

    /// Entry point from a scanned QR string. Cancels any in-flight
    /// attempt first (a fresh scan always starts a NEW attempt — old
    /// work can never overwrite it), then validates the payload, submits
    /// the connection request, and begins polling for Parent approval.
    /// Deliberately never touches a receipt for some OTHER pending
    /// attempt on an invalid-code failure — scanning garbage by mistake
    /// must never discard a perfectly recoverable prior attempt; only
    /// the explicit `reset()` ("Scan again") action does that.
    public func beginPairing(scannedText: String) {
        switch AthleteDeviceAuthorizationQRPayload.validate(scannedText) {
        case .failure:
            cancelCurrentAttempt()
            state = .failed("That code isn't a Vǫxtr device authorization code. Try scanning again.")
        case .success(let invitationId):
            startNewAttempt { [weak self] myGeneration in
                await self?.submitAndPoll(invitationId: invitationId, myGeneration: myGeneration)
            }
        }
    }

    /// Called once, when the scan screen first appears, BEFORE any scan
    /// — if a receipt from a previous interrupted session exists, this
    /// resumes polling/reconfirming for that SAME invitation/request
    /// instead of requiring the Parent to show a brand-new code. No-op
    /// from any state other than `.idle`.
    public func resumePendingAttemptIfAny() {
        guard case .idle = state else { return }
        resumeStoredReceipt()
    }

    /// The Athlete's own explicit "Continue connection" action from
    /// `.interrupted` — resumes the SAME receipt that interruption left
    /// behind (same invitation/request/key), requesting a fresh
    /// challenge rather than resubmitting the connection request or
    /// requiring a new invitation. No-op from any other state.
    public func continuePendingAttempt() {
        guard case .interrupted = state else { return }
        resumeStoredReceipt()
    }

    /// Loads whatever receipt is currently stored and resumes it —
    /// shared by `resumePendingAttemptIfAny()` (automatic, once, on
    /// screen appear) and `continuePendingAttempt()` (explicit, from
    /// `.interrupted`). Both paths verify the receipt belongs to a key
    /// THIS installation can still produce before attempting anything
    /// over the network: a reinstall (orphaned Keychain material under
    /// a mismatched installation marker) or missing/corrupt key must
    /// never silently authorize, and must never generate a replacement
    /// key to continue an attempt bound to a different, now-gone one —
    /// such a receipt is cleared outright rather than retried.
    ///
    /// A receipt that already recorded a grant is NEVER shortcut
    /// straight to `.authorized` — it is always reconfirmed with the
    /// backend first, via the SAME fresh-challenge-and-signed-claim path
    /// a receipt with no grant yet uses. Per the Normative Security
    /// Contract's own §2 D2 same-key recovery model, the backend answers
    /// that reconfirmation with `already_granted` (mapped to
    /// `.alreadyGranted` here) when the grant is still active and within
    /// its 24-hour recovery deadline — this is the backend's own
    /// EXISTING recovery mechanism, not a new endpoint. A locally stored
    /// `recoveryDeadline` already having passed is never itself treated
    /// as proof the grant was revoked; only the backend's own response
    /// decides that.
    private func resumeStoredReceipt() {
        guard let receipt = receiptStore.loadReceipt() else { return }
        guard service.currentInstallationHasExistingSigningKey() else {
            receiptStore.clearReceipt()
            state = .failed("This device's secure key no longer matches a connection in progress. Please scan a new code.")
            return
        }
        if let grantId = receipt.grantId {
            startNewAttempt { [weak self] myGeneration in
                self?.state = .reconfirmingPreviousGrant(grantId: grantId)
                await self?.pollForApprovalAndClaim(
                    invitationId: receipt.invitationId,
                    connectionRequestId: receipt.connectionRequestId,
                    displayCode: receipt.displayCode,
                    myGeneration: myGeneration
                )
            }
        } else {
            startNewAttempt { [weak self] myGeneration in
                self?.state = .resuming
                await self?.pollForApprovalAndClaim(
                    invitationId: receipt.invitationId,
                    connectionRequestId: receipt.connectionRequestId,
                    displayCode: receipt.displayCode,
                    myGeneration: myGeneration
                )
            }
        }
    }

    /// Cancels any in-flight attempt and returns to `.idle` — the
    /// Athlete's own explicit "Scan again" action, from EITHER a
    /// terminal `.failed` state or an `.interrupted` one. Unlike
    /// `continuePendingAttempt()`, this is a deliberate, explicit new
    /// attempt: it discards whatever receipt is currently stored first
    /// (a no-op if none exists), so a stale pending/interrupted request
    /// is never silently left behind to confuse a later
    /// `resumePendingAttemptIfAny()` call.
    public func reset() {
        cancelCurrentAttempt()
        receiptStore.clearReceipt()
        state = .idle
    }

    /// Cancels any in-flight attempt without changing `state` and
    /// WITHOUT touching any persisted receipt — called when the hosting
    /// screen disappears (Done button or interactive swipe dismissal
    /// alike), so no stale poll loop keeps running after the Athlete has
    /// left this screen. A merely-dismissed screen is not the Athlete
    /// discarding their pending attempt the way `reset()` is.
    public func cancel() {
        cancelCurrentAttempt()
    }

    private func cancelCurrentAttempt() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
        unpersistedAuthorizationWarning = nil
    }

    private func startNewAttempt(_ operation: @escaping (Int) async -> Void) {
        cancelCurrentAttempt()
        let myGeneration = generation
        currentTask = Task { [weak self] in
            await operation(myGeneration)
            if let self, self.generation == myGeneration {
                self.currentTask = nil
            }
        }
    }

    /// `true` only while THIS call's own attempt is still the current
    /// one and has not been cancelled — checked after every `await`
    /// before touching `state` or persisted receipts.
    private func isCurrent(_ myGeneration: Int) -> Bool {
        !Task.isCancelled && myGeneration == generation
    }

    private func submitAndPoll(invitationId: UUID, myGeneration: Int) async {
        state = .submitting
        let submission: ConnectionRequestSubmissionOutcome
        do {
            submission = try await service.submitConnectionRequest(invitationId: invitationId)
        } catch {
            guard isCurrent(myGeneration) else { return }
            state = .failed("Couldn't reach Vǫxtr. Check your connection and try again.")
            return
        }
        guard isCurrent(myGeneration) else { return }

        switch submission {
        case .submitted(let connectionRequestId, let displayCode):
            do {
                try receiptStore.saveReceipt(AthleteDeviceAuthorizationReceipt(
                    invitationId: invitationId,
                    connectionRequestId: connectionRequestId,
                    displayCode: displayCode
                ))
            } catch {
                // Explicit, never swallowed: without a persisted receipt
                // there is nothing to resume from if this app is
                // interrupted before a claim completes. Rather than
                // proceed into a poll that could eventually commit a
                // claim while implicitly promising a durability this
                // installation cannot actually provide right now, this
                // attempt stops here — the backend-side request remains
                // submitted and visible to the Parent regardless;
                // scanning again submits a fresh one.
                guard isCurrent(myGeneration) else { return }
                state = .failed("Couldn't save this connection attempt on this device. Please try again.")
                return
            }
            guard isCurrent(myGeneration) else { return }
            state = .awaitingApproval(connectionRequestId: connectionRequestId, displayCode: displayCode)
            await pollForApprovalAndClaim(invitationId: invitationId, connectionRequestId: connectionRequestId, displayCode: displayCode, myGeneration: myGeneration)
        case .invitationNotAvailable:
            state = .failed("This code is no longer available. Ask the parent to show a new one.")
        case .invalidDeviceKey, .inconsistentState:
            state = .failed("Something went wrong preparing this device. Please try again.")
        case .tooManyRequests:
            // This per-invitation cap does not reset by waiting — the
            // honest next step is a brand-new invitation, never "wait a
            // moment and try again."
            state = .failed("Too many attempts on this code. Ask the parent to show a new one.")
        }
    }

    /// Polls `claim-challenge` until it is issued (meaning the Parent
    /// has approved, OR — for a resumed/reconfirmed receipt — that the
    /// backend's own recovery window for an existing grant is still
    /// open) or the poll budget is exhausted — and, once issued, signs
    /// and submits the claim. A network failure while REQUESTING a
    /// challenge, or the poll budget running out, is a resumable
    /// interruption (`.interrupted`): the receipt this attempt is
    /// already bound to is untouched, so `continuePendingAttempt()` can
    /// pick it back up later. `claim-challenge` itself folds every
    /// reason a challenge should not be issued yet — still pending,
    /// rejected, already claimed outside its recovery window — into the
    /// same `.requestNotAvailable` outcome (anti-enumeration, by backend
    /// design); this loop never tries to tell those cases apart, only
    /// keeps waiting until the budget runs out.
    private func pollForApprovalAndClaim(invitationId: UUID, connectionRequestId: UUID, displayCode: String?, myGeneration: Int) async {
        for _ in 0..<Self.maxPollAttempts {
            guard isCurrent(myGeneration) else { return }

            let challengeOutcome: ClaimChallengeOutcome
            do {
                challengeOutcome = try await service.requestClaimChallenge(connectionRequestId: connectionRequestId)
            } catch {
                guard isCurrent(myGeneration) else { return }
                state = .interrupted(displayCode: displayCode)
                return
            }
            guard isCurrent(myGeneration) else { return }

            switch challengeOutcome {
            case .issued(let challengeId, let nonce, _):
                state = .claiming
                let settled = await attemptClaim(
                    invitationId: invitationId,
                    connectionRequestId: connectionRequestId,
                    challengeId: challengeId,
                    nonce: nonce,
                    displayCode: displayCode,
                    myGeneration: myGeneration
                )
                if settled { return }
                // Ambiguous network failure during claim-submit — fall
                // through to the next poll tick rather than failing;
                // the next tick requests a brand-new challenge.
            case .requestNotAvailable:
                break
            }
            guard isCurrent(myGeneration) else { return }
            try? await clock.sleep(for: Self.pollIntervalSeconds)
        }
        guard isCurrent(myGeneration) else { return }
        state = .interrupted(displayCode: displayCode)
    }

    /// Returns `true` once this attempt has reached a SETTLED outcome
    /// (authorized, a genuine terminal business failure, or a permanent
    /// local failure already published as `.interrupted`) — `false`
    /// means the caller should keep polling (an ambiguous network
    /// failure, handled by requesting a fresh challenge on the next
    /// tick).
    private func attemptClaim(
        invitationId: UUID,
        connectionRequestId: UUID,
        challengeId: UUID,
        nonce: Data,
        displayCode: String?,
        myGeneration: Int
    ) async -> Bool {
        let claimOutcome: ClaimOutcome
        do {
            claimOutcome = try await service.submitClaim(
                invitationId: invitationId,
                connectionRequestId: connectionRequestId,
                challengeId: challengeId,
                nonce: nonce
            )
        } catch let error as AthleteDeviceAuthorizationError {
            guard isCurrent(myGeneration) else { return true }
            switch error {
            case .network, .malformedResponse:
                // Ambiguous: the signature may have already reached and
                // been processed by the backend before the connection
                // dropped. Never resubmit the connection request or
                // require a new invitation — the caller retries with a
                // fresh challenge for this SAME request/key instead.
                return false
            case .signingKeyUnavailable, .gatewayConfigurationMissing:
                // PERMANENT and local — nothing about retrying the exact
                // same request automatically, up to the full poll
                // budget, can ever succeed. Stop immediately rather than
                // silently looping; the Athlete can retry explicitly
                // (`continuePendingAttempt()`) once whatever is actually
                // wrong is fixed.
                state = .interrupted(displayCode: displayCode)
                return true
            }
        } catch {
            guard isCurrent(myGeneration) else { return true }
            return false
        }
        guard isCurrent(myGeneration) else { return true }

        switch claimOutcome {
        case .granted(let grantId, let recoveryDeadline), .alreadyGranted(let grantId, let recoveryDeadline):
            do {
                try receiptStore.saveReceipt(AthleteDeviceAuthorizationReceipt(
                    invitationId: invitationId,
                    connectionRequestId: connectionRequestId,
                    grantId: grantId,
                    recoveryDeadline: recoveryDeadline
                ))
                unpersistedAuthorizationWarning = nil
            } catch {
                // The backend HAS confirmed this device's authorization
                // right now — `state` reports that truthfully below
                // regardless. What failed is only the LOCAL record a
                // future relaunch would use to show this without a new
                // scan; that distinct, narrower fact is communicated
                // here rather than silently discarded.
                unpersistedAuthorizationWarning = "This device is authorized, but we couldn't save a local record of it. If the app restarts before you finish elsewhere, you may need to scan a new code."
            }
            state = .authorized(grantId: grantId)
            return true
        case .requestNotApproved:
            // Lost a race: the challenge was issued while approved, but
            // approval state changed (e.g. revoked) before this claim
            // reached the backend. Genuinely terminal for this attempt.
            receiptStore.clearReceipt()
            state = .failed("This connection could not be completed. Ask the parent to show a new code.")
            return true
        case .invitationNotFound,
             .requestNotFound,
             .invitationExpired,
             .invitationClaimedByOtherRequest,
             .grantRevoked,
             .recoveryWindowExpired,
             .inconsistentState:
            receiptStore.clearReceipt()
            state = .failed("This connection could not be completed. Ask the parent to show a new code.")
            return true
        case .challengeInvalid:
            // The anti-enumeration fold also covers "signature didn't
            // verify" — which should never happen for a key this
            // coordinator itself just signed with, but is still a
            // genuine terminal rejection for THIS specific challenge,
            // never silently retried with the same (already-consumed)
            // challenge. The next poll tick requests a brand-new one.
            return false
        }
    }
}
