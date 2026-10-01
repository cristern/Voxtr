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
/// AUTHENTICATION RECOVERY (review round 2): when the coordinator
/// reports `.authenticationRequired`, this view presents the EXISTING,
/// unmodified `ParentEnrollmentView` (the package's own public SIWA
/// surface — `ParentSignInCoordinator` itself is package-internal, so
/// this is the only way `VoxtrAppShell` can "reuse the existing Parent
/// SIWA flow" rather than re-implementing it) as a sheet. The selected
/// athlete/invitation/request is never lost — the coordinator's own
/// `pendingOperation` preserves exactly what to retry, and nothing
/// retries automatically: dismissing that sheet is the Parent's own
/// explicit action, which is when `retryAfterReauthentication()` runs.
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
        }
    }

    private var isPresentingReauthentication: Binding<Bool> {
        Binding(
            get: {
                if case .authenticationRequired = coordinator.state { return true }
                return false
            },
            set: { _ in }
        )
    }

    /// Wraps the EXISTING, unmodified `ParentEnrollmentView` with a
    /// "Done" action — that view has no dismiss affordance of its own
    /// (it's designed to live in the Profile tab's own NavigationStack),
    /// so this sheet supplies one. Tapping Done is the Parent's own
    /// explicit signal that they're finished signing in; only THEN does
    /// `retryAfterReauthentication()` run, resuming exactly the
    /// operation (`start`/`decide`) that originally failed, for the
    /// exact same athlete/invitation/request — nothing here retries on
    /// its own.
    private var reauthenticationSheet: some View {
        NavigationStack {
            ParentEnrollmentView(service: parentAuthenticationService, workspaces: enrollableWorkspaces)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Task { await coordinator.retryAfterReauthentication() }
                        }
                        .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.reauthDoneButton")
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

    private func authenticationRequiredView(requirement: AthleteParentAuthenticationRequirement) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(Self.message(for: requirement))
                .multilineTextAlignment(.center)
                .foregroundStyle(VoxtrColor.textSecondary)
                .padding(.horizontal, 32)
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
