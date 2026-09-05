import SwiftUI
import UIKit
import CloudKit
import VoxtrCore

/// Athlete Connection Foundation B2.6 (TestFlight runtime crash follow-up,
/// PR #69 lead review hardening): presents Apple's own native CloudKit
/// sharing UI (`UICloudSharingController`) for an ALREADY-created `CKShare`
/// (via `AthleteConnectionOwnerHandoffService.prepareInvitation(...)`) —
/// this codebase adds no custom email/SMS invite delivery of its own; the
/// Parent sends the invite through whatever standard iOS share-sheet
/// mechanism they choose from this controller (Messages, Mail, AirDrop,
/// copy link, etc.), exactly as Apple's own API is designed to be used.
///
/// LEADING ROOT-CAUSE HYPOTHESIS for the observed ParentApp TestFlight
/// build 502 crash (`EXC_BREAKPOINT`/`SIGTRAP` inside CloudKit.framework, on
/// tapping "Connect Athlete App" — the crash stack was not fully symbolized
/// into Vǫxtr source, so this is runtime evidence strongly indicating, not
/// a proven-by-symbolication, root cause): Apple's own `UICloudSharingController`
/// documentation requires this controller to be PRESENTED — via a genuine
/// `present(_:animated:completion:)` call, with its own
/// `popoverPresentationController` configured first ("You must set the
/// popoverPresentationController before presenting"). The version of this
/// file PR #69 replaced made `UICloudSharingController` itself this type's
/// `UIViewControllerType`, returned directly from `makeUIViewController`,
/// relying on the caller wrapping it in SwiftUI's `.sheet(isPresented:)`.
/// SwiftUI does not call `present(_:)` on a `UIViewControllerRepresentable`'s
/// own returned controller — it EMBEDS it as a CHILD of SwiftUI's own
/// internally-managed hosting controller (`addChild`/view embedding), never
/// a genuine UIKit presentation. This fix targets that observed CloudKit
/// presentation failure; it is described as verified only once a new
/// TestFlight build reproduces the same "Connect Athlete App" action
/// successfully on a real device.
///
/// THE FIX, HARDENED (PR #69 lead review): this representable's own
/// `UIViewControllerType` is `CloudSharingAnchorViewController` (below) — a
/// plain, invisible ANCHOR, never `UICloudSharingController` itself. The
/// caller embeds this anchor via `.background(...)` on an always-on-screen
/// view (never `.sheet`). Presentation is triggered from the anchor's own
/// `viewDidAppear` — NOT from `updateUIViewController` — because
/// `updateUIViewController` carries no guarantee the anchor is actually
/// attached to a window/visible hierarchy yet; presenting from there could
/// silently fail or no-op on some SwiftUI update timing, replacing a crash
/// with an equally bad "nothing happens" bug. `viewDidAppear` is UIKit's own
/// documented guarantee that this exact concern is satisfied: it fires only
/// once this controller's view has actually been added to a window and is
/// part of the currently-displayed hierarchy, which is precisely what
/// `present(_:animated:completion:)` requires to succeed. See
/// `CloudSharingAnchorViewController`'s own doc comment for the rest.
///
/// CKSharingSupported: Apple's own documentation ties this Info.plist key
/// exclusively to "launch your app when the user taps or clicks a share's
/// URL" — the ACCEPTING side (AthleteApp, which already declares it — see
/// `CloudKitCapabilityConfigurationTests.athleteAppDeclaresCKSharingSupported`
/// in Tests/VoxtrSprint0Tests/CloudKitTransportTests.swift). ParentApp only
/// ever creates/presents a share in this architecture; today's Info.plist
/// correctly omits this key for that reason. Today's configuration is not
/// asserted here as a permanent product invariant — if a later Vǫxtr
/// feature genuinely needs ParentApp to accept share links too, that would
/// be a deliberate, separate product decision, not something this crash fix
/// should lock in either direction.
///
/// CONSTRUCTION: `UICloudSharingController(share:container:)` — the overload
/// for a share that ALREADY exists (B2.1's `ensureSharingRoot`/B2.6's
/// `createInvitationShare` already produced the real `CKShare` by the time
/// this view appears), as opposed to the closure-based overload that CREATES
/// a share, which this slice does not use since creation is already this
/// codebase's own idempotent job. `container`: constructed in the anchor,
/// from the handoff's own `containerIdentifier` — this is the one place in
/// this slice a real `CKContainer` is realized directly rather than through
/// `CloudKitTransport`'s own lazy-realization wrapper, because presentation
/// legitimately needs the concrete UIKit type and this only ever runs from
/// an explicit Parent action (never at `CompositionRoot.build()` time),
/// matching this codebase's own "no CloudKit I/O at launch" invariant.
///
/// DOES NOT decide `share.publicPermission` here — B2.1/B2.6 already set
/// that once, at share creation; this presenter must not casually change it.
public struct CloudSharingPresenter: UIViewControllerRepresentable {
    public let handoff: AthleteConnectionInvitationHandoff
    public let athleteDisplayName: String
    public let onDismiss: () -> Void

    public init(handoff: AthleteConnectionInvitationHandoff, athleteDisplayName: String, onDismiss: @escaping () -> Void) {
        self.handoff = handoff
        self.athleteDisplayName = athleteDisplayName
        self.onDismiss = onDismiss
    }

    /// The ANCHOR only — deliberately never `UICloudSharingController`
    /// itself. See this type's own doc comment for why.
    public func makeUIViewController(context: Context) -> CloudSharingAnchorViewController {
        let anchor = CloudSharingAnchorViewController()
        anchor.handoff = handoff
        anchor.delegate = context.coordinator
        return anchor
    }

    /// Only ever refreshes the anchor's own stored `handoff` — deliberately
    /// NEVER calls `.present(` here. SwiftUI does not guarantee the anchor
    /// is actually attached to a window/visible hierarchy at the time this
    /// is invoked, so presenting from here would reintroduce a lifecycle
    /// race (this type's own doc comment explains why). Presentation is
    /// driven exclusively by `CloudSharingAnchorViewController.viewDidAppear`.
    public func updateUIViewController(_ uiViewController: CloudSharingAnchorViewController, context: Context) {
        uiViewController.handoff = handoff
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(athleteDisplayName: athleteDisplayName, onDismiss: onDismiss)
    }

    /// `NSObject`: `UICloudSharingControllerDelegate` and
    /// `UIAdaptivePresentationControllerDelegate` are Objective-C
    /// protocols, matching every other UIKit delegate bridge in this
    /// codebase's own established pattern.
    public final class Coordinator: NSObject, UICloudSharingControllerDelegate, UIAdaptivePresentationControllerDelegate {
        private let athleteDisplayName: String
        private let onDismiss: () -> Void
        private let log = VoxtrLog.logger(.appShell)
        /// An explicit dismiss (save/stop, below) and the
        /// `presentationControllerDidDismiss` notification that same
        /// dismissal subsequently triggers can BOTH fire for one real user
        /// action — guarded so `onDismiss()` (which clears
        /// `pendingInvitationHandoff`) never runs twice for it.
        private var hasDismissed = false

        init(athleteDisplayName: String, onDismiss: @escaping () -> Void) {
            self.athleteDisplayName = athleteDisplayName
            self.onDismiss = onDismiss
        }

        public func itemTitle(for csc: UICloudSharingController) -> String? {
            "Connect \(athleteDisplayName) to Vǫxtr"
        }

        public func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            log.error("UICloudSharingController failed to save share: \(error.localizedDescription, privacy: .public)")
        }

        public func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            csc.dismiss(animated: true)
            dismissOnce()
        }

        public func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            csc.dismiss(animated: true)
            dismissOnce()
        }

        /// Covers interactive (swipe-to-dismiss) dismissal, which neither
        /// `cloudSharingControllerDidSaveShare` nor
        /// `cloudSharingControllerDidStopSharing` fires for. Also fires
        /// after either of those two explicitly calls `dismiss(animated:)`
        /// — `dismissOnce()` absorbs that overlap.
        public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            dismissOnce()
        }

        private func dismissOnce() {
            guard !hasDismissed else { return }
            hasDismissed = true
            onDismiss()
        }
    }
}

/// The dedicated anchor `UIViewController` `CloudSharingPresenter` embeds —
/// see that type's own doc comment for the full rationale. `public`: its
/// visibility must be at least that of `CloudSharingPresenter
/// .makeUIViewController(context:)`, a public protocol requirement.
///
/// WHY `viewDidAppear` AND NOT `updateUIViewController`: `viewDidAppear` is
/// UIKit's own documented guarantee that this controller's view has
/// actually been added to a window and is part of the currently-displayed
/// hierarchy — exactly what `present(_:animated:completion:)` requires to
/// succeed. `updateUIViewController` carries no such guarantee: SwiftUI can
/// invoke it before the underlying `UIView` is installed in a window at
/// all. Presenting from there could silently fail or be ignored by UIKit,
/// which would replace PR #69's original crash with an equally bad
/// "Parent taps Connect Athlete App, nothing visibly happens" bug — no
/// `DispatchQueue.main.async` delay, sleep, or retry loop could honestly
/// paper over that; waiting for the real, documented lifecycle event is the
/// correct fix.
///
/// `.clear`/non-interactive: this anchor sits behind real, visible SwiftUI
/// content via `.background(...)` — it must never paint over or intercept
/// touches meant for that content.
public final class CloudSharingAnchorViewController: UIViewController {
    var handoff: AthleteConnectionInvitationHandoff?
    weak var delegate: CloudSharingPresenter.Coordinator?
    private var hasPresented = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentCloudSharingControllerIfNeeded()
    }

    /// Presents the real `UICloudSharingController` via a genuine
    /// `present(_:animated:completion:)` call, exactly once — `hasPresented`
    /// guards against a later, redundant `viewDidAppear` (e.g. this screen
    /// being re-shown after being backgrounded) attempting to present a
    /// second time for the same handoff.
    private func presentCloudSharingControllerIfNeeded() {
        guard !hasPresented, let handoff, let delegate else { return }
        hasPresented = true

        let container = CKContainer(identifier: handoff.containerIdentifier)
        let controller = UICloudSharingController(share: handoff.share, container: container)
        controller.delegate = delegate
        // Apple's own UICloudSharingController documentation: "You must set
        // the popoverPresentationController before presenting" — required
        // on iPad, harmless on iPhone.
        controller.popoverPresentationController?.sourceView = view
        controller.presentationController?.delegate = delegate
        self.present(controller, animated: true)
    }
}
