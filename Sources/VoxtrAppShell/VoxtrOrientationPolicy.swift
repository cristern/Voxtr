import UIKit

/// Statistics V1 UI (fullscreen Timeline follow-up): the ONE
/// authoritative owner of which interface orientations ParentApp
/// currently allows. `VoxtrOrientationAppDelegate` below answers
/// UIKit's standard `application(_:supportedInterfaceOrientationsFor:)`
/// question by forwarding this single shared value — nothing else in
/// the app decides that question. Every screen that needs a
/// temporarily wider mask than ParentApp's own portrait-only default
/// (currently only the fullscreen Development Timeline) requests it
/// through this one shared instance rather than introducing its own
/// orientation state, so there is never more than one owner to
/// reconcile, and normal ParentApp screens are unaffected by default.
///
/// Deliberately holds ONLY the orientation mask — never Statistics
/// state, persistence, or any domain model.
@MainActor
public final class VoxtrOrientationPolicy {
    public static let shared = VoxtrOrientationPolicy()

    /// ParentApp's default, everywhere-else behavior — matches
    /// `Info.plist`'s own iPhone `UISupportedInterfaceOrientations`
    /// baseline (portrait only).
    public static let portraitOnly: UIInterfaceOrientationMask = .portrait

    /// The fullscreen Development Timeline's temporarily-widened mask.
    /// Deliberately portrait + both landscapes only — never
    /// `.allButUpsideDown`/`.all`; upside-down is not part of the
    /// approved contract for this screen, or for any ParentApp screen.
    public static let portraitAndLandscape: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]

    public private(set) var allowedOrientations: UIInterfaceOrientationMask = portraitOnly

    private init() {}

    /// Widens or restores the allowed mask, then asks UIKit to
    /// immediately re-evaluate the CURRENT physical device orientation
    /// against it — a single, deterministic call tied to this one
    /// state change, never a repeated/timed poll. If the device is
    /// already held in an orientation the new mask permits, this
    /// rotates the app to match it; if the device is held in an
    /// orientation the new mask no longer permits (e.g. restoring
    /// portrait-only while the phone is still held landscape), this
    /// rotates the app back — so releasing the wider mask never leaves
    /// the app stuck in a now-disallowed orientation.
    public func setAllowedOrientations(_ mask: UIInterfaceOrientationMask) {
        guard allowedOrientations != mask else { return }
        allowedOrientations = mask
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

/// The one place ParentApp bridges into UIKit's app-level orientation
/// query. Wired in via `@UIApplicationDelegateAdaptor` from
/// `ParentApp.swift` — `AthleteApp` never references this type, so its
/// own (unrelated, portrait-only) orientation behavior is unaffected by
/// its existence in this shared module.
///
/// `application(_:supportedInterfaceOrientationsFor:)` is declared
/// `nonisolated` and reads `VoxtrOrientationPolicy.shared` via
/// `MainActor.assumeIsolated` rather than requiring the whole method to
/// be statically `@MainActor` — UIKit always invokes this delegate
/// method on the main thread, so the assumption is safe, and a
/// `nonisolated` witness is guaranteed to satisfy this protocol
/// requirement regardless of how the current SDK itself annotates
/// `UIApplicationDelegate`'s isolation.
public final class VoxtrOrientationAppDelegate: NSObject, UIApplicationDelegate {
    public override init() {
        super.init()
    }

    public nonisolated func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated {
            VoxtrOrientationPolicy.shared.allowedOrientations
        }
    }
}
