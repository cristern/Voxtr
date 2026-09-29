import SwiftUI
import AuthenticationServices
import Foundation

/// Athlete Connection V1 — the modest ParentApp entry point for sign-in,
/// workspace selection, and enrollment code entry (see cristern/Voxtr
/// Docs/Architecture/AthleteConnectionV1-ParentAuthenticationContract.md
/// §6). This is the ONLY place in this package that touches
/// `AuthenticationServices` UI directly — `ParentAuthenticationService`
/// itself has no dependency on it at all, so the orchestration logic is
/// fully testable without ever presenting a real system sign-in sheet.
///
/// `workspaces` is supplied by the caller (`VoxtrAppShell`), which is
/// the only place allowed to call `ParentWorkspaceRepository
/// .fetchAllWorkspaces()` and map each `FamilyWorkspace.workspaceId
/// .rawValue` to an `EnrollableWorkspace` — this package never imports
/// `VoxtrParentDomain`/SwiftData, per this contract's own domain-
/// ownership boundary.
public struct ParentEnrollmentView: View {
    private let service: ParentAuthenticationService
    private let workspaces: [EnrollableWorkspace]

    @State private var isSignedIn: Bool
    @State private var selectedWorkspace: EnrollableWorkspace?
    @State private var code: String = ""
    @State private var statusMessage: String?
    @State private var isSubmitting = false
    @State private var pendingHandshake: PendingSiwaHandshake?
    /// When `pendingHandshake` was fetched, on THIS device's own clock —
    /// never the backend's `expires_at`, since this is only a
    /// conservative client-side safety margin, not the source of truth
    /// for the nonce's actual server-side lifetime. See
    /// `nonceFreshnessBound`'s own doc comment.
    @State private var pendingHandshakeFetchedAt: Date?
    @State private var isFetchingNonce = false
    @State private var nonceFetchFailed = false

    public init(service: ParentAuthenticationService, workspaces: [EnrollableWorkspace]) {
        self.service = service
        self.workspaces = workspaces
        _isSignedIn = State(initialValue: service.isSignedIn())
        _selectedWorkspace = State(initialValue: workspaces.first)
    }

    /// The backend's `auth-nonce` nonce is valid for 60 seconds (see the
    /// contract's own §1 nonce-lifetime note and the merged `auth-nonce`
    /// handler). This is deliberately a conservative margin under that,
    /// not the backend's own value — the device must stop presenting a
    /// nonce as usable well before the backend would actually reject it,
    /// since `configureAppleRequest(_:)` below cannot itself await a
    /// fresh one mid-tap (`SignInWithAppleButton.onRequest` is
    /// synchronous).
    private static let nonceFreshnessBound: TimeInterval = 45
    /// How often `keepNonceFresh()` checks whether the current handshake
    /// has crossed `nonceFreshnessBound` while sitting unused — short
    /// enough that the sign-in button is never left disabled for long,
    /// long enough not to hammer `auth-nonce`.
    private static let nonceFreshnessPollInterval: Duration = .seconds(5)

    private var isPendingHandshakeFresh: Bool {
        guard let fetchedAt = pendingHandshakeFetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) < Self.nonceFreshnessBound
    }

    private var canAttemptSignIn: Bool {
        pendingHandshake != nil && isPendingHandshakeFresh
    }

    public var body: some View {
        Form {
            if !isSignedIn {
                signInSection
            } else {
                enrollmentSection
                signOutSection
            }
        }
        .navigationTitle("Parent Account")
        // Keyed on `isSignedIn` rather than a one-shot `.task`: SwiftUI
        // cancels and restarts this task whenever `isSignedIn` changes,
        // which is exactly what "signing out must enable a new SIWA
        // attempt without navigating away" needs — no manual task
        // bookkeeping in `signOut()` below. While signed in, the guard
        // makes this an immediate no-op (no reason to hold a nonce).
        .task(id: isSignedIn) {
            guard !isSignedIn else { return }
            await keepNonceFresh()
        }
    }

    private var signInSection: some View {
        Section {
            SignInWithAppleButton(.signIn, onRequest: configureAppleRequest, onCompletion: handleAppleCompletion)
                .frame(height: 44)
                .disabled(!canAttemptSignIn)
                .accessibilityIdentifier("parentEnrollment.signInButton")
            if nonceFetchFailed {
                Button("Retry") {
                    Task { await fetchNonce() }
                }
                .accessibilityIdentifier("parentEnrollment.retryNonceButton")
            }
        } header: {
            Text("Sign in")
        } footer: {
            if let statusMessage {
                Text(statusMessage)
                    .accessibilityIdentifier("parentEnrollment.statusMessage")
            }
        }
    }

    private var enrollmentSection: some View {
        Section {
            if workspaces.isEmpty {
                Text("No workspace found on this device yet.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Workspace", selection: $selectedWorkspace) {
                    ForEach(workspaces) { workspace in
                        Text(workspace.displayName).tag(Optional(workspace))
                    }
                }
                .accessibilityIdentifier("parentEnrollment.workspacePicker")
            }
            TextField("Enrollment code", text: $code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("parentEnrollment.codeField")
            Button("Submit") {
                Task { await submitRedemption() }
            }
            .disabled(selectedWorkspace == nil || code.isEmpty || isSubmitting)
            .accessibilityIdentifier("parentEnrollment.submitButton")
        } header: {
            Text("Enroll this workspace")
        } footer: {
            if let statusMessage {
                Text(statusMessage)
                    .accessibilityIdentifier("parentEnrollment.statusMessage")
            }
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Sign out", role: .destructive) {
                Task { await signOut() }
            }
            .accessibilityIdentifier("parentEnrollment.signOutButton")
        }
    }

    // MARK: - Nonce lifecycle

    /// Runs for as long as the sign-in section is visible (SwiftUI
    /// cancels it automatically once `isSignedIn` flips `true`, or this
    /// view goes away) — fetches a nonce immediately if needed, then
    /// polls to replace it before it crosses this view's own
    /// conservative freshness bound, so the Sign in with Apple button is
    /// available whenever possible rather than going permanently stale.
    /// Every place a handshake is CONSUMED (a completion attempt,
    /// success or failure) also triggers an immediate `fetchNonce()` of
    /// its own rather than waiting out this loop's own poll interval —
    /// this loop is the steady-state/idle-staleness safety net, not the
    /// only path to a fresh nonce.
    private func keepNonceFresh() async {
        while !Task.isCancelled {
            if pendingHandshake == nil || !isPendingHandshakeFresh {
                await fetchNonce()
            }
            try? await Task.sleep(for: Self.nonceFreshnessPollInterval)
        }
    }

    /// Fetches a fresh handshake and records when it was fetched (for
    /// `isPendingHandshakeFresh`'s own bound check). `isFetchingNonce`
    /// guards against wasteful concurrent duplicate fetches — the
    /// background poll loop and an explicit consumption-triggered call
    /// can otherwise both land at nearly the same moment.
    private func fetchNonce() async {
        guard !isFetchingNonce else { return }
        isFetchingNonce = true
        defer { isFetchingNonce = false }
        do {
            let handshake = try await service.beginSignIn()
            pendingHandshake = handshake
            pendingHandshakeFetchedAt = Date()
            nonceFetchFailed = false
        } catch {
            pendingHandshake = nil
            pendingHandshakeFetchedAt = nil
            nonceFetchFailed = true
            statusMessage = "Couldn't prepare sign-in. Check your connection and try again."
        }
    }

    // MARK: - Sign-in

    /// `SignInWithAppleButton.onRequest` is a SYNCHRONOUS callback — it
    /// cannot itself await the nonce fetch — so `pendingHandshake` must
    /// already have been populated by `keepNonceFresh()` before the
    /// button becomes enabled (see `.disabled(!canAttemptSignIn)`).
    /// Re-checks freshness here too, defensively: `canAttemptSignIn`
    /// already keeps the button disabled once a handshake goes stale,
    /// but if one somehow slipped past that (a narrow window between
    /// SwiftUI evaluating `.disabled` and this callback firing), this
    /// never signs the request with a nonce past this view's own
    /// conservative bound — an empty nonce is safely rejected by the
    /// backend, which triggers the same `authentication_failed` recovery
    /// path as any other rejected attempt. Only `.nonce` is set; no
    /// scopes are requested, since nothing in this flow uses an Apple-
    /// provided name/email (`ParentProfile`'s name comes from local
    /// onboarding, never from Apple).
    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard let pendingHandshake, isPendingHandshakeFresh else {
            request.nonce = ""
            return
        }
        request.nonce = pendingHandshake.hashedNonceHex
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        guard let handshake = pendingHandshake else {
            statusMessage = "Please try again."
            return
        }
        // Consume the handshake immediately, synchronously, before any
        // awaiting begins — a nonce is single-use, and this is also
        // what prevents a duplicate/tapped-twice completion of this
        // exact handshake: `canAttemptSignIn` requires `pendingHandshake
        // != nil`, so the button is already disabled by the time either
        // branch below starts its own async work.
        pendingHandshake = nil
        pendingHandshakeFetchedAt = nil

        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                statusMessage = "Sign in with Apple did not return a usable credential."
                Task { await fetchNonce() }
                return
            }
            Task { await completeSignIn(handshake: handshake, identityToken: identityToken) }
        case .failure:
            // Cancellation or an Apple-side failure — the nonce this
            // handshake carried is discarded (never reused), and the
            // sign-in section must remain usable, so fetch a fresh one
            // right away rather than waiting for the background poll.
            statusMessage = "Sign-in was cancelled or failed."
            Task { await fetchNonce() }
        }
    }

    private func completeSignIn(handshake: PendingSiwaHandshake, identityToken: String) async {
        do {
            let outcome = try await service.completeSignIn(
                handshake: handshake,
                credential: AppleIdentityCredential(identityToken: identityToken)
            )
            switch outcome {
            case .authenticated:
                isSignedIn = true
                statusMessage = nil
            case .authenticationFailed:
                // Also reached if the backend authenticated the
                // handshake but the service discarded the resulting
                // session because the user signed out while this call
                // was in flight (see `ParentAuthenticationService
                // .completeSignIn`'s own generation-guard doc comment) —
                // either way, a fresh nonce is what lets the user try
                // again. Because the Apple sheet itself can take long
                // enough for the nonce to have expired server-side
                // before this call reached `parent-auth-complete`, this
                // is also the path that recovers from that case: a
                // stale nonce reads to the backend as an ordinary failed
                // authentication (§1's anti-enumeration design — the
                // wire response never distinguishes "wrong credential"
                // from "expired nonce"), so restarting with a brand-new
                // nonce here is the correct, sufficient recovery for
                // both causes.
                statusMessage = "Sign-in failed. Please try again."
                await fetchNonce()
            }
        } catch {
            statusMessage = "Could not reach the server. Please try again."
            await fetchNonce()
        }
    }

    private func signOut() async {
        let serverConfirmedRevocation = await service.signOut()
        isSignedIn = false
        code = ""
        // The local token is always cleared by `service.signOut()`
        // regardless of network outcome — never claim the SERVER side
        // succeeded when it didn't.
        statusMessage = serverConfirmedRevocation
            ? nil
            : "Signed out on this device. We couldn't confirm your session was closed on the server."
        // `isSignedIn` flipping to `false` restarts the `.task(id:)`
        // above on its own, which calls `keepNonceFresh()` and fetches a
        // new handshake immediately — no manual fetch needed here.
    }

    // MARK: - Redemption

    private func submitRedemption() async {
        guard let workspace = selectedWorkspace else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let outcome = try await service.redeemEnrollment(workspace: workspace, code: code)
            statusMessage = message(for: outcome)
            switch outcome {
            case .bound, .alreadyRedeemedBySameParent:
                code = ""
            default:
                break
            }
        } catch let error as ParentAuthenticationError {
            switch error {
            case .sessionInvalid, .sessionExpired, .notSignedIn:
                isSignedIn = false
                statusMessage = "Your session has expired. Please sign in again."
            case .reauthenticationRequired:
                // Rotation cannot satisfy this — only a brand-new SIWA
                // handshake can (§2.6). Returning to the sign-in section
                // starts exactly that (via the `.task(id: isSignedIn)`
                // restart above), without discarding the still-live
                // (just not fresh enough) token — see
                // ParentAuthenticationService.redeemEnrollment's own doc
                // comment.
                isSignedIn = false
                statusMessage = "For your security, please sign in again to confirm it's you."
            case .network, .malformedResponse:
                statusMessage = "Something went wrong. Please try again."
            }
        } catch {
            statusMessage = "Something went wrong. Please try again."
        }
    }

    private func message(for outcome: RedemptionOutcome) -> String {
        switch outcome {
        case .bound:
            return "This workspace is now linked to your account."
        case .alreadyRedeemedBySameParent:
            return "This workspace is already linked to your account."
        case .authorizationAlreadyRedeemed:
            return "This code has already been used by a different parent."
        case .bindingRevoked:
            return "This workspace's previous link was revoked. Contact support for a new code."
        case .workspaceAlreadyBound:
            return "This workspace is already linked to a different parent."
        case .inconsistentState:
            return "Something is inconsistent on our end. Please contact support."
        case .authorizationNotAvailable:
            return "That code is invalid, expired, or has been cancelled."
        }
    }
}
