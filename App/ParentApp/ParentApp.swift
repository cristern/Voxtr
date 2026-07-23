import SwiftUI
import VoxtrAppShell

/// Content is still the Sprint-0 placeholder (`NavigationShellView`) —
/// story S1.4 (parent onboarding UI) replaces this with `RootView`.
/// S1.0's job is only the composition/persistence plumbing below, not
/// the UI that will eventually use it.
///
/// What DID change in Sprint 1 (S1.0): this now actually builds the
/// composition root and gets a real, persisted `ModelContainer` at
/// launch, via `CompositionRootLoaderView` — Sprint 0 never called
/// `CompositionRoot.build()` from either app target at all.
@main
struct ParentApp: App {
    var body: some Scene {
        WindowGroup {
            CompositionRootLoaderView { _ in
                NavigationShellView()
            }
        }
    }
}
