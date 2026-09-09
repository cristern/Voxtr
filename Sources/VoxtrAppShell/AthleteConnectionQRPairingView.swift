import CloudKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Athlete Connection QR-first V1: the Parent-facing pairing screen —
/// presents the ALREADY-CREATED canonical invitation
/// (`AthleteConnectionOwnerHandoffService.prepareInvitation`'s own
/// `AthleteConnectionInvitationHandoff`) as a QR code encoding its
/// existing `CKShare.url` VERBATIM. Never a second, parallel invitation
/// payload — QR is only a nearby presentation/transport mechanism for
/// the same canonical handoff `CloudSharingPresenter` (the Apple
/// recipient/share UI) already carried. Replaces that presenter as the
/// V1 default happy path, per the approved product direction recorded in
/// `Docs/AthleteConnectionFoundationB-Closeout.md`'s own "Approved
/// product direction — QR-first nearby pairing" section — that file is
/// left in place, simply unused by this screen, for later remote/
/// flexible sharing scope (Messages/Mail/AirDrop/copy-link), which
/// remains explicitly out of scope here.
///
/// PRIVACY: the QR code is only ever the opaque `CKShare.url` — no
/// athlete name, DOB, or raw workspace/participant/athlete ID is encoded
/// into it. `share.publicPermission == .none` (set once, at share
/// creation, by `FamilyWorkspaceOwnerShareCoordinator.createInvitationShare` —
/// unchanged by this screen) already means possessing this URL alone is
/// not sufficient to join; CloudKit's own accept flow still applies.
/// Never logged: the QR image is rendered directly from
/// `handoff.share.url` in-memory, never written to a diagnostic or
/// persisted anywhere by this screen.
public struct AthleteConnectionQRPairingView: View {
    public let handoff: AthleteConnectionInvitationHandoff
    public let athleteDisplayName: String
    public let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    public init(handoff: AthleteConnectionInvitationHandoff, athleteDisplayName: String, onDismiss: @escaping () -> Void) {
        self.handoff = handoff
        self.athleteDisplayName = athleteDisplayName
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Text("Connect \(athleteDisplayName)")
                    .font(VoxtrTypography.cardTitle)
                    .foregroundStyle(VoxtrColor.textPrimary)

                qrCodeView
                    .frame(width: 260, height: 260)

                Text("Open Vǫxtr Athlete on \(athleteDisplayName)'s phone and scan this code.")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()
            }
            .voxtrScreenBackground()
            .navigationTitle("Scan to connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                        dismiss()
                    }
                    .accessibilityIdentifier("athleteConnectionQR.doneButton")
                }
            }
        }
    }

    /// `handoff.share.url` is `Optional` per Apple's own `CKShare` API —
    /// this screen already only ever presents an ALREADY-SAVED share (see
    /// `FamilyWorkspaceOwnerShareCoordinator.createInvitationShare`, which
    /// awaits a successful save before returning), so it is expected to
    /// be populated here; a calm, honest fallback message is shown rather
    /// than fabricating a QR code from any other value if it is not — no
    /// invented fallback content presented as truth.
    @ViewBuilder
    private var qrCodeView: some View {
        if let url = handoff.share.url, let qrImage = Self.qrImage(for: url.absoluteString) {
            Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityIdentifier("athleteConnectionQR.code")
        } else {
            Text("Couldn't prepare a scannable code yet. Please try again.")
                .foregroundStyle(VoxtrColor.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("athleteConnectionQR.unavailableMessage")
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
