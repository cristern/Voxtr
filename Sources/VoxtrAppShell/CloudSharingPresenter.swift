import SwiftUI
import UIKit
import CloudKit
import VoxtrCore

/// Athlete Connection Foundation B2.6 (TestFlight runtime crash follow-up,
/// ParentApp build 502): presents Apple's own native CloudKit sharing UI
/// (`UICloudSharingController`) for an ALREADY-created `CKShare` (via
/// `AthleteConnectionOwnerHandoffService.prepareInvitation(...)`) — this
/// codebase adds no custom email/SMS invite delivery of its own; the Parent
/// sends the invite through whatever standard iOS share-sheet mechanism they
/// choose from this controller (Messages, Mail, AirDrop, copy link, etc.),
/// exactly as Apple's own API is designed to be used.
///
/// ROOT CAUSE OF THE CONFIRMED TESTFLIGHT CRASH (EXC_BREAKPOINT/SIGTRAP
/// inside CloudKit.framework, on tapping "Connect Athlete App"): Apple's own
/// `UICloudSharingController` documentation requires this controller to be
/// PRESENTED — via a genuine `present(_:animated:completion:)` call, with
/// its `popoverPresentationController` configured first ("You must set the
/// popoverPresentationController before presenting"). The PRIOR version of
/// this file made `UICloudSharingController` itself this type's
/// `UIViewControllerType`, returned directly from `makeUIViewController`,
/// and relied on the caller wrapping it in SwiftUI's `.sheet(isPresented:)`.
/// SwiftUI does not call `present(_:)` on a `UIViewControllerRepresentable`'s
/// own returned controller — it EMBEDS it as a CHILD of SwiftUI's own
/// internally-managed hosting controller (`addChild`/view embedding), never
/// a genuine UIKit presentation. `UICloudSharingController`'s own internal
/// implementation depends on genuinely being the presented controller (its
/// `presentingViewController`, and its own further internal presentations
/// for the "Add People" flow); without that, this system controller's
/// internal CloudKit.framework code hit an assertion on a real, signed
/// device. This is a well-documented general failure mode for
/// SwiftUI-wrapping system view controllers designed only to be presented
/// (the same class of issue historically seen with `MFMailComposeViewController`/
/// `UIActivityViewController` before Apple shipped native SwiftUI wrappers
/// for those).
///
/// THE FIX: this representable's own `UIViewControllerType` is now a plain,
/// invisible ANCHOR `UIViewController` — never `UICloudSharingController`
/// itself. The caller embeds this anchor via `.background(...)` on an
/// always-on-screen view (never `.sheet`), so it becomes part of a REAL,
/// already-presented view-controller hierarchy. Once embedded,
/// `updateUIViewController` calls a genuine `anchor.present(cloudSharingController,
/// animated: true)` exactly once per handoff — the pattern Apple's own
/// documentation describes.
///
/// NOT A CKSharingSupported PROBLEM: Apple's own `CKSharingSupported`
/// documentation ties this Info.plist key exclusively to "launch your app
/// when the user taps or clicks a share's URL" — the ACCEPTING side
/// (AthleteApp, which already declares it — see
/// `CloudKitCapabilityConfigurationTests.athleteAppDeclaresCKSharingSupported`
/// in Tests/VoxtrSprint0Tests/CloudKitTransportTests.swift). ParentApp never
/// accepts or launches from a tapped share link in this architecture; it
/// only ever CREATES and PRESENTS a share. Investigation for this fix
/// confirmed ParentApp's entitlements are already identical/correct to
/// AthleteApp's, and its Info.plist correctly omits `CKSharingSupported` —
/// adding that key would not have addressed this crash, whose actual cause
/// was this file's own presentation mechanics, not app configuration.
///
/// CONSTRUCTION: `UICloudSharingController(share:container:)` — the overload
/// for a share that ALREADY exists (B2.1's `ensureSharingRoot`/B2.6's
/// `createInvitationShare` already produced the real `CKShare` by the time
/// this view appears), as opposed to the closure-based overload that CREATES
/// a share, which this slice does not use since creation is already this
/// codebase's own idempotent job. `container`: constructed here, from the
/// handoff's own `containerIdentifier` — this is the one place in this
/// slice a real `CKContainer` is realized directly rather than through
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
    /// itself. See this type's own doc comment for why. `.clear`/non-
    /// interactive: this anchor is embedded via `.background(...)` behind
    /// real, visible SwiftUI content — it must never paint over or
    /// intercept touches meant for that content.
    public func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    /// Presents the real `UICloudSharingController` via a genuine
    /// `present(_:animated:completion:)` call, exactly once per handoff —
    /// `context.coordinator.hasPresented` guards against re-presenting on a
    /// later, unrelated SwiftUI diff of this same anchor.
    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard !context.coordinator.hasPresented else { return }
        context.coordinator.hasPresented = true

        let container = CKContainer(identifier: handoff.containerIdentifier)
        let controller = UICloudSharingController(share: handoff.share, container: container)
        controller.delegate = context.coordinator
        // Apple's own UICloudSharingController documentation: "You must set
        // the popoverPresentationController before presenting" — required
        // on iPad, harmless on iPhone.
        controller.popoverPresentationController?.sourceView = uiViewController.view
        controller.presentationController?.delegate = context.coordinator
        uiViewController.present(controller, animated: true)
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
        /// Guards `updateUIViewController` from presenting more than once
        /// for the same anchor — see this type's own doc comment.
        var hasPresented = false

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
            onDismiss()
        }

        public func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            csc.dismiss(animated: true)
            onDismiss()
        }

        /// Now that this controller is genuinely presented (rather than
        /// SwiftUI-sheet-embedded), a manual interactive dismissal (swipe
        /// down) no longer flows back through any SwiftUI `.sheet` binding
        /// on its own — without this, `pendingInvitationHandoff` would stay
        /// stale/non-nil after the user dismisses this way.
        public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismiss()
        }
    }
}
