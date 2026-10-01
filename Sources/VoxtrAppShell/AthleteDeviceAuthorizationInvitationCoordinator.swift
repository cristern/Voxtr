import Foundation
import VoxtrCoreContracts
import VoxtrParentAuthentication

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
        case decided(ConnectionRequestDecisionOutcome)
        case failed(String)
    }

    public private(set) var state: State = .idle

    private let invitationService: AthleteDeviceAuthorizationInvitationService
    private let parentAuthenticationService: ParentAuthenticationService
    private let clock: AthleteDeviceAuthorizationPollingClock
    private var pollTask: Task<Void, Never>?

    /// Same cadence as the Athlete-side poll
    /// (`AthleteDeviceAuthorizationPairingCoordinator.pollIntervalSeconds`)
    /// — ample margin under the backend's own 60-second challenge nonce
    /// TTL, responsive enough that a newly-submitted request appears
    /// promptly on the Parent's screen.
    static let pollIntervalSeconds: Double = 3

    public init(
        invitationService: AthleteDeviceAuthorizationInvitationService,
        parentAuthenticationService: ParentAuthenticationService,
        clock: AthleteDeviceAuthorizationPollingClock = SystemAthleteDeviceAuthorizationPollingClock()
    ) {
        self.invitationService = invitationService
        self.parentAuthenticationService = parentAuthenticationService
        self.clock = clock
    }

    /// Creates a fresh invitation for the selected athlete and begins
    /// polling for submitted requests. `invitedBy` is the Parent's own
    /// `ActorId`, threaded straight to `prepareInvitation`'s own
    /// `createInvitedAthleteParticipant(invitedBy:)` call when a new
    /// participant must be created — same convention as
    /// `AthleteConnectionOwnerHandoffService.prepareInvitation`.
    public func start(forAthlete athleteId: AthleteId, workspaceId: WorkspaceId, invitedBy: ActorId) async {
        state = .preparing
        let invitation: AthleteDeviceAuthorizationInvitation
        do {
            invitation = try await invitationService.prepareInvitation(
                forAthlete: athleteId,
                workspaceId: workspaceId,
                invitedBy: invitedBy
            )
        } catch {
            state = .failed("Couldn't create a connection code. Please try again.")
            return
        }
        state = .awaitingRequests(invitation: invitation, requests: [])
        beginPolling(invitation: invitation)
    }

    /// Stops polling without changing `state` — the caller (the View,
    /// via `.onDisappear`/dismissal) is responsible for calling this
    /// when the screen goes away, so no orphaned poll loop keeps running
    /// after the Parent has dismissed the QR screen.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func beginPolling(invitation: AthleteDeviceAuthorizationInvitation) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshRequests(invitation: invitation)
                try? await self.clock.sleep(for: Self.pollIntervalSeconds)
            }
        }
    }

    private func refreshRequests(invitation: AthleteDeviceAuthorizationInvitation) async {
        // A decision may have just been made on a previous tick (or by
        // an explicit `decide(...)` call) — once `state` has moved past
        // `.awaitingRequests`, a late-arriving poll tick must not
        // overwrite it.
        guard case .awaitingRequests = state else { return }
        let outcome: ConnectionRequestListOutcome
        do {
            outcome = try await parentAuthenticationService.listConnectionRequests(invitationId: invitation.invitationId)
        } catch {
            // A transient network hiccup — the next poll tick retries;
            // never surfaced as a hard failure for a single missed poll.
            return
        }
        guard case .awaitingRequests = state else { return }
        switch outcome {
        case .ok(let requests):
            state = .awaitingRequests(invitation: invitation, requests: requests)
        case .invitationNotFound, .ownerBindingNotActive:
            stop()
            state = .failed("This connection code is no longer available.")
        }
    }

    /// Approves or rejects exactly the request identified by `requestId`,
    /// carrying back `displayCode` exactly as shown on screen for that
    /// request — the Parent's own visual comparison against the
    /// Athlete's device, never retyped or re-derived.
    public func decide(
        invitation: AthleteDeviceAuthorizationInvitation,
        requestId: UUID,
        decision: ConnectionRequestDecision,
        displayCode: String
    ) async {
        stop()
        do {
            let outcome = try await parentAuthenticationService.decideConnectionRequest(
                invitationId: invitation.invitationId,
                connectionRequestId: requestId,
                decision: decision,
                displayCode: displayCode
            )
            state = .decided(outcome)
        } catch {
            state = .failed("Couldn't record that decision. Please try again.")
        }
    }
}
