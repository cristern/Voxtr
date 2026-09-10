import Foundation
import VoxtrAthleteDomain

/// Athlete App Shell / UX Foundation: the ONE place that decides whether
/// AthleteApp shows the connection gate or the athlete-facing shell,
/// given the existing, unmodified `AthleteRuntimeSession` state machine
/// (`AthleteRuntimeSession`/`AthleteConnectionRuntimeState` themselves
/// are untouched by this round). Pure/no I/O — directly unit-testable
/// without SwiftUI, mirroring this codebase's own established pattern of
/// separating a pure routing/decision function from the view that
/// renders it (see e.g. `FamilyWorkspaceParticipantShareCoordinator
/// .action(forParticipantStatus:)`).
///
/// Deliberately does not introduce a second connection-state concept:
/// every case of `AthleteConnectionRuntimeState` maps to exactly one
/// `AthleteShellRoute` case, and `.shell` is the only route that carries
/// the resolved actor onward — nothing here stores or caches that actor
/// itself; the caller (`AthleteRootView`) reads `AthleteRuntimeSession
/// .shared.state` fresh on every body evaluation, exactly as before this
/// round.
enum AthleteShellRoute: Equatable {
    /// Not yet connected, actively connecting, a recoverable failure, or
    /// the lifecycle service isn't wired up yet — all four route to the
    /// SAME calm gate screen (`AthleteConnectionGateView`), which itself
    /// renders the distinguishing detail (the actual
    /// `AthleteConnectionRuntimeState` case it's given) — never a
    /// populated athlete experience.
    case gate
    /// The full B2.2 → B2.3 → B2.4 chain succeeded — `actor` is the
    /// already-resolved `CurrentSessionActor`, passed straight through.
    case shell(actor: CurrentSessionActor)

    static func route(for state: AthleteConnectionRuntimeState) -> AthleteShellRoute {
        switch state {
        case .connected(let actor):
            return .shell(actor: actor)
        case .notConnected, .connecting, .failed, .lifecycleServiceNotReady:
            return .gate
        }
    }
}

/// Athlete App Shell / UX Foundation: the ONE canonical way AthleteApp
/// resolves a display name for the connected athlete — shared by the
/// shell's own greeting (`AthleteNowView`) and its Profile/diagnostics
/// surface (`AthleteProfileView`), so neither screen invents a second
/// lookup. Supersedes the private `connectedTitle(for:)` logic that
/// previously lived only inside `AthleteConnectionStatusView` (removed
/// this round — see `AthleteRootView.swift`'s own doc comment).
///
/// Read-only, resolved fresh from the canonical `AthleteRepository` on
/// every call — never stored as a separate identity/name truth. If the
/// lookup fails or the actor has no linked athlete (should not happen
/// for an `.athlete`-role actor, but this is read-only display code, not
/// an invariant-enforcing boundary), `nil` is returned rather than
/// fabricating a name — the caller decides its own calm fallback copy.
enum AthleteDisplayIdentity {
    @MainActor
    static func resolvedName(for actor: CurrentSessionActor, athleteRepository: AthleteRepository) -> String? {
        guard let linkedAthleteId = actor.linkedAthleteId,
              let athlete = try? athleteRepository.fetchAthlete(byId: linkedAthleteId) else {
            return nil
        }
        return athlete.preferredName ?? athlete.givenName
    }
}
