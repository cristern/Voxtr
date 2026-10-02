import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import VoxtrCore
import VoxtrCoreContracts
import VoxtrParentAuthentication

/// Athlete Connection V1 (backend device authorization): the Parent-
/// facing pairing screen — displays the backend-issued invitation as a
/// QR code, polls for submitted connection requests, and lets the Parent
/// compare each request's own display code against the Athlete's actual
/// device before explicitly approving or rejecting it.
///
/// ADDITIVE, not a replacement, alongside the existing, unmodified
/// `AthleteConnectionQRPairingView` (CKShare pairing) — see
/// `AthleteDeviceAuthorizationQRPayload`'s own doc comment.
///
/// PRIVACY: the QR code is only ever the invitation's own opaque id — no
/// athlete name, DOB, or raw workspace/participant identifier. The
/// display code shown per pending request is a selection consistency
/// check, never authorization itself (Normative Security Contract §3).
///
/// AUTHENTICATION RECOVERY (review round 2, extended in round 3, finished
/// in round 4): when the coordinator reports `.authenticationRequired`,
/// this view presents the EXISTING, unmodified `ParentEnrollmentView`
/// (the package's own
/// public SIWA surface — `ParentSignInCoordinator` itself is
/// package-internal, so this is the only way `VoxtrAppShell` can "reuse
/// the existing Parent SIWA flow" rather than re-implementing it) as a
/// sheet, in its own `forcesReauthentication` mode. The selected
/// athlete/invitation/request is never lost — the coordinator's own
/// `pendingOperation` preserves exactly what to retry. Nothing retries
/// automatically: dismissing the sheet (Cancel, swipe, or SwiftUI's own
/// setter) is purely a presentation-level choice —
/// `AthleteDeviceAuthorizationReauthenticationSheetPresentation` tracks
/// it without ever touching `pendingOperation` — and the Parent can
/// reopen the SAME sheet for the SAME operation at any time via
/// `authenticationRequiredView`'s own "Sign in to continue" action. Only
/// `onReauthenticated` (fired by `ParentEnrollmentView` itself, after a
/// brand-new completed SIWA handshake plus the Parent's own explicit
/// Continue tap) calls `retryAfterReauthentication()`.
@MainActor
public struct AthleteDeviceAuthorizationInvitationView: View {
    let athleteId: AthleteId
    let workspaceId: WorkspaceId
    let invitedBy: ActorId
    let athleteDisplayName: String
    let parentAuthenticationService: ParentAuthenticationService
    let enrollableWorkspaces: [EnrollableWorkspace]
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// A FRESH coordinator per presentation — SwiftUI reconstructs this
    /// view's `@State` the next time a `.sheet` presents it, so a new
    /// "Connect this device" tap for a different (or the same) athlete
    /// never resumes a previous, already-`.decided`/`.failed` state
    /// machine. Deliberately NOT shared/owned by a ViewModel for this
    /// reason.
    @State private var coordinator: AthleteDeviceAuthorizationInvitationCoordinator
    /// Captures exactly which pending request's Approve button was
    /// tapped, so the confirmation dialog below always acts on THAT
    /// specific request — never an ambient "currently selected" request
    /// that could go stale while the dialog is open.
    @State private var pendingApprovalConfirmation: PendingApprovalConfirmation?
    /// Review round 4: the Parent reauthentication sheet's own
    /// presentation state — extracted into a pure, testable type (see
    /// `AthleteDeviceAuthorizationReauthenticationSheetPresentation`'s own
    /// doc comment) rather than derived purely from `coordinator.state`,
    /// because the state alone can't tell "the Parent dismissed this"
    /// apart from "this is still the same authentication failure as
    /// before." Resets the moment `coordinator.state` leaves
    /// `.authenticationRequired`, so a LATER, genuinely new auth failure
    /// can present the sheet again.
    @State private var reauthenticationSheetPresentation = AthleteDeviceAuthorizationReauthenticationSheetPresentation()

    private struct PendingApprovalConfirmation: Identifiable {
        let invitation: AthleteDeviceAuthorizationInvitation
        let request: ConnectionRequestSummary
        var id: UUID { request.id }
    }

    public init(
        invitationService: AthleteDeviceAuthorizationInvitationService,
        parentAuthenticationService: ParentAuthenticationService,
        athleteId: AthleteId,
        workspaceId: WorkspaceId,
        invitedBy: ActorId,
        athleteDisplayName: String,
        enrollableWorkspaces: [EnrollableWorkspace],
        onDismiss: @escaping () -> Void
    ) {
        self._coordinator = State(initialValue: AthleteDeviceAuthorizationInvitationCoordinator(
            invitationService: invitationService,
            parentAuthenticationService: parentAuthenticationService
        ))
        self.athleteId = athleteId
        self.workspaceId = workspaceId
        self.invitedBy = invitedBy
        self.athleteDisplayName = athleteDisplayName
        self.parentAuthenticationService = parentAuthenticationService
        self.enrollableWorkspaces = enrollableWorkspaces
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            content
                .voxtrScreenBackground()
                .navigationTitle("Connect \(athleteDisplayName)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            coordinator.stop()
                            onDismiss()
                            dismiss()
                        }
                        .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.doneButton")
                    }
                }
                .task {
                    if case .idle = coordinator.state {
                        await coordinator.start(forAthlete: athleteId, workspaceId: workspaceId, invitedBy: invitedBy)
                    }
                }
                // Review round 2: stops any in-flight polling the
                // instant this screen leaves the hierarchy — an explicit
                // Done tap AND an interactive swipe dismissal both fire
                // `.onDisappear`, so neither can leave an orphaned poll
                // loop running.
                .onDisappear {
                    coordinator.stop()
                }
                .confirmationDialog(
                    "Does this match the code on \(athleteDisplayName)'s screen?",
                    isPresented: Binding(
                        get: { pendingApprovalConfirmation != nil },
                        set: { isPresented in if !isPresented { pendingApprovalConfirmation = nil } }
                    ),
                    presenting: pendingApprovalConfirmation
                ) { confirmation in
                    Button("Yes, it matches — approve") {
                        Task {
                            await coordinator.decide(
                                invitation: confirmation.invitation,
                                requestId: confirmation.request.id,
                                decision: .approved,
                                displayCode: confirmation.request.displayCode
                            )
                        }
                        pendingApprovalConfirmation = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingApprovalConfirmation = nil
                    }
                } message: { confirmation in
                    Text("Code shown here: \(confirmation.request.displayCode)")
                }
                .sheet(isPresented: isPresentingReauthentication) {
                    reauthenticationSheet
                }
                // The dismissed flag only means anything WHILE
                // `.authenticationRequired` — the moment that state is
                // left (a later success, failure, or a brand-new auth
                // failure after a retry), it's cleared, so a genuinely
                // new failure can present the sheet again.
                .onChange(of: coordinator.state) { _, newState in
                    let authenticationRequired: Bool
                    if case .authenticationRequired = newState { authenticationRequired = true } else { authenticationRequired = false }
                    reauthenticationSheetPresentation.noteStateChanged(authenticationRequired: authenticationRequired)
                }
        }
    }

    /// A REAL dismissible binding, unlike a binding whose `set` is a
    /// no-op: without a working setter, an interactive swipe-to-dismiss
    /// has nothing to write to, so SwiftUI's own `isPresented` getter
    /// (derived from `coordinator.state`, which dismissal alone never
    /// changes) would just report "still presented" and fight the
    /// Parent's own swipe. `reauthenticationSheetPresentation` gives the
    /// setter somewhere real to write.
    private var isPresentingReauthentication: Binding<Bool> {
        Binding(
            get: {
                let authenticationRequired: Bool
                if case .authenticationRequired = coordinator.state { authenticationRequired = true } else { authenticationRequired = false }
                return reauthenticationSheetPresentation.isPresented(authenticationRequired: authenticationRequired)
            },
            set: { isPresented in
                if !isPresented { reauthenticationSheetPresentation.dismiss() }
            }
        )
    }

    /// Wraps the EXISTING, unmodified `ParentEnrollmentView` in its own
    /// `forcesReauthentication` mode — shows the SIWA attempt directly
    /// even though the Parent's session is still nominally live (just
    /// not fresh enough), never the ordinary enrollment/sign-out
    /// sections. Cancelling here is the Parent's own explicit choice to
    /// not continue right now: it just dismisses, and does NOT call
    /// `retryAfterReauthentication()` — `pendingOperation` stays intact
    /// for a later retry. Only `onReauthenticated` (fired by
    /// `ParentEnrollmentView` itself, and ONLY after a brand-new SIWA
    /// handshake actually completed AND the Parent tapped its own
    /// explicit Continue) both dismisses this sheet and resumes exactly
    /// the operation (`start`/`decide`/`resumePolling`) that originally
    /// failed, for the exact same athlete/invitation/request — a mere
    /// "Done" tap is never treated as proof of that on its own.
    private var reauthenticationSheet: some View {
        NavigationStack {
            ParentEnrollmentView(
                service: parentAuthenticationService,
                workspaces: enrollableWorkspaces,
                forcesReauthentication: true,
                onReauthenticated: {
                    reauthenticationSheetPresentation.dismiss()
                    Task { await coordinator.retryAfterReauthentication() }
                }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        reauthenticationSheetPresentation.dismiss()
                    }
                    .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.reauthCancelButton")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .idle, .preparing:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .awaitingRequests(let invitation, let requests):
            awaitingRequestsView(invitation: invitation, requests: requests)
        case .decided(let outcome):
            decidedView(outcome: outcome)
        case .authenticationRequired(let requirement):
            authenticationRequiredView(requirement: requirement)
        case .failed(let message):
            failedView(message: message)
        }
    }

    /// Review round 4: shown both WHILE the reauthentication sheet is
    /// presented (as the content behind it) and, now, AFTER the Parent
    /// has explicitly dismissed it without completing a fresh SIWA
    /// handshake — no operation is actually running at that point, so
    /// this never shows a perpetual spinner; instead it offers a
    /// "Sign in to continue" action that simply reopens the SAME sheet
    /// for the SAME still-pending operation
    /// (`coordinator.pendingOperation` is untouched by dismissal).
    private func authenticationRequiredView(requirement: AthleteParentAuthenticationRequirement) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(VoxtrColor.textSecondary)
            Text(Self.message(for: requirement))
                .multilineTextAlignment(.center)
                .foregroundStyle(VoxtrColor.textSecondary)
                .padding(.horizontal, 32)
            Button("Sign in to continue") {
                reauthenticationSheetPresentation.reopen()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.reauthenticateButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.authenticationRequired")
    }

    private static func message(for requirement: AthleteParentAuthenticationRequirement) -> String {
        switch requirement {
        case .notSignedIn:
            return "Please sign in to continue."
        case .sessionInvalid, .sessionExpired:
            return "Your session has expired. Please sign in again."
        case .reauthenticationRequired:
            return "For your security, please sign in again to confirm it's you."
        }
    }

    private func awaitingRequestsView(invitation: AthleteDeviceAuthorizationInvitation, requests: [ConnectionRequestSummary]) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                qrCodeView(invitationId: invitation.invitationId)
                    .frame(width: 220, height: 220)

                Text("Open Vǫxtr Athlete on \(athleteDisplayName)'s phone and scan this code.")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                let pending = requests.filter { $0.status == .pending }
                if !pending.isEmpty {
                    VStack(spacing: 12) {
                        Text("Compare this code with \(athleteDisplayName)'s screen")
                            .font(VoxtrTypography.cardTitle)
                            .foregroundStyle(VoxtrColor.textPrimary)
                        ForEach(pending) { request in
                            pendingRequestRow(invitation: invitation, request: request)
                        }
                    }
                }
            }
            .padding(.vertical, 24)
        }
    }

    private func pendingRequestRow(invitation: AthleteDeviceAuthorizationInvitation, request: ConnectionRequestSummary) -> some View {
        VStack(spacing: 12) {
            Text(request.displayCode)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.pendingDisplayCode")
            HStack(spacing: 16) {
                Button("Reject") {
                    Task {
                        await coordinator.decide(
                            invitation: invitation,
                            requestId: request.id,
                            decision: .rejected,
                            displayCode: request.displayCode
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.isDecisionPending)
                .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.rejectButton")

                // Review round 2: Approve no longer decides directly —
                // it only stages a confirmation naming THIS exact
                // request, requiring the Parent to explicitly confirm
                // the physical comparison-code match before anything is
                // sent.
                Button("Approve") {
                    pendingApprovalConfirmation = PendingApprovalConfirmation(invitation: invitation, request: request)
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isDecisionPending)
                .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.approveButton")
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func decidedView(outcome: ConnectionRequestDecisionOutcome) -> some View {
        VStack(spacing: 16) {
            switch outcome {
            case .approved:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("Approved")
                    .font(VoxtrTypography.cardTitle)
                Text("Ask \(athleteDisplayName) to finish connecting on their device.")
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .multilineTextAlignment(.center)
            case .rejected:
                Text("Rejected")
                    .font(VoxtrTypography.cardTitle)
            default:
                Text("Couldn't complete that decision. Please try again.")
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Done") {
                onDismiss()
                dismiss()
            }
            .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.decidedDoneButton")
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.decidedState")
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .foregroundStyle(VoxtrColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Done") {
                onDismiss()
                dismiss()
            }
            .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.failedDoneButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func qrCodeView(invitationId: UUID) -> some View {
        let url = AthleteDeviceAuthorizationQRPayload.encode(invitationId: invitationId)
        if let qrImage = Self.qrImage(for: url.absoluteString) {
            Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.qrCode")
        } else {
            Text("Couldn't prepare a scannable code yet. Please try again.")
                .foregroundStyle(VoxtrColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    static func qrImage(for string: String) -> UIImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
