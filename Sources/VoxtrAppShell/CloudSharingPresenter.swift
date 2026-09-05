import SwiftUI
import UIKit
import CloudKit
import VoxtrCore

/// Athlete Connection Foundation B2.6: presents Apple's own native
/// CloudKit sharing UI (`UICloudSharingController`) for an ALREADY-
/// created `CKShare` (via `AthleteConnectionOwnerHandoffService
/// .prepareInvitation(...)`) — this codebase adds no custom email/SMS
/// invite delivery of its own; the Parent sends the invite through
/// whatever standard iOS share-sheet mechanism they choose from this
/// controller (Messages, Mail, AirDrop, copy link, etc.), exactly as
/// Apple's own API is designed to be used.
///
/// NO SWIFTUI-NATIVE EQUIVALENT: `UICloudSharingController` is a UIKit
/// `UIViewController` with no SwiftUI wrapper Apple provides — this is
/// the correct, current (non-deprecated), documented API for presenting
/// native CloudKit sharing UI, wrapped the standard `UIViewControllerRepresentable`
/// way.
///
/// CONSTRUCTION: `UICloudSharingController(share:container:)` — the
/// overload for a share that ALREADY exists (B2.1's `ensureSharingRoot`
/// already produced the real `CKShare` by the time this view appears),
/// as opposed to the closure-based overload that CREATES a share, which
/// this slice does not use since creation is B2.1's own already-idempotent
/// job. `container`: constructed here, from the handoff's own
/// `containerIdentifier` — this is the one place in this slice a real
/// `CKContainer` is realized directly rather than through
/// `CloudKitTransport`'s own lazy-realization wrapper, because
/// presentation legitimately needs the concrete UIKit type and this only
/// ever runs from an explicit Parent action (never at `CompositionRoot
/// .build()` time), matching this codebase's own "no CloudKit I/O at
/// launch" invariant.
///
/// DOES NOT decide `share.publicPermission` here — B2.1 already set that
/// once, at share creation; this presenter must not casually change it.
public struct CloudSharingPresenter: UIViewControllerRepresentable {
    public let handoff: AthleteConnectionInvitationHandoff
    public let athleteDisplayName: String
    public let onDismiss: () -> Void

    public init(handoff: AthleteConnectionInvitationHandoff, athleteDisplayName: String, onDismiss: @escaping () -> Void) {
        self.handoff = handoff
        self.athleteDisplayName = athleteDisplayName
        self.onDismiss = onDismiss
    }

    public func makeUIViewController(context: Context) -> UICloudSharingController {
        let container = CKContainer(identifier: handoff.containerIdentifier)
        let controller = UICloudSharingController(share: handoff.share, container: container)
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(athleteDisplayName: athleteDisplayName, onDismiss: onDismiss)
    }

    /// `NSObject`: `UICloudSharingControllerDelegate` is an Objective-C
    /// protocol, matching every other UIKit delegate bridge in this
    /// codebase's own established pattern.
    public final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let athleteDisplayName: String
        private let onDismiss: () -> Void
        private let log = VoxtrLog.logger(.appShell)

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
            onDismiss()
        }

        public func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onDismiss()
        }
    }
}
