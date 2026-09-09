import SwiftUI
import UIKit
import VoxtrCore

/// Athlete Connection QR-first V1: AthleteApp's "Scan connection code"
/// screen — the smallest calm V1 flow tying together `QRCodeScannerView`
/// (camera/UI only), `AthleteConnectionQRCode`/`AthleteConnectionScanCoordinator`
/// (payload validation + orchestration), and the EXISTING, unmodified
/// `AthleteRuntimeSession` connection state machine. Presents no fake
/// percentages/countdowns/urgency — matches Calm by Default.
///
/// A fresh `scanAttempt` identity (`.id(scanAttempt)`) is the retry
/// mechanism: incrementing it discards the previous `QRCodeScannerViewController`
/// and constructs a brand-new one, which starts a clean capture session
/// with its own single-shot `hasEmittedScan` guard — never a bespoke
/// "resume scanning" state to keep in sync by hand.
@MainActor
public struct AthleteConnectionScanView: View {
    let transport: CloudKitTransport
    let session: AthleteRuntimeSession
    @Environment(\.dismiss) private var dismiss
    /// PR #84 follow-up: one coordinator instance for this screen's own
    /// lifetime — see `AthleteConnectionScanCoordinator`'s own
    /// RE-ENTRANCE GUARD doc comment for why its `isHandlingScan` guard
    /// is deliberately separate, per-screen-session state, not shared or
    /// global. `@State` (not a plain `let`) so the SAME instance, and
    /// its internal guard, survives this view's own re-renders rather
    /// than being reconstructed on every body evaluation.
    @State private var scanCoordinator = AthleteConnectionScanCoordinator()
    @State private var scanAttempt = 0
    @State private var isProcessingScan = false
    @State private var scanErrorMessage: String?
    @State private var isCameraPermissionDenied = false

    public init(transport: CloudKitTransport, session: AthleteRuntimeSession = .shared) {
        self.transport = transport
        self.session = session
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan connection code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("athleteConnectionScan.cancelButton")
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .connected(let actor) = session.state {
            successView(actor: actor)
        } else if isCameraPermissionDenied {
            permissionDeniedView
        } else {
            scanningView
        }
    }

    private var scanningView: some View {
        ZStack {
            QRCodeScannerView(
                onScan: { text in
                    Task { await handleScan(text) }
                },
                onPermissionDenied: {
                    isCameraPermissionDenied = true
                }
            )
            .id(scanAttempt)
            .ignoresSafeArea()

            VStack {
                Spacer()
                overlayMessage
                    .padding(.bottom, 48)
            }
        }
    }

    @ViewBuilder
    private var overlayMessage: some View {
        if let scanErrorMessage {
            VStack(spacing: 12) {
                Text(scanErrorMessage)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("athleteConnectionScan.errorMessage")
                Button("Scan again") {
                    scanErrorMessage = nil
                    scanAttempt += 1
                }
                .accessibilityIdentifier("athleteConnectionScan.retryButton")
            }
            .padding()
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
        } else if isProcessingScan {
            VStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("Confirming…")
                    .foregroundStyle(.white)
            }
        } else {
            Text("Open Vǫxtr on the parent's device and scan its connection code.")
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding()
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Camera access needed")
                .font(VoxtrTypography.cardTitle)
            Text("Vǫxtr needs camera access to scan a connection code. You can enable it in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(VoxtrColor.textSecondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .accessibilityIdentifier("athleteConnectionScan.openSettingsButton")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func successView(actor: CurrentSessionActor) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Connected")
                .font(VoxtrTypography.cardTitle)
            Button("Done") { dismiss() }
                .accessibilityIdentifier("athleteConnectionScan.doneButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("athleteConnectionScan.successState")
    }

    private func handleScan(_ text: String) async {
        guard !isProcessingScan else { return }
        isProcessingScan = true
        scanErrorMessage = nil
        let outcome = await scanCoordinator.handleScannedText(text, transport: transport, session: session)
        isProcessingScan = false
        switch outcome {
        case nil:
            if case .failed(let error) = session.state {
                scanErrorMessage = error.presentationSafeDescription
            }
            // Otherwise session.state is now .connected — successView renders.
        case .invalidCode:
            scanErrorMessage = "That code isn't a Vǫxtr connection code. Try scanning again."
        case .shareMetadataFetchFailed:
            scanErrorMessage = "Couldn't confirm this code with iCloud. Check your connection and try again."
        case .alreadyInFlight:
            // This screen's own isProcessingScan guard above already
            // prevents overlapping calls in the ordinary case — this
            // case is the coordinator's own defense-in-depth guard
            // catching an unexpected second call; the first, genuine
            // attempt is still in flight and will settle session.state
            // on its own, so nothing further is shown here.
            break
        }
    }
}
