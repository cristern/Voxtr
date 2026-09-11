import SwiftUI
import VoxtrAppShell
import VoxtrAthleteScanner

/// This now builds the real composition root and gets a real, persisted
/// `ModelContainer` at launch, via `CompositionRootLoaderView`, and
/// presents `AthleteRootView` — the Athlete App Shell / UX Foundation
/// root (see that type's own doc comment): a calm connection gate while
/// not connected, or the athlete-facing tab shell once connected. The
/// old Sprint-0 `NavigationShellView()` placeholder is gone (deleted
/// this round — no remaining callers).
///
/// The `@UIApplicationDelegateAdaptor` below is the ONLY place
/// `AthleteCloudKitShareAppDelegate` is wired in — `ParentApp` never
/// adds it, since Parent-side (owner) CloudKit sharing has no
/// equivalent participant-acceptance callback to receive. Mirrors
/// `ParentApp.swift`'s own `VoxtrOrientationAppDelegate` adaptor
/// pattern exactly; the two adaptors are unrelated to each other and
/// each app target wires only the one it needs.
///
/// ITMS-90683 fix: `import VoxtrAthleteScanner` above is likewise the
/// ONLY place this product is linked — `ParentApp.swift` never adds it.
/// `AthleteRootView`'s own `makeScannerView` parameter is supplied here
/// with the real, `AVCaptureSession`-backed `QRCodeScannerView`, so that
/// concrete camera-API code is compiled into AthleteApp.app but never
/// into ParentApp.app. See `Package.swift`'s own doc comment on the
/// `VoxtrAthleteScanner` target for the full rationale.
@main
struct AthleteApp: App {
    @UIApplicationDelegateAdaptor(AthleteCloudKitShareAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            CompositionRootLoaderView { root in
                AthleteRootView(root: root, makeScannerView: Self.makeScannerView)
            }
        }
    }

    private static func makeScannerView(
        onScan: @escaping (String) -> Void,
        onPermissionDenied: @escaping () -> Void
    ) -> AnyView {
        AnyView(QRCodeScannerView(onScan: onScan, onPermissionDenied: onPermissionDenied))
    }
}
