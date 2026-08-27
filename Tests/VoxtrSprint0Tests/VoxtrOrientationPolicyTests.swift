import Testing
import UIKit
@testable import VoxtrAppShell

/// Statistics V1 UI (fullscreen Timeline follow-up): focused tests for
/// `VoxtrOrientationPolicy`'s two canonical masks. Deliberately does
/// NOT exercise `setAllowedOrientations(_:)` — that method's side
/// effect (`UIViewController.attemptRotationToDeviceOrientation()`) is
/// inherently UIApplication/UIWindow-driven and not meaningfully
/// verifiable in a headless unit test; that live behavior is covered
/// by Codemagic/TestFlight runtime validation instead. What IS durably
/// testable without any UIKit runtime is that the two masks the app
/// actually uses are exactly what the approved contract requires.
@Suite("VoxtrOrientationPolicy")
@MainActor
struct VoxtrOrientationPolicyTests {
    @Test("ParentApp's default mask is portrait only")
    func defaultMaskIsPortraitOnly() {
        #expect(VoxtrOrientationPolicy.portraitOnly == .portrait)
    }

    @Test("The fullscreen Timeline's mask is exactly portrait + both landscapes — never upside-down, never .all")
    func expandedMaskIsPortraitAndBothLandscapesOnly() {
        let mask = VoxtrOrientationPolicy.portraitAndLandscape
        #expect(mask.contains(.portrait))
        #expect(mask.contains(.landscapeLeft))
        #expect(mask.contains(.landscapeRight))
        #expect(!mask.contains(.portraitUpsideDown))
        #expect(mask == [.portrait, .landscapeLeft, .landscapeRight])
    }

    @Test("The two canonical masks are distinct")
    func defaultAndExpandedMasksDiffer() {
        #expect(VoxtrOrientationPolicy.portraitOnly != VoxtrOrientationPolicy.portraitAndLandscape)
    }
}
