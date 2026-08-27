import SwiftUI
import VoxtrCoreContracts

/// Statistics V1 UI (fullscreen Timeline round): a dedicated, larger
/// presentation of the SAME Development Timeline chart and Statistics
/// state `AthleteStatisticsView` already loads — never a second
/// Statistics read model. `viewModel` is the exact same
/// `AthleteStatisticsViewModel` instance the caller already holds (a
/// reference type), so toggling a series here mutates the one shared
/// state directly; `points`/`intervalStart`/`intervalEnd` are the same
/// values already derived from the loaded `StatisticsAthleteSummary`,
/// passed straight through rather than reloaded or recomputed here.
/// Reuses `DevelopmentTimelineChart` directly (via its `chartHeight`
/// parameter) rather than forking a second chart implementation.
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
    let points: [DevelopmentTimelinePoint]
    let intervalStart: LocalDate
    let intervalEnd: LocalDate

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        breakdownModePicker
                        seriesToggles
                        DevelopmentTimelineChart(
                            points: points,
                            isTrainingVisible: viewModel.isTrainingSeriesVisible,
                            isFormVisible: viewModel.isFormSeriesVisible,
                            isSleepVisible: viewModel.isSleepSeriesVisible,
                            intervalStart: intervalStart,
                            intervalEnd: intervalEnd,
                            chartHeight: max(240, geometry.size.height - 120),
                            breakdownMode: viewModel.trainingBreakdownMode
                        )
                        .accessibilityIdentifier("athleteStatisticsTimelineFullscreen.developmentTimeline")
                    }
                    .padding()
                    .frame(minHeight: geometry.size.height)
                }
            }
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
