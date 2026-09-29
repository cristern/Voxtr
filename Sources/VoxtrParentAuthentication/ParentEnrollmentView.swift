import SwiftUI
import AuthenticationServices

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

    public init(service: ParentAuthenticationService, workspaces: [EnrollableWorkspace]) {
        self.service = service
        self.workspaces = workspaces
        _isSignedIn = State(initialValue: service.isSignedIn())
        _selectedWorkspace = State(initialValue: workspaces.first)
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
        .task {
            if !isSignedIn && pendingHandshake == nil {
                pendingHandshake = try? await service.beginSignIn()
            }
        }
    }

    private var signInSection: some View {
        Section {
            SignInWithAppleButton(.signIn, onRequest: configureAppleRequest, onCompletion: handleAppleCompletion)
                .frame(height: 44)
                .disabled(pendingHandshake == nil)
                .accessibilityIdentifier("parentEnrollment.signInButton")
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

    // MARK: - Sign-in

    /// `SignInWithAppleButton.onRequest` is a SYNCHRONOUS callback — it
    /// cannot itself await the nonce fetch — so `pendingHandshake` must
    /// already have been populated by the `.task` above before the
    /// button becomes enabled (see `.disabled(pendingHandshake == nil)`).
    /// Only `.nonce` is set; no scopes are requested, since nothing in
    /// this flow uses an Apple-provided name/email (`ParentProfile`'s
    /// name comes from local onboarding, never from Apple).
    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.nonce = pendingHandshake?.hashedNonceHex ?? ""
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        guard let handshake = pendingHandshake else {
            statusMessage = "Please try again."
            return
        }
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                statusMessage = "Sign in with Apple did not return a usable credential."
                return
            }
            Task { await completeSignIn(handshake: handshake, identityToken: identityToken) }
        case .failure:
            statusMessage = "Sign-in was cancelled or failed."
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
                statusMessage = "Sign-in failed. Please try again."
                pendingHandshake = try? await service.beginSignIn()
            }
        } catch {
            statusMessage = "Could not reach the server. Please try again."
            pendingHandshake = try? await service.beginSignIn()
        }
    }

    private func signOut() async {
        await service.signOut()
        isSignedIn = false
        statusMessage = nil
        code = ""
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
                pendingHandshake = try? await service.beginSignIn()
            case .reauthenticationRequired:
                // Rotation cannot satisfy this — only a brand-new SIWA
                // handshake can (§2.6). Returning to the sign-in section
                // starts exactly that, without discarding the still-live
                // (just not fresh enough) token — see
                // ParentAuthenticationService.redeemEnrollment's own doc
                // comment.
                isSignedIn = false
                statusMessage = "For your security, please sign in again to confirm it's you."
                pendingHandshake = try? await service.beginSignIn()
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
