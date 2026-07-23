import SwiftUI
import VoxtrAppShell

/// Deliberately minimal — this is the CI/Sprint-0 shell, not real product
/// UI. Real athlete-facing navigation/screens are Sprint 1+ work.
@main
struct AthleteApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationShellView()
        }
    }
}
