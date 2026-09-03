import Foundation

/// Athlete Connection Foundation B1: the ONE CloudKit container both
/// `ParentApp` and `AthleteApp` are configured to use (see each target's
/// `.entitlements` file, `com.apple.developer.icloud-container-identifiers`).
/// Foundation B discovery established `FamilyWorkspace` as the single
/// CloudKit sharing root for the family MVP (DDM-006) — one shared
/// container, not one per app, is what makes cross-account Parent/Athlete
/// sharing possible at all: CloudKit sharing (`CKShare`) only works between
/// participants of the SAME container.
///
/// No canonical container identifier existed anywhere in this repository
/// before this round (verified: no `.entitlements` file, no CloudKit
/// reference in `project.pbxproj` — see the Foundation B discovery
/// document). This value was chosen following the existing
/// `app.voxtr.athlete`/`app.voxtr.parent` bundle-identifier convention.
///
/// IMPORTANT: this string must exactly match the container identifier
/// actually provisioned for this app in the Apple Developer Portal /
/// App Store Connect before a real, signed build can use CloudKit at
/// runtime — that external configuration is NOT something this repository
/// can create or verify. See the Foundation B1 delivery report for what
/// remains to be configured there.
public enum CloudKitContainerIdentifier {
    public static let voxtrFamily = "iCloud.app.voxtr.shared"
}
