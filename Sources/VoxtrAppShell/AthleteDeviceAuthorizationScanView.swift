import SwiftUI
import UIKit
import VoxtrCore

/// Athlete Connection V1 (backend device authorization): the Athlete
/// app's "Connect this device" screen — the smallest calm flow tying
/// together the injected camera scanner view (same
/// `AthleteConnectionScannerBuilder` seam `AthleteConnectionScanView`
/// already uses — no second AVFoundation coupling introduced) and
/// `AthleteDeviceAuthorizationPairingCoordinator`'s own state machine.
///
/// ADDITIVE, not a replacement: this is a SEPARATE screen from the
/// existing, unmodified `AthleteConnectionScanView` (CloudKit CKShare
/// pairing) — see `AthleteDeviceAuthorizationQRPayload`'s own doc
/// comment for why. Presents no fake percentages/countdowns while
/// waiting for Parent approval — matches Calm by Default.
@MainActor
public struct AthleteDeviceAuthorizationScanView: View {
    let makeScannerView: AthleteConnectionScannerBuilder
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: AthleteDeviceAuthorizationPairingCoordinator
    @State private var scanAttempt = 0
    @State private var isCameraPermissionDenied = false

    public init(
        service: AthleteDeviceAuthorizationService,
        makeScannerView: @escaping AthleteConnectionScannerBuilder
    ) {
        self.makeScannerView = makeScannerView
        self._coordinator = State(initialValue: AthleteDeviceAuthorizationPairingCoordinator(service: service))
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Connect this device")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("athleteDeviceAuthorizationScan.cancelButton")
                    }
                }
        }
        // Review round 2: resumes a receipt from a previous interrupted
        // session exactly once, before any scan — never on every body
        // re-evaluation (SwiftUI only runs `.task` again if its own
        // identity changes, and this view's identity is stable for the
        // sheet's lifetime).
        .task {
            coordinator.resumePendingAttemptIfAny()
        }
        // Cancels any in-flight network/poll work the instant this
        // screen leaves the hierarchy — fires for an explicit Cancel tap
        // AND an interactive swipe dismissal alike (`.onDisappear` runs
        // either way), so no orphaned poll loop keeps running after the
        // Athlete has left this screen.
        .onDisappear {
            coordinator.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .idle:
            scanningView
        case .resuming(let displayCode):
            awaitingApprovalView(displayCode: displayCode)
        case .reconfirmingPreviousGrant:
            waitingView(message: "Confirming your previous connection with Vǫxtr…")
        case .submitting, .claiming:
            waitingView(message: "Confirming…")
        case .awaitingApproval(_, let displayCode):
            awaitingApprovalView(displayCode: displayCode)
        case .authorized:
            successView
        case .interrupted(let displayCode):
            interruptedView(displayCode: displayCode)
        case .failed(let message):
            failedView(message: message)
        }
    }

    @ViewBuilder
    private var scanningView: some View {
        if isCameraPermissionDenied {
            permissionDeniedView
        } else {
            ZStack {
                makeScannerView(
                    { text in coordinator.beginPairing(scannedText: text) },
                    { isCameraPermissionDenied = true }
                )
                .id(scanAttempt)
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("Open Vǫxtr on the parent's device and scan its connection code.")
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 48)
                }
            }
        }
    }

    private func waitingView(message: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(message)
                .foregroundStyle(VoxtrColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `displayCode` is the SAME comparison code the Parent's own screen
    /// shows for this exact request — the Athlete only ever reads it
    /// here, never retypes or confirms it; the Parent's visual compare +
    /// explicit approval is what matters (Normative Security Contract
    /// §3: "a comparison code is ONLY a human visual check, never an
    /// auth token"). Review round 4: also used for a RESUMED pending
    /// receipt (`.resuming`), whose own `displayCode` may be `nil` for a
    /// receipt saved before this field existed — handled honestly (a
    /// plain "waiting" message) rather than inventing a code to show.
    private func awaitingApprovalView(displayCode: String?) -> some View {
        VStack(spacing: 16) {
            if let displayCode {
                Text("Compare this code")
                    .font(VoxtrTypography.cardTitle)
                Text(displayCode)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .accessibilityIdentifier("athleteDeviceAuthorizationScan.displayCode")
                Text("Ask the parent to check this matches what they see, then approve on their device.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .padding(.horizontal, 32)
            } else {
                Text("Waiting for the parent to approve on their device.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .padding(.horizontal, 32)
            }
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("athleteDeviceAuthorizationScan.awaitingApproval")
    }

    /// Deliberately NOT "Connected" — this slice's own boundary ends at
    /// confirmed backend device authorization. It never hydrates athlete
    /// data, accepts a CKShare, activates business membership, or shows
    /// the normal athlete dashboard as a consequence of this result, so
    /// the copy says exactly that rather than implying a fuller
    /// connection than what actually happened. When the backend
    /// confirmed this but the local receipt recording it couldn't be
    /// saved, `coordinator.unpersistedAuthorizationWarning` says so
    /// honestly too, rather than silently hiding that gap.
    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Device authorized")
                .font(VoxtrTypography.cardTitle)
            Text("This device is now authorized with Vǫxtr. Setting up the athlete's data on this device isn't available yet.")
                .multilineTextAlignment(.center)
                .foregroundStyle(VoxtrColor.textSecondary)
                .padding(.horizontal, 32)
            if let warning = coordinator.unpersistedAuthorizationWarning {
                Text(warning)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("athleteDeviceAuthorizationScan.unpersistedWarning")
            }
            Button("Done") { dismiss() }
                .accessibilityIdentifier("athleteDeviceAuthorizationScan.doneButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("athleteDeviceAuthorizationScan.successState")
    }

    /// A resumable interruption: the receipt this attempt was bound to
    /// is still intact, so "Continue connection" requests a fresh
    /// challenge for the SAME request/key rather than starting over —
    /// never automatically, always this explicit tap. "Scan again"
    /// remains available as a SEPARATE, explicit choice for a genuinely
    /// new attempt, which discards that receipt (see `reset()`'s own
    /// doc comment).
    private func interruptedView(displayCode: String?) -> some View {
        VStack(spacing: 16) {
            Text("Connection interrupted")
                .font(VoxtrTypography.cardTitle)
            Text("We couldn't finish confirming this connection. If the parent already approved, you can continue — nothing needs to be scanned again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(VoxtrColor.textSecondary)
                .padding(.horizontal, 32)
            if let displayCode {
                Text(displayCode)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .accessibilityIdentifier("athleteDeviceAuthorizationScan.interruptedDisplayCode")
            }
            Button("Continue connection") {
                coordinator.continuePendingAttempt()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("athleteDeviceAuthorizationScan.continueButton")
            Button("Scan again") {
                coordinator.reset()
                scanAttempt += 1
            }
            .accessibilityIdentifier("athleteDeviceAuthorizationScan.retryButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("athleteDeviceAuthorizationScan.interruptedState")
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(VoxtrColor.textSecondary)
                .padding(.horizontal, 32)
            Button("Scan again") {
                coordinator.reset()
                scanAttempt += 1
            }
            .accessibilityIdentifier("athleteDeviceAuthorizationScan.retryButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .accessibilityIdentifier("athleteDeviceAuthorizationScan.openSettingsButton")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
