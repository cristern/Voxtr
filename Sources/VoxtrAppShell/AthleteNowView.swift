import SwiftUI
import VoxtrAthleteDomain

/// Athlete App Shell / UX Foundation: the "Now" tab — the future
/// day-to-day landing surface for AthleteApp. This round intentionally
/// shows ONLY a calm greeting and an honest empty state: no Planning
/// data, no Training data, no Reflection data, no fabricated
/// recommendations/readiness/recovery/performance calculations — none of
/// those domains are wired into AthleteApp yet, and this task's own scope
/// explicitly excludes adding them. The empty state exists to tell the
/// athlete their app is working as intended, not broken — never to
/// manufacture usefulness with fake data.
///
/// Reuses the native `ContentUnavailableView` component already
/// established elsewhere in this design system (e.g.
/// `AthleteStatisticsView`'s error state, `ParentTrainingTabView`'s "No
/// athletes yet") rather than inventing new empty-state UI.
struct AthleteNowView: View {
    let actor: CurrentSessionActor
    let athleteRepository: AthleteRepository

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(greeting)
                    .font(VoxtrTypography.screenTitle)
                    .foregroundStyle(VoxtrColor.textPrimary)
                    .accessibilityIdentifier("athleteNow.greeting")

                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "sparkles",
                    description: Text("Your day-to-day activity will show up here once it's ready.")
                )
                .accessibilityIdentifier("athleteNow.emptyState")
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
            }
            .padding()
        }
        .voxtrScreenBackground()
        .navigationTitle("Now")
        .accessibilityIdentifier("athleteNow.screen")
    }

    private var greeting: String {
        guard let name = AthleteDisplayIdentity.resolvedName(for: actor, athleteRepository: athleteRepository) else {
            return "Welcome"
        }
        return "Hi, \(name)"
    }
}
