import Foundation

/// Athlete Connection V1 (backend device authorization, review round 4's
/// own UI finish): pure, SwiftUI-free presentation logic for the Parent
/// reauthentication sheet on `AthleteDeviceAuthorizationInvitationView`.
///
/// Extracted out of the view specifically so the actual PRESENTATION
/// STATE — whether the sheet should be shown right now, and how
/// dismissal/reopening affects that — is deterministically unit-testable
/// without a UI test harness, rather than only testing the coordinator's
/// own network-facing state. Mirrors this codebase's own established
/// pattern of extracting SwiftUI-adjacent state machines into plain,
/// testable types (see `ParentSignInCoordinator`'s own doc comment for
/// the same rationale applied to the sign-in attempt lifecycle).
///
/// Holds NO reference to the coordinator or any network/decision logic —
/// dismissing or reopening this sheet can never, by construction, send a
/// decision or a retry on its own. Only the view's own `onReauthenticated`
/// callback (fired by `ParentEnrollmentView` after a brand-new completed
/// SIWA handshake plus the Parent's own explicit Continue tap) calls
/// `retryAfterReauthentication()`.
struct AthleteDeviceAuthorizationReauthenticationSheetPresentation: Equatable {
    private var isDismissed = false

    /// Whether the sheet should be presented right now, given whether the
    /// coordinator is currently reporting `.authenticationRequired`.
    /// `false` whenever the Parent has explicitly dismissed it for this
    /// SAME authentication failure, until either `reopen()` or the
    /// authentication requirement itself clears.
    func isPresented(authenticationRequired: Bool) -> Bool {
        authenticationRequired && !isDismissed
    }

    /// The Parent's own explicit dismissal — a Cancel tap, an interactive
    /// swipe, or SwiftUI's own `.sheet(isPresented:)` setter firing
    /// `false`. Never itself a decision or a retry.
    mutating func dismiss() {
        isDismissed = true
    }

    /// The Parent's own explicit "Sign in to continue" tap from the
    /// `authenticationRequired` screen — reopens the SAME sheet for the
    /// SAME still-pending operation (the coordinator's own
    /// `pendingOperation` is untouched by dismissal, so this alone is
    /// enough; nothing here needs to re-derive or re-request anything).
    mutating func reopen() {
        isDismissed = false
    }

    /// Call whenever the coordinator's own state changes. Resets the
    /// dismissed flag once state leaves `.authenticationRequired` (a
    /// later success/failure, or a brand-new auth failure after a
    /// retry), so a genuinely new failure can present the sheet again
    /// without the Parent needing to do anything first.
    mutating func noteStateChanged(authenticationRequired: Bool) {
        guard !authenticationRequired else { return }
        isDismissed = false
    }
}
