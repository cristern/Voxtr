import SwiftUI
import VoxtrAthleteDomain

/// Athlete App Shell / UX Foundation: the "Profile" tab — athlete
/// identity plus the RELOCATED Internal Alpha diagnostics that previously
/// lived in the old `AthleteConnectionStatusView`'s always-visible debug
/// caption (`debugIdentifiers(for:)`, removed this round). Those stable
/// participant/workspace identifiers are still genuinely needed for the
/// still-pending two-device QR pairing TestFlight validation (see this
/// PR's own delivery report) — NOT deleted, only moved to a clearly
/// secondary, collapsed `DisclosureGroup`, off by default, so ordinary
/// use of this screen never shows raw IDs as if they were normal product
/// UI.
///
/// Identity is resolved via the SAME canonical `AthleteDisplayIdentity
/// .resolvedName(for:athleteRepository:)` the Now tab uses — no second,
/// duplicate name lookup or locally-stored identity truth.
struct AthleteProfileView: View {
    let actor: CurrentSessionActor
    let athleteRepository: AthleteRepository

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(VoxtrColor.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(VoxtrTypography.cardTitle)
                            .foregroundStyle(VoxtrColor.textPrimary)
                            .accessibilityIdentifier("athleteProfile.displayName")
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(VoxtrTypography.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
            }
            .voxtrRowSurface()

            Section {
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Participant \(actor.participantId.uuidString)")
                        Text("Workspace \(actor.workspaceId.rawValue.uuidString)")
                    }
                    .font(VoxtrTypography.caption)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("athleteProfile.technicalDetails")
                }
            } header: {
                VoxtrSectionHeading("Diagnostics")
            } footer: {
                Text("For support use only while device pairing is being verified.")
            }
            .voxtrRowSurface()
        }
        .voxtrScreenBackground()
        .navigationTitle("Profile")
        .accessibilityIdentifier("athleteProfile.screen")
    }

    private var displayName: String {
        AthleteDisplayIdentity.resolvedName(for: actor, athleteRepository: athleteRepository) ?? "Athlete"
    }
}
