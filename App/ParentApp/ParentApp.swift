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
    var body: some Scene {
        WindowGroup {
            CompositionRootLoaderView { root in
                RootView(root: root)
            }
        }
    }
}
