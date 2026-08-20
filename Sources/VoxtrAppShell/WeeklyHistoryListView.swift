import SwiftUI
import VoxtrCoreContracts

/// Area 6 correction: the actual Training entry surface — a
/// discoverable list of weeks, newest first, each with a factual
/// summary. Selecting one navigates to the detailed `WeeklyHistoryView`
/// for that specific week (which may still offer arrow navigation as a
/// secondary aid, but this list is the primary entry point).
public struct WeeklyHistoryListView: View {
    @State private var viewModel: WeeklyHistoryListViewModel
    let athleteDisplayName: String
    let currentWeekStart: LocalDate
    let makeDetailView: (LocalDate) -> WeeklyHistoryView

    public init(
        viewModel: WeeklyHistoryListViewModel,
        athleteDisplayName: String,
        currentWeekStart: LocalDate,
        makeDetailView: @escaping (LocalDate) -> WeeklyHistoryView
    ) {
        _viewModel = State(initialValue: viewModel)
        self.athleteDisplayName = athleteDisplayName
        self.currentWeekStart = currentWeekStart
        self.makeDetailView = makeDetailView
    }

    public var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
                .voxtrRowSurface()
            }
            ForEach(viewModel.summaries) { summary in
                NavigationLink {
                    makeDetailView(summary.weekStart)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WeekIdentityFormatter.stableIdentityLabel(forWeekStart: summary.weekStart))
                            .font(VoxtrTypography.cardTitle)
                            .foregroundStyle(VoxtrColor.textPrimary)
                        if let context = WeekIdentityFormatter.contextualLabel(for: summary.weekStart, referenceWeekStart: currentWeekStart) {
                            Text(context)
                                .font(VoxtrTypography.caption)
                                .foregroundStyle(VoxtrColor.textSecondary)
                        }
                        Text("Planned \(summary.plannedCount) · Completed from plan \(summary.completedFromPlanCount) · Additional \(summary.additionalCount)")
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                    }
                }
                .accessibilityIdentifier("weeklyHistoryList.weekRow.\(summary.weekStart.isoString)")
                .voxtrRowSurface()
            }
            if viewModel.canLoadMore {
                Button("Load more") {
                    viewModel.loadMore()
                }
                .accessibilityIdentifier("weeklyHistoryList.loadMoreButton")
                .voxtrRowSurface()
            }
        }
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle("Week by Week")
        .onAppear {
            if viewModel.summaries.isEmpty {
                viewModel.loadInitial()
            }
        }
    }
}
