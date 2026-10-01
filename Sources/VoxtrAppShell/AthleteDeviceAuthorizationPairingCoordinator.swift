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
/// Calm by Default: no fake progress percentages or countdowns while
/// polling — `.awaitingApproval`/`.claiming` are the only "please wait"
/// states shown, each with a plain, honest message.
///
/// RE-ENTRANCE GUARD: `isHandlingScan` mirrors
/// `AthleteConnectionScanCoordinator`'s own established convention
/// exactly — per-screen-session state, never shared/global.
@MainActor
@Observable
public final class AthleteDeviceAuthorizationPairingCoordinator {

    public enum State: Equatable {
        case idle
        case submitting
        case awaitingApproval(connectionRequestId: UUID, displayCode: String)
        case claiming
        case authorized(grantId: UUID)
        case failed(String)
    }

    public private(set) var state: State = .idle

    private let service: AthleteDeviceAuthorizationService
    private let clock: AthleteDeviceAuthorizationPollingClock
    private var isHandlingScan = false

    /// Ample margin under the backend's own 60-second challenge nonce
    /// TTL, and short enough that the Athlete screen feels responsive
    /// once the Parent actually approves.
    static let pollIntervalSeconds: Double = 3
    /// ~5 minutes of polling at the interval above — long enough for a
    /// Parent to notice and approve, bounded so this screen never waits
    /// forever on a request nobody is going to act on.
    static let maxPollAttempts = 100

    public init(
        service: AthleteDeviceAuthorizationService,
        clock: AthleteDeviceAuthorizationPollingClock = SystemAthleteDeviceAuthorizationPollingClock()
    ) {
        self.service = service
        self.clock = clock
    }

    /// Entry point from a scanned QR string. Validates the payload,
    /// submits the connection request, and (on success) begins polling
    /// for Parent approval — all the way through to a settled terminal
    /// state (`.authorized`/`.failed`) or cancellation.
    public func beginPairing(scannedText: String) async {
        guard !isHandlingScan else { return }
        isHandlingScan = true
        defer { isHandlingScan = false }

        switch AthleteDeviceAuthorizationQRPayload.validate(scannedText) {
        case .failure:
            state = .failed("That code isn't a Vǫxtr device authorization code. Try scanning again.")
        case .success(let invitationId):
            await submitAndPoll(invitationId: invitationId)
        }
    }

    public func reset() {
        state = .idle
    }

    private func submitAndPoll(invitationId: UUID) async {
        state = .submitting
        let submission: ConnectionRequestSubmissionOutcome
        do {
            submission = try await service.submitConnectionRequest(invitationId: invitationId)
        } catch {
            state = .failed("Couldn't reach Vǫxtr. Check your connection and try again.")
            return
        }

        switch submission {
        case .submitted(let connectionRequestId, let displayCode):
            state = .awaitingApproval(connectionRequestId: connectionRequestId, displayCode: displayCode)
            await pollForApprovalAndClaim(invitationId: invitationId, connectionRequestId: connectionRequestId)
        case .invitationNotAvailable:
            state = .failed("This code is no longer available. Ask the parent to show a new one.")
        case .invalidDeviceKey, .inconsistentState:
            state = .failed("Something went wrong preparing this device. Please try again.")
        case .tooManyRequests:
            state = .failed("Too many attempts. Please wait a moment and try again.")
        }
    }

    /// Polls `claim-challenge` until it is issued (meaning the Parent has
    /// approved) or the poll budget is exhausted. `claim-challenge` folds
    /// every reason a challenge should not be issued yet — still
    /// pending, rejected, already claimed — into the same
    /// `.requestNotAvailable` outcome (anti-enumeration, by backend
    /// design); this loop deliberately never tries to tell those cases
    /// apart, only keeps waiting until the budget runs out.
    private func pollForApprovalAndClaim(invitationId: UUID, connectionRequestId: UUID) async {
        for _ in 0..<Self.maxPollAttempts {
            if Task.isCancelled { return }
            let challengeOutcome: ClaimChallengeOutcome
            do {
                challengeOutcome = try await service.requestClaimChallenge(connectionRequestId: connectionRequestId)
            } catch {
                state = .failed("Couldn't reach Vǫxtr. Check your connection and try again.")
                return
            }
            switch challengeOutcome {
            case .issued(let challengeId, let nonce, _):
                state = .claiming
                await submitClaim(
                    invitationId: invitationId,
                    connectionRequestId: connectionRequestId,
                    challengeId: challengeId,
                    nonce: nonce
                )
                return
            case .requestNotAvailable:
                break
            }
            try? await clock.sleep(for: Self.pollIntervalSeconds)
        }
        state = .failed("This wasn't approved in time. Ask the parent to try again.")
    }

    private func submitClaim(invitationId: UUID, connectionRequestId: UUID, challengeId: UUID, nonce: Data) async {
        let claimOutcome: ClaimOutcome
        do {
            claimOutcome = try await service.submitClaim(
                invitationId: invitationId,
                connectionRequestId: connectionRequestId,
                challengeId: challengeId,
                nonce: nonce
            )
        } catch {
            state = .failed("Couldn't reach Vǫxtr. Check your connection and try again.")
            return
        }

        switch claimOutcome {
        case .granted(let grantId, _), .alreadyGranted(let grantId, _):
            state = .authorized(grantId: grantId)
        case .requestNotApproved,
             .invitationNotFound,
             .requestNotFound,
             .invitationExpired,
             .invitationClaimedByOtherRequest,
             .grantRevoked,
             .recoveryWindowExpired,
             .inconsistentState,
             .challengeInvalid:
            state = .failed("This connection could not be completed. Ask the parent to show a new code.")
        }
    }
}
