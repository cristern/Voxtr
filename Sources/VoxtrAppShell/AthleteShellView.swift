import SwiftUI
import VoxtrAthleteDomain

/// Athlete App Shell / UX Foundation: the ENTIRE AthleteApp experience
/// whenever `AthleteShellRoute.route(for:)` resolves to `.shell(actor:)`
/// (i.e. `AthleteRuntimeSession.state` is `.connected`). Replaces the old
/// Sprint-0 `NavigationShellView()` placeholder (deleted this round — see
/// this file's own PR description) with the smallest reversible
/// navigation foundation this task's own repository audit could support:
/// no canonical Athlete navigation document exists anywhere in the repo
/// (`Docs/` was searched), and ParentApp's own `ParentTabShellView` is
/// heavily Planning/Training/Reflection/Statistics-dependent — explicitly
/// NOT to be copied for an app that, this round, must not query any of
/// those domains.
///
/// Two tabs only: **Now** (the future day-to-day landing surface — today
/// a calm, honest empty state) and **Profile** (athlete identity plus the
/// relocated Internal Alpha diagnostics — see `AthleteProfileView`'s own
/// doc comment). Deliberately small — a `TabView` is trivially extensible
/// later (e.g. Training/Reflection tabs) without restructuring, so this
/// is a foundation, not a final navigation decision.
struct AthleteShellView: View {
    let actor: CurrentSessionActor
    let athleteRepository: AthleteRepository

    var body: some View {
        TabView {
            NavigationStack {
                AthleteNowView(actor: actor, athleteRepository: athleteRepository)
            }
            .tabItem {
                Label("Now", systemImage: "house")
            }
            .accessibilityIdentifier("athleteTabs.now")

            NavigationStack {
                AthleteProfileView(actor: actor, athleteRepository: athleteRepository)
            }
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("athleteTabs.profile")
        }
        .accessibilityIdentifier("athleteShell.tabView")
    }
}
