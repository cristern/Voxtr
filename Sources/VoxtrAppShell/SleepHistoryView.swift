import SwiftUI
import VoxtrCoreContracts

/// VX-023 (Sleep V1): "the same interaction family as Weekly History
/// where appropriate, but daily not weekly" — same List + ForEach +
/// "Load more" shape as `WeeklyHistoryListView`, adapted for daily rows
/// that (unlike weekly ones) always render even when nothing was
/// logged, per `SleepHistoryRow`'s own doc comment.
public struct SleepHistoryView: View {
    @State private var viewModel: SleepHistoryViewModel
    let athleteDisplayName: String
    let today: LocalDate
    /// Builds a fresh `SleepCaptureViewModel` for a given row's date —
    /// same "caller supplies a maker closure" shape
    /// `WeeklyHistoryListView.makeDetailView` already establishes, so
    /// this view never has to know how to construct
    /// `SleepCoordinationService` dependencies itself.
    let makeCaptureViewModel: (LocalDate, Int?) -> SleepCaptureViewModel

    public init(
        viewModel: SleepHistoryViewModel,
        athleteDisplayName: String,
        today: LocalDate,
        makeCaptureViewModel: @escaping (LocalDate, Int?) -> SleepCaptureViewModel
    ) {
        _viewModel = State(initialValue: viewModel)
        self.athleteDisplayName = athleteDisplayName
        self.today = today
        self.makeCaptureViewModel = makeCaptureViewModel
    }

    public var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            ForEach(viewModel.rows) { row in
                NavigationLink {
                    // "Edit history date rereads the corrected canonical
                    // value" — refreshRow(for:) updates just this ONE
                    // row in place once the capture screen reports a
                    // successful save, never a full reload/re-page.
                    SleepCaptureView(
                        viewModel: makeCaptureViewModel(row.localDate, row.sleepQuality),
                        onSaved: { viewModel.refreshRow(for: row.localDate) }
                    )
                } label: {
                    HStack {
                        Text(SleepHistoryDateFormatter.label(for: row.localDate, today: today))
                        Spacer()
                        if let sleepQuality = row.sleepQuality {
                            Text("\(sleepQuality)/5")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not logged")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("sleepHistory.row.\(row.id)")
            }
            if viewModel.canLoadMore {
                Button("Load more") {
                    viewModel.loadMore()
                }
                .accessibilityIdentifier("sleepHistory.loadMoreButton")
            }
        }
        .navigationTitle("Sleep History")
        .onAppear {
            if viewModel.rows.isEmpty {
                viewModel.loadInitial()
            }
        }
    }
}
