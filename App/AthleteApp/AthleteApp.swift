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
@main
struct AthleteApp: App {
    var body: some Scene {
        WindowGroup {
            CompositionRootLoaderView { _ in
                NavigationShellView()
            }
        }
    }
}
