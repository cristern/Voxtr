import AVFoundation
import SwiftUI
import UIKit

/// Athlete Connection QR-first V1: CAMERA/UI ONLY — deliberately contains
/// no QR payload parsing/validation and no CloudKit/domain logic
/// whatsoever (see `AthleteConnectionQRCode`/`AthleteConnectionScanCoordinator`
/// for those, kept entirely separate per this task's own explicit
/// "separate camera/UI from parsing from acceptance" requirement). Emits
/// every decoded QR string via `onScan`, unfiltered — the caller decides
/// what a "supported" payload looks like; this view stays dumb and
/// reusable.
///
/// Plain `AVCaptureSession`/`AVCaptureMetadataOutput` — deliberately the
/// smallest, most broadly Apple-supported native API for this project's
/// iOS 17 deployment target, chosen over VisionKit's
/// `DataScannerViewController`: that higher-level API additionally
/// requires an A12+ Neural Engine and is unconditionally unavailable in
/// Simulator (`DataScannerViewController.isSupported` is always `false`
/// there), which would make this screen's own code path impossible to
/// exercise even at a build/compile level in this repo's existing
/// simulator-only CI workflows. AVFoundation has neither restriction and
/// is the traditional, fully documented native mechanism for exactly
/// this "scan one QR code, control presentation/dismissal myself" shape.
public struct QRCodeScannerView: UIViewControllerRepresentable {
    public let onScan: (String) -> Void
    public let onPermissionDenied: () -> Void

    public init(onScan: @escaping (String) -> Void, onPermissionDenied: @escaping () -> Void) {
        self.onScan = onScan
        self.onPermissionDenied = onPermissionDenied
    }

    public func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.onScan = onScan
        controller.onPermissionDenied = onPermissionDenied
        return controller
    }

    /// Deliberately empty: `onScan`/`onPermissionDenied` are read once at
    /// construction — a fresh scan attempt is a fresh `QRCodeScannerView`
    /// identity (see `AthleteConnectionScanView`'s own `.id(scanAttempt)`
    /// use), never an in-place update of a live scanning session.
    public func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

/// See `QRCodeScannerView`'s own doc comment for the full rationale.
///
/// EXPLICIT PERMISSION LIFECYCLE: camera access is requested only from
/// `viewDidAppear`, the first time this controller's view is genuinely
/// visible — never eagerly at app launch or at `CompositionRoot.build()`
/// time, matching this task's own explicit requirement.
///
/// DETERMINISTIC START/STOP: capture starts in `viewDidAppear` and stops
/// in `viewWillDisappear` — mirrors `CloudSharingAnchorViewController`'s
/// own, already-proven reasoning for why `updateUIViewController` cannot
/// be trusted for this kind of side effect (no guarantee the view is
/// actually in a window yet) — so backgrounding or dismissing this screen
/// always releases the camera, and re-presenting it always restarts a
/// clean session.
///
/// PR #84 follow-up (Codemagic Xcode 26.6 Swift 6 compile fix): this
/// class is implicitly `@MainActor`-isolated (inherited from
/// `UIViewController`'s own global-actor annotation in the modern SDK
/// overlay), so every method here — including `metadataOutput(_:
/// didOutput:from:)` below — is MainActor-isolated by default.
/// `AVCaptureMetadataOutputObjectsDelegate`'s own protocol requirement,
/// however, is declared `nonisolated` (ordinary legacy-Objective-C
/// delegate shape) — Codemagic's authoritative compiler flagged exactly
/// this mismatch: "conformance ... crosses into main actor-isolated code
/// and can cause data races." The conformance below is written as `,
/// @MainActor AVCaptureMetadataOutputObjectsDelegate` — an ISOLATED
/// CONFORMANCE (not `@preconcurrency`, which would only silence the
/// diagnostic without actually proving safety) — telling the compiler
/// that THIS SPECIFIC conformance is only ever dispatched into on
/// MainActor, which is exactly true here: `configureCaptureSession()`
/// below explicitly registers this delegate via
/// `output.setMetadataObjectsDelegate(self, queue: .main)`, so
/// `metadataOutput(_:didOutput:from:)` is guaranteed to be invoked on
/// the main queue/MainActor already, by this file's own existing
/// design — the isolated-conformance annotation makes that existing
/// guarantee explicit and statically checked, rather than papering over
/// it. `metadataOutput(_:didOutput:from:)` itself is left exactly as
/// written (implicitly MainActor-isolated, never `nonisolated`) — the
/// fix is entirely in the conformance declaration, not the method body.
public final class QRCodeScannerViewController: UIViewController, @MainActor AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasEmittedScan = false
    private var hasRequestedAccess = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    /// Deliberately NOT `viewDidLoad`: `viewDidLoad` can fire
    /// synchronously from within `makeUIViewController` itself, i.e.
    /// still inside the SwiftUI render pass that is constructing this
    /// controller — mutating SwiftUI `@State` (via `onPermissionDenied`,
    /// for an already-denied permission) from there risks SwiftUI's own
    /// "modifying state during view update" hazard. `viewDidAppear` is
    /// guaranteed to run only once this controller's view is genuinely
    /// in the window/visible hierarchy, safely outside that render pass
    /// — the same reasoning `CloudSharingAnchorViewController` already
    /// established for its own main side effect.
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasRequestedAccess else {
            startRunningIfConfigured()
            return
        }
        hasRequestedAccess = true
        requestAccessIfNeededAndConfigure()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func requestAccessIfNeededAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCaptureSession()
            startRunningIfConfigured()
        case .notDetermined:
            // `AVCaptureDevice.requestAccess`'s completion handler is not
            // MainActor-isolated (it can resolve on an arbitrary system
            // queue) — `Task { @MainActor in ... }` is the correct hop
            // back to this MainActor-isolated controller's own state,
            // mirroring `AthleteCloudKitShareAppDelegate`'s own established
            // pattern for exactly this shape (a non-isolated system
            // completion handler that must resume MainActor-isolated
            // work), rather than `DispatchQueue.main.async`, which Swift 6
            // strict concurrency does not statically recognize as an
            // actor hop.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    guard granted else {
                        self.onPermissionDenied?()
                        return
                    }
                    self.configureCaptureSession()
                    self.startRunningIfConfigured()
                }
            }
        case .denied, .restricted:
            onPermissionDenied?()
        @unknown default:
            onPermissionDenied?()
        }
    }

    private func configureCaptureSession() {
        guard session.inputs.isEmpty else { return }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onPermissionDenied?()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onPermissionDenied?()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    /// `AVCaptureSession.startRunning()` is a blocking call — Apple's own
    /// documented guidance is to dispatch it to a background queue rather
    /// than block the caller (here, MainActor) while the camera spins
    /// up. `AVCaptureSession` is a plain AVFoundation reference type,
    /// used here exactly as Apple's own guidance describes; this is a
    /// compile-oriented-audit risk this sandbox has no Swift/Xcode
    /// toolchain to verify empirically (no Swift 6 Sendability diagnostic
    /// can be run here) — Codemagic's real compiler remains authoritative
    /// for whether this specific capture needs an additional annotation.
    private func startRunningIfConfigured() {
        guard !session.inputs.isEmpty, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasEmittedScan,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        hasEmittedScan = true
        onScan?(value)
    }
}
