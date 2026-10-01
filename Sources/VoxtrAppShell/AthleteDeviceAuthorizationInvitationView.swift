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
@MainActor
public struct AthleteDeviceAuthorizationInvitationView: View {
    let athleteId: AthleteId
    let workspaceId: WorkspaceId
    let invitedBy: ActorId
    let athleteDisplayName: String
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// A FRESH coordinator per presentation — SwiftUI reconstructs this
    /// view's `@State` the next time a `.sheet` presents it, so a new
    /// "Connect this device" tap for a different (or the same) athlete
    /// never resumes a previous, already-`.decided`/`.failed` state
    /// machine. Deliberately NOT shared/owned by a ViewModel for this
    /// reason.
    @State private var coordinator: AthleteDeviceAuthorizationInvitationCoordinator

    public init(
        invitationService: AthleteDeviceAuthorizationInvitationService,
        parentAuthenticationService: ParentAuthenticationService,
        athleteId: AthleteId,
        workspaceId: WorkspaceId,
        invitedBy: ActorId,
        athleteDisplayName: String,
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
        case .failed(let message):
            failedView(message: message)
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
                .accessibilityIdentifier("athleteDeviceAuthorizationInvitation.rejectButton")

                Button("Approve") {
                    Task {
                        await coordinator.decide(
                            invitation: invitation,
                            requestId: request.id,
                            decision: .approved,
                            displayCode: request.displayCode
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
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
