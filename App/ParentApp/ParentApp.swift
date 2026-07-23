import SwiftUI
import VoxtrAppShell

/// Deliberately minimal — this is the CI/Sprint-0 shell, not real product
/// UI. Real parent-facing navigation/screens are Sprint 1+ work. Reuses
/// the same NavigationShellView as AthleteApp for now since no
/// parent-specific UI exists yet — both apps compose the same
/// ModuleRegistry.
@main
struct ParentApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationShellView()
        }
    }
}
