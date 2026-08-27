import SwiftUI
import VoxtrAppShell

/// S1.4: content is now `RootView`, whose navigation is driven entirely
/// by `FamilyRestorationState` — no onboarding UI here in this file
/// itself, that's all in `RootView`/`CreateFamilyView`.
///
/// What DID change in Sprint 1 (S1.0): this now actually builds the
/// composition root and gets a real, persisted `ModelContainer` at
/// launch, via `CompositionRootLoaderView` — Sprint 0 never called
/// `CompositionRoot.build()` from either app target at all.
@main
struct ParentApp: App {
    /// Bridges into UIKit's app-level `supportedInterfaceOrientationsFor`
    /// query — see `VoxtrOrientationAppDelegate`'s own doc comment.
    /// This is the ONLY place that hook is wired in; `AthleteApp` never
    /// adds this adaptor, so its own orientation behavior is unchanged.
    @UIApplicationDelegateAdaptor(VoxtrOrientationAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            CompositionRootLoaderView { root in
                RootView(root: root)
            }
        }
    }
}
