import Foundation

/// Injectable so deterministic tests never actually sleep — mirrors
/// `ParentSignInCoordinator`'s own `ParentSignInClock` seam exactly, for
/// the same reason.
public protocol AthleteDeviceAuthorizationPollingClock {
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
/// OWNED CANCELLATION + GENERATIONS (review round 2): every attempt runs
/// as exactly one `Task` this coordinator itself owns (`currentTask`).
/// `cancel()` cancels it AND bumps `generation`, so any work from an
/// OLDER attempt that is still unwinding when a NEWER one starts (a
/// fresh scan, an explicit `reset()`, or the screen being dismissed and
/// re-presented) can never publish its own stale result over the newer
/// attempt's state — every `state =` write is guarded by a check that
/// the work's own captured generation still matches `generation` AND
/// the task has not been cancelled, performed after EVERY `await`
/// (network call, sleep, signing) and again right before publishing.
///
/// RESUMABLE RECEIPT (review round 2): `AthleteDeviceAuthorizationReceiptStoring`
/// persists only the minimal installation-scoped metadata needed to
/// resume after an interruption (invitation/request id, and — once
/// known — grant id/recovery deadline). See that type's own doc comment
/// for why it is metadata only, never proof of current access, and why
/// a consumed challenge/nonce/signature is never part of it.
///
/// AMBIGUOUS CLAIM FAILURE RECOVERY: a network failure during
/// `claim-submit` is inherently ambiguous — the backend may have
/// processed the signed proof before the connection dropped. This
/// coordinator NEVER resubmits the connection request or requires a new
/// invitation for that case; it requests a FRESH challenge for the SAME
/// `connectionRequestId`/key and retries, exactly as the Normative
/// Security Contract's own retry model describes.
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
        case resuming
        case submitting
        case awaitingApproval(connectionRequestId: UUID, displayCode: String)
        case claiming
        case authorized(grantId: UUID)
        case failed(String)
    }

    public private(set) var state: State = .idle

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
    /// resumes polling/claiming for that SAME invitation/request instead
    /// of requiring the Parent to show a brand-new code. The receipt is
    /// metadata only (see its own doc comment); this never treats its
    /// mere presence as proof the device is already authorized.
    public func resumePendingAttemptIfAny() {
        guard case .idle = state, let receipt = receiptStore.loadReceipt() else { return }
        if let grantId = receipt.grantId {
            // The receipt already recorded a successful claim from a
            // prior session — report it directly rather than re-polling
            // for something that already happened.
            state = .authorized(grantId: grantId)
            return
        }
        startNewAttempt { [weak self] myGeneration in
            self?.state = .resuming
            await self?.pollForApprovalAndClaim(
                invitationId: receipt.invitationId,
                connectionRequestId: receipt.connectionRequestId,
                myGeneration: myGeneration
            )
        }
    }

    /// Cancels any in-flight attempt and returns to `.idle` — used for
    /// an explicit "scan again" after a failure. Does NOT clear a
    /// persisted receipt (a failure here doesn't mean the underlying
    /// backend attempt is dead; see the specific outcome handling below
    /// for when a receipt is actually cleared).
    public func reset() {
        cancelCurrentAttempt()
        state = .idle
    }

    /// Cancels any in-flight attempt without changing `state` — called
    /// when the hosting screen disappears (Done button or interactive
    /// swipe dismissal alike), so no stale poll loop keeps running after
    /// the Athlete has left this screen.
    public func cancel() {
        cancelCurrentAttempt()
    }

    private func cancelCurrentAttempt() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
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
            try? receiptStore.saveReceipt(AthleteDeviceAuthorizationReceipt(
                invitationId: invitationId,
                connectionRequestId: connectionRequestId
            ))
            state = .awaitingApproval(connectionRequestId: connectionRequestId, displayCode: displayCode)
            await pollForApprovalAndClaim(invitationId: invitationId, connectionRequestId: connectionRequestId, myGeneration: myGeneration)
        case .invitationNotAvailable:
            state = .failed("This code is no longer available. Ask the parent to show a new one.")
        case .invalidDeviceKey, .inconsistentState:
            state = .failed("Something went wrong preparing this device. Please try again.")
        case .tooManyRequests:
            // Review round 2: this per-invitation cap does not reset by
            // waiting — the honest next step is a brand-new invitation,
            // never "wait a moment and try again."
            state = .failed("Too many attempts on this code. Ask the parent to show a new one.")
        }
    }

    /// Polls `claim-challenge` until it is issued (meaning the Parent
    /// has approved) or the poll budget is exhausted — and, once issued,
    /// signs and submits the claim. A network failure specifically
    /// during `claim-submit` is treated as AMBIGUOUS (see this type's
    /// own doc comment): rather than failing, this loop simply continues
    /// and requests a fresh challenge for the same request/key on the
    /// next tick. `claim-challenge` itself folds every reason a
    /// challenge should not be issued yet — still pending, rejected,
    /// already claimed — into the same `.requestNotAvailable` outcome
    /// (anti-enumeration, by backend design); this loop never tries to
    /// tell those cases apart, only keeps waiting until the budget runs
    /// out, and the eventual timeout message says so honestly rather
    /// than implying the Parent never approved.
    private func pollForApprovalAndClaim(invitationId: UUID, connectionRequestId: UUID, myGeneration: Int) async {
        for _ in 0..<Self.maxPollAttempts {
            guard isCurrent(myGeneration) else { return }

            let challengeOutcome: ClaimChallengeOutcome
            do {
                challengeOutcome = try await service.requestClaimChallenge(connectionRequestId: connectionRequestId)
            } catch {
                guard isCurrent(myGeneration) else { return }
                state = .failed("Couldn't reach Vǫxtr. Check your connection and try again.")
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
        state = .failed("This is taking longer than expected. If the parent already approved, try again in a moment — poll exhaustion doesn't mean it wasn't approved.")
    }

    /// Returns `true` once this attempt has reached a SETTLED outcome
    /// (authorized or a genuine terminal business failure) — `false`
    /// means the caller should keep polling (an ambiguous network
    /// failure, handled by requesting a fresh challenge on the next
    /// tick).
    private func attemptClaim(
        invitationId: UUID,
        connectionRequestId: UUID,
        challengeId: UUID,
        nonce: Data,
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
        } catch {
            // Ambiguous: the signature may have already reached and been
            // processed by the backend before the connection dropped.
            // Never resubmit the connection request or require a new
            // invitation — the caller retries with a fresh challenge for
            // this SAME request/key instead.
            return false
        }
        guard isCurrent(myGeneration) else { return true }

        switch claimOutcome {
        case .granted(let grantId, let recoveryDeadline), .alreadyGranted(let grantId, let recoveryDeadline):
            try? receiptStore.saveReceipt(AthleteDeviceAuthorizationReceipt(
                invitationId: invitationId,
                connectionRequestId: connectionRequestId,
                grantId: grantId,
                recoveryDeadline: recoveryDeadline
            ))
            state = .authorized(grantId: grantId)
            return true
        case .requestNotApproved:
            // Lost a race: the challenge was issued while approved, but
            // approval state changed (e.g. revoked) before this claim
            // reached the backend. Genuinely terminal for this attempt.
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
