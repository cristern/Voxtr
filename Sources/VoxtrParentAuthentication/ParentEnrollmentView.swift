import SwiftUI
import AuthenticationServices

/// Athlete Connection V1 — the modest ParentApp entry point for sign-in,
/// workspace selection, and enrollment code entry (see cristern/Voxtr
/// Docs/Architecture/AthleteConnectionV1-ParentAuthenticationContract.md
/// §6). This is the ONLY place in this package that touches
/// `AuthenticationServices` UI directly — neither `ParentAuthenticationService`
/// nor `ParentSignInCoordinator` depend on it at all, so the sign-in
/// state machine is fully testable without ever presenting a real
/// system sign-in sheet.
///
/// The sign-in ATTEMPT lifecycle (pinning a handshake at Apple request
/// creation, keeping it immune to idle nonce renewal, disabling the
/// button for the attempt's whole lifetime, ending it exactly once) all
/// lives in `ParentSignInCoordinator` — see that type's own doc comment
/// for the race it fixes. This view only wires SwiftUI/
/// `AuthenticationServices` callbacks to that coordinator and renders
/// its state; workspace selection and code redemption (unrelated to the
/// sign-in race) remain here.
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
    /// Review round 3: when `true`, this view is being presented
    /// specifically to satisfy `ParentAuthenticationError
    /// .reauthenticationRequired` for some OTHER sensitive operation
    /// elsewhere (e.g. `AthleteDeviceAuthorizationInvitationCoordinator`'s
    /// own `start`/`decide`) — it shows ONLY the SIWA attempt, directly,
    /// even though `coordinator.isSignedIn` is already `true` (a live
    /// but not-fresh-enough session is exactly this situation); it never
    /// shows workspace enrollment or sign-out, which are not what this
    /// presentation is for.
    private let forcesReauthentication: Bool
    /// Fires once, only after a BRAND-NEW SIWA handshake has actually
    /// completed successfully in `forcesReauthentication` mode AND the
    /// Parent has explicitly tapped Continue — never merely from
    /// `coordinator.isSignedIn` already being `true`, and never from
    /// this view simply being dismissed. `nil` outside
    /// `forcesReauthentication` mode.
    private let onReauthenticated: (() -> Void)?

    @State private var coordinator: ParentSignInCoordinator
    @State private var selectedWorkspace: EnrollableWorkspace?
    @State private var code: String = ""
    @State private var isSubmitting = false

    public init(
        service: ParentAuthenticationService,
        workspaces: [EnrollableWorkspace],
        forcesReauthentication: Bool = false,
        onReauthenticated: (() -> Void)? = nil
    ) {
        self.service = service
        self.workspaces = workspaces
        self.forcesReauthentication = forcesReauthentication
        self.onReauthenticated = onReauthenticated
        _coordinator = State(initialValue: ParentSignInCoordinator(service: service, forceFreshSignIn: forcesReauthentication))
        _selectedWorkspace = State(initialValue: workspaces.first)
    }

    /// How often the background poll checks whether the coordinator's
    /// idle handshake is due for renewal — short enough that the
    /// sign-in button is never left disabled for long, long enough not
    /// to hammer `auth-nonce`. The coordinator itself decides WHETHER a
    /// fetch is actually useful right now (`shouldFetchReadyHandshake`)
    /// — in particular, it refuses outright for as long as an attempt is
    /// active, regardless of this timer.
    private static let nonceFreshnessPollInterval: Duration = .seconds(5)

    public var body: some View {
        Form {
            if forcesReauthentication {
                if coordinator.justCompletedFreshSignIn {
                    freshSignInConfirmedSection
                } else {
                    signInSection
                }
            } else if !coordinator.isSignedIn {
                signInSection
            } else {
                enrollmentSection
                signOutSection
            }
        }
        .navigationTitle("Parent Account")
        // Keyed on `isSignedIn` rather than a one-shot `.task`: SwiftUI
        // cancels and restarts this task whenever it changes, which is
        // exactly what "signing out must enable a new SIWA attempt
        // without navigating away" needs — no manual task bookkeeping
        // in `signOut()`. In `forcesReauthentication` mode this must
        // start even though `isSignedIn` is already (and stays) `true`
        // — a live-but-stale session still needs a fresh idle handshake
        // offered directly; `keepNonceFresh()` itself stops once a
        // fresh sign-in actually completes.
        .task(id: coordinator.isSignedIn) {
            guard forcesReauthentication || !coordinator.isSignedIn else { return }
            await keepNonceFresh()
        }
    }

    /// Shown only in `forcesReauthentication` mode, only once a BRAND
    /// NEW handshake has actually completed — requires its own explicit
    /// tap before firing `onReauthenticated`, so neither the flip to
    /// `justCompletedFreshSignIn` alone nor merely dismissing this sheet
    /// can be mistaken for that confirmation.
    private var freshSignInConfirmedSection: some View {
        Section {
            Button("Continue") {
                onReauthenticated?()
            }
            .accessibilityIdentifier("parentEnrollment.continueAfterReauthButton")
        } header: {
            Text("Signed in")
        } footer: {
            Text("You're signed in again. Tap Continue to pick up where you left off.")
        }
    }

    private var signInSection: some View {
        Section {
            SignInWithAppleButton(.signIn, onRequest: configureAppleRequest, onCompletion: handleAppleCompletion)
                .frame(height: 44)
                .disabled(!coordinator.canAttemptSignIn)
                .accessibilityIdentifier("parentEnrollment.signInButton")
            if coordinator.nonceFetchFailed {
                Button("Retry") {
                    Task { await coordinator.fetchReadyHandshakeIfNeeded() }
                }
                .accessibilityIdentifier("parentEnrollment.retryNonceButton")
            }
        } header: {
            Text("Sign in")
        } footer: {
            if let statusMessage = coordinator.statusMessage {
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
            if let statusMessage = coordinator.statusMessage {
                Text(statusMessage)
                    .accessibilityIdentifier("parentEnrollment.statusMessage")
            }
        }
    }

    private var signOutSection: some View {
        Section {
            // Synchronous on purpose: `ParentSignInCoordinator.signOut()`
            // flips `isSignedIn` immediately, before any network call,
            // and returns its own best-effort revocation `Task`
            // internally rather than requiring the caller to await one —
            // wrapping this in `Task { await ... }` would reintroduce
            // exactly the delay this fix removes.
            Button("Sign out", role: .destructive) {
                code = ""
                coordinator.signOut()
            }
            .accessibilityIdentifier("parentEnrollment.signOutButton")
        }
    }

    // MARK: - Nonce lifecycle

    /// Runs for as long as the sign-in section is visible (SwiftUI
    /// cancels it automatically once `coordinator.isSignedIn` flips
    /// `true`, or this view goes away) — the coordinator itself decides
    /// whether each poll actually does anything.
    private func keepNonceFresh() async {
        while !Task.isCancelled {
            if forcesReauthentication && coordinator.justCompletedFreshSignIn { return }
            await coordinator.fetchReadyHandshakeIfNeeded()
            try? await Task.sleep(for: Self.nonceFreshnessPollInterval)
        }
    }

    // MARK: - Sign-in

    /// `SignInWithAppleButton.onRequest` is a SYNCHRONOUS callback — it
    /// cannot itself await a nonce fetch. `coordinator.beginAttempt()`
    /// is itself synchronous for exactly this reason: it atomically pins
    /// whatever idle handshake is currently ready as THIS attempt's
    /// handshake, in one call with no `await` in between, so there is no
    /// window for a concurrent renewal to race it. If no idle handshake
    /// is available/fresh right now (should be unreachable given
    /// `.disabled(!coordinator.canAttemptSignIn)`, but never trusted
    /// blindly), an empty nonce is signed instead of reusing anything —
    /// the backend safely rejects that the same way it rejects any other
    /// failed attempt. Only `.nonce` is set; no scopes are requested,
    /// since nothing in this flow uses an Apple-provided name/email
    /// (`ParentProfile`'s name comes from local onboarding, never from
    /// Apple).
    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.nonce = coordinator.beginAttempt()?.hashedNonceHex ?? ""
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                coordinator.cancelActiveAttempt()
                coordinator.statusMessage = "Sign in with Apple did not return a usable credential."
                Task { await coordinator.fetchReadyHandshakeIfNeeded() }
                return
            }
            Task {
                await coordinator.completeActiveAttempt(identityToken: identityToken)
                // The attempt just ended (success or failure) — fetch a
                // fresh idle handshake right away rather than waiting
                // out the background poll's own interval.
                await coordinator.fetchReadyHandshakeIfNeeded()
            }
        case .failure:
            // Cancellation or an Apple-side failure — the pinned
            // attempt handshake is discarded (never reused), and the
            // sign-in section must remain usable, so fetch a fresh idle
            // one right away.
            coordinator.cancelActiveAttempt()
            Task { await coordinator.fetchReadyHandshakeIfNeeded() }
        }
    }

    // MARK: - Redemption

    private func submitRedemption() async {
        guard let workspace = selectedWorkspace else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let outcome = try await service.redeemEnrollment(workspace: workspace, code: code)
            coordinator.statusMessage = message(for: outcome)
            switch outcome {
            case .bound, .alreadyRedeemedBySameParent:
                code = ""
            default:
                break
            }
        } catch let error as ParentAuthenticationError {
            switch error {
            case .sessionInvalid, .sessionExpired, .notSignedIn:
                coordinator.forceSignedOut(statusMessage: "Your session has expired. Please sign in again.")
            case .reauthenticationRequired:
                // Rotation cannot satisfy this — only a brand-new SIWA
                // handshake can (§2.6). Returning to the sign-in section
                // starts exactly that (via the `.task(id:)` restart
                // above), without discarding the still-live (just not
                // fresh enough) token — see
                // ParentAuthenticationService.redeemEnrollment's own doc
                // comment.
                coordinator.forceSignedOut(statusMessage: "For your security, please sign in again to confirm it's you.")
            case .network, .malformedResponse:
                coordinator.statusMessage = "Something went wrong. Please try again."
            }
        } catch {
            coordinator.statusMessage = "Something went wrong. Please try again."
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
