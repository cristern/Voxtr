import Foundation

/// Internal Alpha diagnostic surface follow-up: gates whether the
/// "Connect Athlete App" screen shows its secondary CloudKit diagnostic
/// line (see `AthleteFamilyManagementViewModel.connectAthleteAppDiagnostic*`).
///
/// WHY A RECEIPT CHECK, NOT A FEATURE FLAG: `FeatureFlagProviding` already
/// exists in this codebase, but it requires someone to explicitly flip a
/// flag — there is no debug/settings surface to do that yet, and Internal
/// Alpha's own Product Owner has no Mac to reach one via Xcode either.
/// Apple's own documented, non-brittle way to tell a TestFlight install
/// apart from a real App Store release is the app-store receipt's own
/// filename: TestFlight installs carry a receipt file literally named
/// `sandboxReceipt`; App Store releases do not. This requires no build
/// number/version to hardcode (avoiding exactly the brittleness this
/// task's own instructions warn against) and needs no manual toggle — it
/// is simply true for every build reaching this Alpha's testers today,
/// and automatically becomes false the moment Vǫxtr ever ships through
/// the real App Store, with no code change required then either.
public enum AthleteInviteDiagnosticVisibility {

    /// PURE — takes the receipt URL as a parameter rather than reading
    /// `Bundle.main` directly, so this is directly unit-testable with a
    /// plain `URL` value, no bundle/Info.plist fixture required.
    public nonisolated static func isVisible(receiptURL: URL?) -> Bool {
        receiptURL?.lastPathComponent == "sandboxReceipt"
    }

    /// Production entry point — reads the running app's own receipt.
    public static var isVisibleForCurrentBuild: Bool {
        isVisible(receiptURL: Bundle.main.appStoreReceiptURL)
    }
}
