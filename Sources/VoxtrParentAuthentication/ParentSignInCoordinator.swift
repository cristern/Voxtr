import Foundation
import Observation

/// Injectable "now" for `ParentSignInCoordinator`'s nonce-freshness
/// check — production uses `SystemParentSignInClock`; deterministic
/// tests inject a fake, controllable clock instead of depending on
/// `Date()`/real `Task.sleep` delays to exercise the freshness bound.
protocol ParentSignInClock: Sendable {
    func now() -> Date
}

struct SystemParentSignInClock: ParentSignInClock {
    func now() -> Date { Date() }
}

/// Athlete Connection V1 — the SIWA sign-in ATTEMPT state machine,
/// extracted out of `ParentEnrollmentView` so it is testable without
/// SwiftUI (see `ParentSignInCoordinatorTests.swift`). Fixes a real race
/// in the original view-only implementation: `configureAppleRequest`
/// read a mutable "pending handshake" field to sign the Apple request,
/// while a separate background poll could replace that same field
/// while the Apple sheet was open — meaning the identity token Apple
/// eventually returns could get paired with a DIFFERENT nonce_id than
/// the one actually signed into the request Apple's sheet presented.
///
/// The fix has one core rule: once an attempt begins, its handshake is
/// PINNED into `activeAttempt` and nothing else may touch it or replace
/// it until the SAME attempt ends.
///
/// - `readyHandshake` is the idle, not-yet-attempted handshake sitting
///   ready for the NEXT tap — this is the only thing background renewal
///   (`fetchReadyHandshakeIfNeeded()`) is ever allowed to write.
/// - `beginAttempt()` is SYNCHRONOUS (callable directly from
///   `SignInWithAppleButton.onRequest`, which cannot itself await) and
///   moves whatever is currently in `readyHandshake` into
///   `activeAttempt`, atomically, in one call with no `await` in
///   between — there is no window in which both a renewal and a begin
///   could observe the same idle handshake and race over it.
/// - While `activeAttempt != nil`, `shouldFetchReadyHandshake` and
///   `canAttemptSignIn` are BOTH `false` — renewal is refused and the
///   button stays disabled for the attempt's entire lifetime (Apple
///   sheet open through backend completion), regardless of how much
///   time passes or whether an idle nonce would otherwise be due for
///   renewal.
/// - `cancelActiveAttempt()`/`completeActiveAttempt(identityToken:)`
///   each end the active attempt exactly once (the latter via `defer`,
///   so every return path — success, `authenticationFailed`, or a
///   thrown network error — clears it identically), freeing the
///   coordinator to pin a new attempt again.
@MainActor
@Observable
final class ParentSignInCoordinator {
    private(set) var isSignedIn: Bool
    private(set) var activeAttempt: PendingSiwaHandshake?
    private(set) var nonceFetchFailed = false
    var statusMessage: String?

    private var readyHandshake: PendingSiwaHandshake?
    private var readyHandshakeFetchedAt: Date?
    private var isFetchingReadyHandshake = false

    private let service: ParentAuthenticationService
    private let clock: ParentSignInClock
    /// The backend's `auth-nonce` nonce is valid for 60 seconds (see
    /// the contract's own §1 nonce-lifetime note and the merged
    /// `auth-nonce` handler). Deliberately a conservative margin UNDER
    /// that, not the backend's own value — this only bounds how long an
    /// IDLE (not-yet-attempted) handshake is offered up for a new
    /// attempt; it never expires an attempt already pinned into
    /// `activeAttempt` (see this type's own doc comment).
    private let freshnessBound: TimeInterval
    /// Review round 3: when `true`, this coordinator offers a fresh SIWA
    /// attempt even while `isSignedIn` is ALREADY `true` — i.e. a live
    /// but not-fresh-enough session, exactly the shape
    /// `ParentAuthenticationError.reauthenticationRequired` describes. A
    /// plain token refresh/rotation can never satisfy that requirement;
    /// only a brand-new handshake through this same coordinator can, so
    /// callers needing that (`ParentEnrollmentView`'s own
    /// `forcesReauthentication` mode) must still be able to reach
    /// `canAttemptSignIn`/`shouldFetchReadyHandshake` without first
    /// requiring the Parent to sign out.
    private let forceFreshSignIn: Bool

    /// Review round 3: `true` for exactly one fresh, successfully
    /// completed SIWA handshake — never for `isSignedIn` being true from
    /// a stored session, and never from a refresh/rotation (which never
    /// goes through this coordinator's own attempt lifecycle at all).
    /// Cleared the moment a NEW attempt is pinned (`beginAttempt()`), so
    /// it can never be read as "still fresh" across a later attempt.
    /// Exists specifically so a caller in `forceFreshSignIn` mode can
    /// require an explicit continuation after this flips `true`, rather
    /// than treating the flip itself (or a mere "Done" tap) as proof.
    private(set) var justCompletedFreshSignIn = false

    init(
        service: ParentAuthenticationService,
        clock: ParentSignInClock = SystemParentSignInClock(),
        freshnessBound: TimeInterval = 45,
        forceFreshSignIn: Bool = false
    ) {
        self.service = service
        self.isSignedIn = service.isSignedIn()
        self.clock = clock
        self.freshnessBound = freshnessBound
        self.forceFreshSignIn = forceFreshSignIn
    }

    // MARK: - Idle nonce freshness

    private var isReadyHandshakeFresh: Bool {
        guard let fetchedAt = readyHandshakeFetchedAt else { return false }
        return clock.now().timeIntervalSince(fetchedAt) < freshnessBound
    }

    /// Whether `SignInWithAppleButton` may currently be tapped — `false`
    /// for the entire duration of any active attempt (never re-enabled
    /// mid-attempt just because a fresh idle handshake happens to
    /// exist), and otherwise requires a present, fresh idle handshake.
    var canAttemptSignIn: Bool {
        activeAttempt == nil && readyHandshake != nil && isReadyHandshakeFresh
    }

    /// Whether fetching a new idle handshake is currently useful —
    /// `false` while signed in with that being enough (nothing left to
    /// sign in for) or while an attempt is active (there is nothing to
    /// renew: the active handshake is pinned and must not be touched),
    /// `true` whenever either genuinely signed out OR `forceFreshSignIn`
    /// is set (a live-but-stale session still needs a brand-new
    /// handshake offered directly, never gated behind the Parent finding
    /// a sign-out action first), and either nothing is held or what's
    /// held has gone stale.
    var shouldFetchReadyHandshake: Bool {
        (forceFreshSignIn || !isSignedIn) && activeAttempt == nil && (readyHandshake == nil || !isReadyHandshakeFresh)
    }

    /// Fetches a new idle handshake, replacing `readyHandshake` — but
    /// ONLY if no attempt is active both before AND after the network
    /// call (re-checked after the `await`, since `beginAttempt()` could
    /// have pinned the CURRENT `readyHandshake` while this fetch was in
    /// flight; discarding the result in that case is exactly what stops
    /// a renewal from clobbering an attempt that began mid-fetch). A
    /// no-op if a fetch is already in flight, or if renewal is not
    /// currently useful (see `shouldFetchReadyHandshake`).
    func fetchReadyHandshakeIfNeeded() async {
        guard shouldFetchReadyHandshake, !isFetchingReadyHandshake else { return }
        isFetchingReadyHandshake = true
        defer { isFetchingReadyHandshake = false }
        do {
            let handshake = try await service.beginSignIn()
            guard activeAttempt == nil else { return }
            readyHandshake = handshake
            readyHandshakeFetchedAt = clock.now()
            nonceFetchFailed = false
        } catch {
            guard activeAttempt == nil else { return }
            readyHandshake = nil
            readyHandshakeFetchedAt = nil
            nonceFetchFailed = true
            statusMessage = "Couldn't prepare sign-in. Check your connection and try again."
        }
    }

    // MARK: - Attempt lifecycle

    /// Pins the current idle handshake as the ACTIVE attempt and returns
    /// it — SYNCHRONOUS, meant to be called directly from
    /// `SignInWithAppleButton.onRequest`. Returns `nil` (and pins
    /// nothing) if no attempt can begin right now — no idle handshake,
    /// a stale one, or an attempt already active; the caller must sign
    /// the Apple request with an empty/invalid nonce in that case rather
    /// than reuse anything, which the backend safely rejects the same
    /// way it rejects any other failed attempt.
    @discardableResult
    func beginAttempt() -> PendingSiwaHandshake? {
        guard activeAttempt == nil, let handshake = readyHandshake, isReadyHandshakeFresh else {
            return nil
        }
        activeAttempt = handshake
        readyHandshake = nil
        readyHandshakeFetchedAt = nil
        // A NEW attempt starting means any PREVIOUS attempt's freshness
        // is no longer what's current — never read as "still fresh" for
        // this one.
        justCompletedFreshSignIn = false
        return handshake
    }

    /// The Apple sheet was cancelled, or Apple itself reported failure,
    /// before ever reaching the backend. Ends the active attempt
    /// (freeing the coordinator to pin a new one) — a no-op if none was
    /// active.
    func cancelActiveAttempt() {
        guard activeAttempt != nil else { return }
        activeAttempt = nil
        statusMessage = "Sign-in was cancelled or failed."
    }

    /// Completes the CURRENTLY ACTIVE attempt against the backend, using
    /// exactly the handshake `beginAttempt()` pinned — never whatever
    /// `readyHandshake` might hold by the time this call actually
    /// resolves. Ends the attempt exactly once, via `defer`, regardless
    /// of which outcome or error path is taken below.
    func completeActiveAttempt(identityToken: String) async {
        guard let handshake = activeAttempt else {
            statusMessage = "Please try again."
            return
        }
        defer { activeAttempt = nil }
        do {
            let outcome = try await service.completeSignIn(
                handshake: handshake,
                credential: AppleIdentityCredential(identityToken: identityToken)
            )
            switch outcome {
            case .authenticated:
                isSignedIn = true
                statusMessage = nil
                justCompletedFreshSignIn = true
            case .authenticationFailed:
                // Also reached if the backend authenticated the
                // handshake but the service itself discarded the
                // resulting session because the user signed out while
                // this call was in flight (see
                // `ParentAuthenticationService.completeSignIn`'s own
                // generation-guard doc comment), or if the Apple sheet
                // stayed open long enough for the nonce to have expired
                // server-side before this call reached
                // `parent-auth-complete` (§1's anti-enumeration design
                // means the wire response never distinguishes "wrong
                // credential" from "expired nonce") — either way, the
                // caller pinning a fresh handshake for a new attempt is
                // the correct, sufficient recovery.
                statusMessage = "Sign-in failed. Please try again."
            }
        } catch {
            statusMessage = "Could not reach the server. Please try again."
        }
    }

    // MARK: - Sign-out

    /// Flips `isSignedIn` to `false` and clears any stale status message
    /// SYNCHRONOUSLY — before best-effort server-side revocation is even
    /// attempted — so the UI reflects "signed out" immediately rather
    /// than waiting on a network call that may be slow or fail. Returns
    /// the (fire-and-forget from the caller's perspective) `Task`
    /// performing that revocation so deterministic tests can await it;
    /// production call sites simply discard it. If revocation later
    /// turns out to have failed server-side, `statusMessage` is updated
    /// truthfully once that result is known — this never claims success
    /// it can't confirm.
    @discardableResult
    func signOut() -> Task<Void, Never> {
        isSignedIn = false
        statusMessage = nil
        return Task {
            let serverConfirmedRevocation = await self.service.signOut()
            if !serverConfirmedRevocation {
                self.statusMessage = "Signed out on this device. We couldn't confirm your session was closed on the server."
            }
        }
    }

    /// Forces local sign-out WITHOUT attempting server-side revocation —
    /// used when the BACKEND itself has already reported the session is
    /// no longer usable (`sessionInvalid`/`sessionExpired`/
    /// `reauthenticationRequired` from `redeemEnrollment`), as opposed
    /// to `signOut()`, which is the user's own explicit action and does
    /// attempt best-effort revocation of a session that, as far as the
    /// device knows, might still be live.
    func forceSignedOut(statusMessage: String) {
        isSignedIn = false
        self.statusMessage = statusMessage
    }
}
