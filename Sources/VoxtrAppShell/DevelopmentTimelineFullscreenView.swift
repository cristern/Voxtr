import SwiftUI
import VoxtrCoreContracts
import VoxtrCoreReferenceData

/// Statistics V1 UI (fullscreen Timeline round): a dedicated, larger
/// presentation of the SAME Development Timeline chart and Statistics
/// state `AthleteStatisticsView` already loads — never a second
/// Statistics read model. `viewModel` is the exact same
/// `AthleteStatisticsViewModel` instance the caller already holds (a
/// reference type). Reuses `DevelopmentTimelineChart` directly (via its
/// `chartHeight` parameter) rather than forking a second chart
/// implementation.
///
/// Fullscreen data-ownership round: this view holds NO summary/point
/// snapshot of its own. `body` reads `viewModel.loadState` directly —
/// the SAME live, `@Observable` state `AthleteStatisticsView` reads —
/// and derives Timeline points from whatever `.loaded(summary)` it
/// currently holds via `DevelopmentTimelinePoint.points(from:sports:)`,
/// the one shared projection both screens use. A Sport/Activity Type
/// filter change made HERE (via `StatisticsFilterMenus`, which calls
/// `viewModel.setSportFilter`/`setActivityTypeFilter` → `load()`)
/// mutates that SAME `loadState`, so this view's next body evaluation
/// renders the new summary automatically — no local filtering, no
/// second reload path, no stale capture from whenever the cover
/// happened to open. `.loading`/`.failed` are rendered with the SAME
/// visual treatment `AthleteStatisticsView` itself uses for those
/// states, under fullscreen-specific accessibility identifiers.
///
/// Fullscreen filters round: `sports` is the SAME canonical Sport
/// catalog `AthleteStatisticsView` already loads via
/// `SportRepository.fetchAllSports()`, passed straight through — this
/// view never fetches Sport reference data itself.
///
/// No orientation-detection code: a `GeometryReader` simply reads
/// `geometry.size`, which SwiftUI already re-reports on every layout
/// pass (including a rotation) with no notification/timer machinery —
/// the chart's height is derived from that available space, and the
/// surrounding `ScrollView` is a plain safety net against clipping on
/// short landscape heights, not a workaround for anything fragile.
///
/// Landscape is only reachable while THIS screen is on-screen: `.onAppear`
/// widens `VoxtrOrientationPolicy.shared` to portrait + both landscapes,
/// and `.onDisappear` restores it to ParentApp's own portrait-only
/// default — standard, deterministic SwiftUI presentation lifecycle
/// hooks tied 1:1 to this view's own appearance, never a timing hack.
/// Normal Athlete Statistics (and every other ParentApp screen) never
/// requests the wider mask, so rotating while still there does nothing.
struct DevelopmentTimelineFullscreenView: View {
    let viewModel: AthleteStatisticsViewModel
    let sports: [Sport]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .voxtrScreenBackground()
                .navigationTitle("Development Timeline")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .tint(VoxtrColor.accent)
        .accessibilityIdentifier("athleteStatisticsTimelineFullscreen.root")
        .onAppear {
            VoxtrOrientationPolicy.shared.setAllowedOrientations(VoxtrOrientationPolicy.portraitAndLandscape)
        }
        .onDisappear {
            VoxtrOrientationPolicy.shared.setAllowedOrientations(VoxtrOrientationPolicy.portraitOnly)
        }
    }

    /// Mirrors `AthleteStatisticsView.body`'s own three-way switch over
    /// `loadState` — same states, same meaning, only the presentation
    /// (fullscreen chart vs. portrait List) differs. Reading `viewModel
    /// .loadState` directly here (rather than being handed a snapshot)
    /// is what makes a filter/period/breakdown change reload correctly:
    /// the ViewModel mutates its own `loadState`, and this computed
    /// property re-evaluates on the next body pass like any other
    /// `@Observable` read.
    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("athleteStatisticsTimelineFullscreen.loadingIndicator")
        case .failed:
            ContentUnavailableView(
                "Couldn't load Statistics",
                systemImage: "exclamationmark.triangle",
                description: Text("Try again in a moment.")
            )
            .accessibilityIdentifier("athleteStatisticsTimelineFullscreen.errorState")
        case .loaded(let summary):
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        StatisticsFilterMenus(
                            viewModel: viewModel,
                            sports: sports,
                            identifierPrefix: "athleteStatisticsTimelineFullscreen"
                        )
                        breakdownModePicker
                        seriesToggles
                        DevelopmentTimelineChart(
                            points: DevelopmentTimelinePoint.points(from: summary, sports: sports),
                            isTrainingVisible: viewModel.isTrainingSeriesVisible,
                            isFormVisible: viewModel.isFormSeriesVisible,
                            isSleepVisible: viewModel.isSleepSeriesVisible,
                            intervalStart: summary.intervalStart,
                            intervalEnd: summary.intervalEnd,
                            chartHeight: max(240, geometry.size.height - 120),
                            breakdownMode: viewModel.trainingBreakdownMode
                        )
                        .accessibilityIdentifier("athleteStatisticsTimelineFullscreen.developmentTimeline")
                    }
                    .padding()
                    .frame(minHeight: geometry.size.height)
                }
            }
        }
    }

    /// The SAME Training Breakdown control as Athlete Statistics, bound
    /// to the SAME shared `viewModel.trainingBreakdownMode` — no second,
    /// fullscreen-only breakdown state. Changing it here stays reflected
    /// after returning to Athlete Statistics, and vice versa.
    private var breakdownModePicker: some View {
        Picker("Training Breakdown", selection: Binding(
            get: { viewModel.trainingBreakdownMode },
            set: { viewModel.trainingBreakdownMode = $0 }
        )) {
            ForEach(TrainingBreakdownMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("athleteStatisticsTimelineFullscreen.trainingBreakdownPicker")
    }

    /// The SAME Training/Form/Sleep toggles as the embedded Athlete
    /// Statistics section, bound to the SAME shared `viewModel` — a
    /// change made here is immediately reflected back on the Athlete
    /// Statistics screen, and vice versa, since both read/write one
    /// underlying instance rather than independent copies.
    private var seriesToggles: some View {
        HStack(spacing: 12) {
            Toggle("Training", isOn: Binding(
                get: { viewModel.isTrainingSeriesVisible },
                set: { viewModel.isTrainingSeriesVisible = $0 }
            ))
            Toggle("Form", isOn: Binding(
                get: { viewModel.isFormSeriesVisible },
                set: { viewModel.isFormSeriesVisible = $0 }
            ))
            Toggle("Sleep", isOn: Binding(
                get: { viewModel.isSleepSeriesVisible },
                set: { viewModel.isSleepSeriesVisible = $0 }
            ))
        }
        .toggleStyle(.button)
        .font(VoxtrTypography.metadata)
        .accessibilityIdentifier("athleteStatisticsTimelineFullscreen.seriesToggles")
    }
}
