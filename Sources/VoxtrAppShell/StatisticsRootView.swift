import SwiftUI
import VoxtrCoreContracts
import VoxtrCoreReferenceData

/// Statistics V1 UI — Parent Statistics root: a family overview, one
/// card per active athlete, no ranking, no comparative ordering by
/// performance (cards render in the SAME `(createdAt, id)` order every
/// other Parent tab's athlete list already uses — never sorted by any
/// of the numbers on the card). Tapping a card opens Athlete Statistics
/// for that athlete's stable `AthleteId`.
public struct StatisticsRootView: View {
    @State private var viewModel: StatisticsRootViewModel
    private let statisticsService: StatisticsService
    private let sportRepository: SportRepository

    public init(viewModel: StatisticsRootViewModel, statisticsService: StatisticsService, sportRepository: SportRepository) {
        _viewModel = State(initialValue: viewModel)
        self.statisticsService = statisticsService
        self.sportRepository = sportRepository
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .voxtrScreenBackground()
                    .accessibilityIdentifier("statistics.root.loadingIndicator")
            case .failed:
                ContentUnavailableView(
                    "Couldn't load Statistics",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Try again in a moment.")
                )
                .accessibilityIdentifier("statistics.root.errorState")
            case .loaded(let cards):
                if cards.isEmpty {
                    // No active athletes: same empty-state shape
                    // `ParentTrainingTabView` already uses for the
                    // identical roster-empty condition — Statistics
                    // does not invent a second one. Adding an athlete
                    // stays a Profile-tab action (Statistics is
                    // read-only), so this only points there in text,
                    // consistent with the existing pattern.
                    ContentUnavailableView(
                        "No athletes yet",
                        systemImage: "chart.bar",
                        description: Text("Add an athlete from Profile to see their Statistics.")
                    )
                    .accessibilityIdentifier("statistics.root.emptyState")
                } else {
                    List {
                        Section {
                            ForEach(cards) { card in
                                NavigationLink {
                                    AthleteStatisticsView(
                                        viewModel: AthleteStatisticsViewModel(
                                            statisticsService: statisticsService,
                                            athleteId: card.athleteId,
                                            athleteDisplayName: card.displayName
                                        ),
                                        sportRepository: sportRepository
                                    )
                                } label: {
                                    StatisticsAthleteCardView(card: card)
                                }
                                .accessibilityIdentifier("statistics.root.athleteCard.\(card.athleteId.rawValue.uuidString)")
                            }
                        } header: {
                            VoxtrSectionHeading(StatisticsPeriod.default.displayName)
                        }
                        .voxtrRowSurface()
                    }
                    .voxtrScreenBackground()
                }
            }
        }
        .tint(VoxtrColor.accent)
        .navigationTitle("Statistics")
        .accessibilityIdentifier("statistics.root")
        .onAppear { viewModel.load() }
    }
}

/// One family-overview card: factual measures only, no verdicts.
private struct StatisticsAthleteCardView: View {
    let card: StatisticsRootViewModel.AthleteCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.displayName)
                .font(VoxtrTypography.cardTitle)
                .foregroundStyle(VoxtrColor.textPrimary)

            Text("\(StatisticsFormatting.minutes(card.summary.totalActualMinutes)) · \(card.summary.performedActivityCount) activities")
                .font(VoxtrTypography.value)
                .foregroundStyle(VoxtrColor.textPrimary)

            HStack(spacing: 16) {
                Text("Form: \(StatisticsFormatting.average(card.summary.form.mean))")
                Text("Sleep: \(StatisticsFormatting.average(card.summary.sleep.mean))")
            }
            .font(VoxtrTypography.metadata)
            .foregroundStyle(VoxtrColor.textSecondary)
        }
        .padding(.vertical, 4)
    }
}
