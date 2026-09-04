import SwiftUI
import VoxtrAppShell

/// Deliberately minimal content — this is the CI/Sprint-0 placeholder
/// UI, not real product UI. Real athlete-facing navigation/screens
/// remain out of scope for Sprint 1 (S1.0-S1.5) per the approved plan;
/// `AthleteApp` stays a placeholder that must keep building, nothing
/// more, this sprint.
///
/// What DID change in Sprint 1 (S1.0): this now actually builds the
/// composition root and gets a real, persisted `ModelContainer` at
/// launch, via `CompositionRootLoaderView` — Sprint 0 never called
/// `CompositionRoot.build()` from either app target at all.
///
/// Athlete Connection Foundation B2.5: `AthleteRootView` replaces the
/// previous direct `NavigationShellView()` call — it still shows that
/// same Sprint 0 placeholder content, plus the minimal Internal Alpha
/// connection status needed to validate the real CKShare acceptance →
/// B2.2 → B2.3 → B2.4 chain on a signed TestFlight build. The
/// `@UIApplicationDelegateAdaptor` below is the ONLY place
/// `AthleteCloudKitShareAppDelegate` is wired in — `ParentApp` never
/// adds it, since Parent-side (owner) CloudKit sharing has no
/// equivalent participant-acceptance callback to receive. Mirrors
/// `ParentApp.swift`'s own `VoxtrOrientationAppDelegate` adaptor
/// pattern exactly; the two adaptors are unrelated to each other and
/// each app target wires only the one it needs.
@main
struct AthleteApp: App {
    @UIApplicationDelegateAdaptor(AthleteCloudKitShareAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            CompositionRootLoaderView { root in
                AthleteRootView(root: root)
            }
        }
    }
}
