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
    /// Athlete hydration/activation integration slice (§5.2): once
    /// `coordinator` reaches `.authorized(grantId:)`, this screen hands
    /// off to the SAME, `CompositionRoot`-resolved connection
    /// coordinator the rest of AthleteApp uses — never a second,
    /// screen-local orchestrator — so hydration/activation state
    /// started here is visible everywhere else too.
    let connectionCoordinator: AthleteBackendConnectionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: AthleteDeviceAuthorizationPairingCoordinator
    @State private var scanAttempt = 0
    @State private var isCameraPermissionDenied = false

    public init(
        service: AthleteDeviceAuthorizationService,
        connectionCoordinator: AthleteBackendConnectionCoordinator,
        makeScannerView: @escaping AthleteConnectionScannerBuilder
    ) {
        self.makeScannerView = makeScannerView
        self.connectionCoordinator = connectionCoordinator
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
        //
        // ChatGPT review on PR #120, R6: cancelling `coordinator` (the
        // claim-submit pairing state machine) alone is not enough once
        // pairing reaches `.authorized(grantId:)` — `backendConnectionView`
        // below hands off to the SEPARATE, shared `connectionCoordinator`,
        // whose own `activate(deviceGrantId:)` runs on an OWNED `Task` it
        // stores on itself, never tied to this view's `.task(id:)`
        // wrapper's own lifetime (that wrapper's body already returned,
        // synchronously, the moment `activate(_:)` was called). Without
        // this, dismissing the sheet mid-hydration would leave that
        // attempt running, free to hydrate/accept/bind/activate, save a
        // checkpoint, and publish `.connected` after the Athlete already
        // left this flow. `connectionCoordinator.cancel()` mirrors
        // `coordinator.cancel()`'s own "a merely-dismissed screen is not
        // the Athlete discarding anything" semantics exactly — it never
        // touches `state` or persisted storage itself; it only stops a
        // now-unwanted attempt from mutating either going forward.
        .onDisappear {
            coordinator.cancel()
            connectionCoordinator.cancel()
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
        case .authorized(let grantId):
            backendConnectionView(deviceGrantId: grantId)
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

    /// Athlete hydration/activation integration slice (§5.2): backend
    /// device authorization alone (`.authorized(grantId:)`) is never
    /// shown as "Connected" on its own — this view hands off to
    /// `connectionCoordinator`, the SAME orchestrator the rest of
    /// AthleteApp reads, and renders whatever honest state it reaches
    /// (hydrating/activating, freshly-connected, cached/unverified, a
    /// specific denial, or a distinct retryable reason) rather than a
    /// fixed "Device authorized" dead end. `.task(id:)` starts
    /// activation exactly once per distinct `deviceGrantId` — never
    /// re-triggered by an unrelated body re-evaluation.
    private func backendConnectionView(deviceGrantId: UUID) -> some View {
        content(for: connectionCoordinator.state)
            .task(id: deviceGrantId) {
                connectionCoordinator.activate(deviceGrantId: deviceGrantId)
            }
    }

    @ViewBuilder
    private func content(for state: AthleteBackendConnectionCoordinator.State) -> some View {
        switch state {
        case .idle, .activating:
            waitingView(message: "Setting up this athlete's data…")
        case .connected(_, let verified):
            connectedView(verified: verified, checkpointUnsaved: false)
        case .connectedButCheckpointUnsaved(_, let verified):
            connectedView(verified: verified, checkpointUnsaved: true)
        case .grantRevoked:
            backendOutcomeView(
                title: "Connection revoked",
                message: "The parent has revoked this device's connection. Ask them to approve a new connection code."
            )
        case .connectionUnavailable:
            backendOutcomeView(
                title: "Connection unavailable",
                message: "This connection isn't available right now. Ask the parent to approve a new connection code."
            )
        case .waitingForParentApproval:
            waitingView(message: "Waiting for the parent to finish approving this connection.")
        case .hydrationWindowExpired:
            backendOutcomeView(
                title: "Connection window expired",
                message: "This connection attempt took too long. Ask the parent to approve a new connection code."
            )
        case .installationKeyUnavailable:
            backendOutcomeView(
                title: "Reinstall detected",
                message: "This device's secure key no longer matches a connection in progress. Please scan a new code."
            )
        case .ackNotConfirmed, .temporarilyUnavailable:
            backendOutcomeView(
                title: "Couldn't finish setting up",
                message: "We couldn't confirm this with Vǫxtr. Check your connection and try again.",
                showsRetry: true, deviceGrantId: currentDeviceGrantId
            )
        case .recoveryRequired:
            backendOutcomeView(
                title: "Couldn't finish setting up",
                message: "This device needs to reconnect. Please scan a new code.",
                showsRetry: false
            )
        }
    }

    /// `coordinator.state` already carries the exact `grantId` this
    /// screen is driving — read fresh rather than duplicated as a
    /// separate stored property.
    private var currentDeviceGrantId: UUID? {
        if case .authorized(let grantId) = coordinator.state { return grantId }
        return nil
    }

    private func connectedView(verified: Bool, checkpointUnsaved: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Connected")
                .font(VoxtrTypography.cardTitle)
            if !verified {
                Text("Connection cannot be verified right now. Showing the last known information.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("athleteDeviceAuthorizationScan.unverifiedBanner")
            }
            if checkpointUnsaved {
                // Same wording as `AthleteShellRoute.backendStatusNotice(for:)`'s
                // own `.connectedButCheckpointUnsaved` case, so this
                // screen and the persistent root-level banner never
                // diverge (ChatGPT review on PR #120, R1/R4).
                Text("Vǫxtr couldn't save what's needed to reconnect automatically. If the app restarts before this is resolved, you may need to scan a new connection code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("athleteDeviceAuthorizationScan.checkpointUnsavedWarning")
            }
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

    private func backendOutcomeView(title: String, message: String, showsRetry: Bool = false, deviceGrantId: UUID? = nil) -> some View {
        VStack(spacing: 16) {
            Text(title)
                .font(VoxtrTypography.cardTitle)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(VoxtrColor.textSecondary)
                .padding(.horizontal, 32)
            if showsRetry, let deviceGrantId {
                Button("Try again") {
                    connectionCoordinator.activate(deviceGrantId: deviceGrantId)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("athleteDeviceAuthorizationScan.backendRetryButton")
            }
            Button("Done") { dismiss() }
                .accessibilityIdentifier("athleteDeviceAuthorizationScan.doneButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("athleteDeviceAuthorizationScan.backendOutcomeState")
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
