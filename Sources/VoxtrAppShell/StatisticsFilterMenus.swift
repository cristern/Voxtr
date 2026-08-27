import SwiftUI
import VoxtrCoreContracts
import VoxtrCoreReferenceData

/// Statistics filter follow-up (fullscreen filters round): the Sport
/// and Activity Type filter Menus, extracted into one shared component
/// so Athlete Statistics and the fullscreen Development Timeline render
/// IDENTICAL filter controls against the SAME authoritative
/// `AthleteStatisticsViewModel` — rather than each duplicating the
/// Menu-construction logic. Purely presentational: every read (the
/// canonical `sports` list, `viewModel.availableSportIds`) and every
/// write (`viewModel.setSportFilter`/`setActivityTypeFilter`) goes
/// through data/methods the caller already owns — this component
/// fetches nothing itself and owns no state of its own.
struct StatisticsFilterMenus: View {
    let viewModel: AthleteStatisticsViewModel
    /// The FULL canonical Sport catalog, already loaded by the caller
    /// (`SportRepository.fetchAllSports()`) — never re-fetched here.
    let sports: [Sport]
    /// Distinguishes this instance's accessibility identifiers from
    /// another instance rendered elsewhere (Athlete Statistics vs. the
    /// fullscreen Timeline) — preserves each screen's own pre-existing
    /// identifier namespace rather than introducing a single shared one
    /// that would silently change either screen's existing identifiers.
    let identifierPrefix: String

    var body: some View {
        Group {
            sportFilterMenu
            activityTypeFilterMenu
        }
    }

    /// Sport filter catalog refinement round: narrowed to the Sports
    /// this athlete has actually recorded performed Statistics history
    /// against (`viewModel.availableSportIds`, refreshed by the
    /// ViewModel's own `load()`) — never the full canonical catalog.
    /// Intersecting two already-resolved lists is presentation-layer
    /// derivation, not a second Sport-availability computation; the
    /// canonical `sortOrder` from `sports` is preserved for free.
    private var availableSports: [Sport] {
        sports.filter { viewModel.availableSportIds.contains($0.sportId) }
    }

    /// No "No sport" filter option in this V1 UI — `StatisticsFilter
    /// .sportId == nil` already means "no constraint" (every activity
    /// matches), so it cannot also mean "only activities with no
    /// Sport" without a fragile workaround. "All Sports" here maps to
    /// that same `nil`; a concrete Sport is the only other option.
    private var sportFilterMenu: some View {
        Menu {
            Button("All Sports") { viewModel.setSportFilter(nil) }
            if !availableSports.isEmpty {
                Divider()
                ForEach(availableSports) { sport in
                    Button(sport.displayName) { viewModel.setSportFilter(sport.sportId) }
                }
            }
        } label: {
            LabeledContent("Sport", value: selectedSportName)
        }
        .accessibilityIdentifier("\(identifierPrefix).sportFilter")
    }

    private var selectedSportName: String {
        guard let sportId = viewModel.sportFilter else { return "All Sports" }
        return sports.first(where: { $0.sportId == sportId })?.displayName ?? "All Sports"
    }

    private var activityTypeFilterMenu: some View {
        Menu {
            Button("All Types") { viewModel.setActivityTypeFilter(nil) }
            Divider()
            ForEach(ActivityType.selectableCases, id: \.self) { type in
                Button(type.displayName) { viewModel.setActivityTypeFilter(type) }
            }
        } label: {
            LabeledContent("Activity Type", value: viewModel.activityTypeFilter?.displayName ?? "All Types")
        }
        .accessibilityIdentifier("\(identifierPrefix).activityTypeFilter")
    }
}
