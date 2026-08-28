import SwiftUI
import VoxtrCoreContracts
import VoxtrCoreReferenceData

/// Statistics V1 UI — Athlete Statistics detail: period + Sport +
/// Activity Type filters, actual training summary, the Development
/// Timeline, and Form/Sleep summaries for one athlete.
public struct AthleteStatisticsView: View {
    @State private var viewModel: AthleteStatisticsViewModel
    private let sportRepository: SportRepository

    @State private var sports: [Sport] = []
    @State private var isShowingFullscreenTimeline = false

    public init(viewModel: AthleteStatisticsViewModel, sportRepository: SportRepository) {
        _viewModel = State(initialValue: viewModel)
        self.sportRepository = sportRepository
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .voxtrScreenBackground()
                    .accessibilityIdentifier("athleteStatistics.loadingIndicator")
            case .failed:
                ContentUnavailableView(
                    "Couldn't load Statistics",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Try again in a moment.")
                )
                .accessibilityIdentifier("athleteStatistics.errorState")
            case .loaded(let summary):
                List {
                    Section {
                        periodPicker
                        StatisticsFilterMenus(viewModel: viewModel, sports: sports, identifierPrefix: "athleteStatistics")
                    } header: {
                        VoxtrSectionHeading("Filters")
                    }
                    .voxtrRowSurface()

                    Section {
                        summaryContent(summary)
                    } header: {
                        VoxtrSectionHeading("Actual Training")
                    }
                    .voxtrRowSurface()

                    Section {
                        planVsActualContent(summary)
                    } header: {
                        VoxtrSectionHeading("Plan vs Actual")
                    }
                    .voxtrRowSurface()

                    Section {
                        comparisonModePicker
                        if viewModel.timelineComparisonMode == .actual {
                            breakdownModePicker
                        }
                        HStack {
                            seriesToggles
                            Spacer()
                            expandTimelineButton
                        }
                        DevelopmentTimelineChart(
                            points: points(from: summary),
                            isTrainingVisible: viewModel.isTrainingSeriesVisible,
                            isFormVisible: viewModel.isFormSeriesVisible,
                            isSleepVisible: viewModel.isSleepSeriesVisible,
                            intervalStart: summary.intervalStart,
                            intervalEnd: summary.intervalEnd,
                            breakdownMode: viewModel.trainingBreakdownMode,
                            comparisonMode: viewModel.timelineComparisonMode
                        )
                        .accessibilityIdentifier("athleteStatistics.developmentTimeline")
                    } header: {
                        VoxtrSectionHeading("Development Timeline")
                    }
                    .voxtrRowSurface()

                    Section {
                        LabeledContent("Form", value: StatisticsFormatting.average(summary.form.mean))
                            .accessibilityIdentifier("athleteStatistics.formSummary")
                        LabeledContent("Sleep", value: StatisticsFormatting.average(summary.sleep.mean))
                            .accessibilityIdentifier("athleteStatistics.sleepSummary")
                    } header: {
                        VoxtrSectionHeading("Form & Sleep")
                    }
                    .voxtrRowSurface()
                }
                .voxtrScreenBackground()
                .fullScreenCover(isPresented: $isShowingFullscreenTimeline) {
                    // Fullscreen data-ownership round: no `points`/
                    // `intervalStart`/`intervalEnd` snapshot passed in —
                    // fullscreen derives those itself from `viewModel
                    // .loadState`, the SAME live state this screen
                    // reads, so a filter change made in fullscreen (or
                    // here) is reflected in both places from the one
                    // authoritative summary, never a stale capture from
                    // whenever the cover happened to open.
                    DevelopmentTimelineFullscreenView(viewModel: viewModel, sports: sports)
                }
            }
        }
        .tint(VoxtrColor.accent)
        .navigationTitle(viewModel.athleteDisplayName)
        .accessibilityIdentifier("athleteStatistics.root")
        .onAppear {
            loadSportsIfNeeded()
            viewModel.load()
        }
    }

    /// Fullscreen data-ownership round: delegates to `DevelopmentTimelinePoint
    /// .points(from:sports:)`, the ONE shared projection both this
    /// screen and `DevelopmentTimelineFullscreenView` use — never a
    /// second, independently-maintained projection that could diverge.
    private func points(from summary: StatisticsAthleteSummary) -> [DevelopmentTimelinePoint] {
        DevelopmentTimelinePoint.points(from: summary, sports: sports)
    }

    /// "No training in period" (a factual zero state, not an error) and
    /// "filter yields no matching training" render identically here —
    /// both are just `performedActivityCount == 0`, and Form/Sleep keep
    /// showing whatever they actually have (Sleep in particular is
    /// never hidden by a Sport/Activity Type filter — see
    /// `StatisticsWeekBucket.sleep`'s own doc comment).
    private func summaryContent(_ summary: StatisticsAthleteSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(StatisticsFormatting.minutes(summary.totalActualMinutes)) · \(summary.performedActivityCount) activities")
                .font(VoxtrTypography.value)
                .foregroundStyle(VoxtrColor.textPrimary)
                .accessibilityIdentifier("athleteStatistics.trainingSummary")

            if summary.performedActivityCount == 0 {
                Text("No matching training recorded for this period.")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("athleteStatistics.noTrainingNote")
            }
        }
    }

    /// Statistics — Plan vs Actual round: a compact, purely factual
    /// summary — planned duration/count and actual duration/count for
    /// the selected athlete + period + filters. Deliberately plain
    /// "Planned"/"Actual" labels, never "adherence"/"completion rate"/
    /// "target achievement" wording, and no red/green or other
    /// evaluative coloring — this section states what was planned and
    /// what happened, and leaves any judgement to the reader. Always
    /// shown regardless of `viewModel.timelineComparisonMode` (that mode
    /// only changes how the Development Timeline CHART presents this
    /// same already-loaded data — see this round's own approved
    /// contract: "Add Plan vs Actual Statistics presentation," a
    /// standalone requirement distinct from the Timeline's own).
    private func planVsActualContent(_ summary: StatisticsAthleteSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Planned", value: "\(StatisticsFormatting.minutes(summary.plannedMinutes)) · \(summary.plannedActivityCount) activities")
                .accessibilityIdentifier("athleteStatistics.planVsActual.planned")

            LabeledContent("Actual", value: "\(StatisticsFormatting.minutes(summary.totalActualMinutes)) · \(summary.performedActivityCount) activities")
                .accessibilityIdentifier("athleteStatistics.planVsActual.actual")
        }
    }

    /// Review follow-up (PR #24) — locked V1 period contract: quick
    /// rolling choices (Last 4/13/26 Weeks) plus a compact "Month…"
    /// option that reveals a Month/Year sub-picker, never a full
    /// arbitrary custom-date-range picker. The mode Picker's own
    /// selection is DERIVED from `viewModel.period` (via `PeriodModeTag`)
    /// rather than tracked as separate View state, so there is exactly
    /// one source of truth for "what period is selected."
    private var periodPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Period", selection: Binding(
                get: { PeriodModeTag(period: viewModel.period) },
                set: { newTag in
                    switch newTag {
                    case .rolling(let window):
                        viewModel.setPeriod(.rolling(window))
                    case .month:
                        // Entering Month mode for the first time defaults
                        // to the calendar month `today` falls in — the
                        // sub-pickers below then let the user change it.
                        if case .calendarMonth = viewModel.period { return }
                        viewModel.setPeriod(.calendarMonth(year: viewModel.today.year, month: viewModel.today.month))
                    }
                }
            )) {
                ForEach(StatisticsPeriod.RollingWindow.allCases) { window in
                    Text(window.displayName).tag(PeriodModeTag.rolling(window))
                }
                Text("Month…").tag(PeriodModeTag.month)
            }
            .accessibilityIdentifier("athleteStatistics.periodPicker")

            if case .calendarMonth(let year, let month) = viewModel.period {
                monthYearPicker(year: year, month: month)
            }
        }
    }

    /// Review follow-up (PR #24): Month/Year options come from
    /// `StatisticsPeriod`'s own selectable-range functions, never a
    /// hardcoded window — the Year range is a deliberately broad UI
    /// safety bound (see `StatisticsPeriod.selectableCalendarMonthYears`'s
    /// own doc comment), and the Month range excludes any future month
    /// within the current year. Changing the Year to one where the
    /// current Month selection would now be in the future clamps the
    /// Month down (`StatisticsPeriod.clampCalendarMonth`) rather than
    /// leaving an invalid/future selection in place.
    private func monthYearPicker(year: Int, month: Int) -> some View {
        HStack {
            Picker("Month", selection: Binding(
                get: { month },
                set: { viewModel.setPeriod(.calendarMonth(year: year, month: $0)) }
            )) {
                ForEach(StatisticsPeriod.selectableCalendarMonths(forYear: year, today: viewModel.today), id: \.self) { candidateMonth in
                    Text(StatisticsPeriod.monthName(candidateMonth)).tag(candidateMonth)
                }
            }
            .accessibilityIdentifier("athleteStatistics.monthPicker")

            Picker("Year", selection: Binding(
                get: { year },
                set: { newYear in
                    let clampedMonth = StatisticsPeriod.clampCalendarMonth(month, forYear: newYear, today: viewModel.today)
                    viewModel.setPeriod(.calendarMonth(year: newYear, month: clampedMonth))
                }
            )) {
                ForEach(StatisticsPeriod.selectableCalendarMonthYears(today: viewModel.today), id: \.self) { candidateYear in
                    Text(String(candidateYear)).tag(candidateYear)
                }
            }
            .accessibilityIdentifier("athleteStatistics.yearPicker")
        }
    }

    /// Training Breakdown round: "How should Training be visually broken
    /// down?" — a presentation choice, deliberately distinct from the
    /// Sport/Activity Type FILTERS above (`StatisticsFilterMenus`,
    /// which changes what counts) and from `seriesToggles` below
    /// (which series render at all). Bound
    /// directly to `viewModel.trainingBreakdownMode`, the one shared
    /// state `DevelopmentTimelineFullscreenView` also binds to.
    private var breakdownModePicker: some View {
        Picker("Training Breakdown", selection: $viewModel.trainingBreakdownMode) {
            ForEach(TrainingBreakdownMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("athleteStatistics.trainingBreakdownPicker")
    }

    /// Statistics — Plan vs Actual round: "How did reality compare with
    /// plan?" — a presentation choice, deliberately distinct from
    /// `breakdownModePicker` above (see `TimelineComparisonMode`'s own
    /// doc comment). Bound directly to `viewModel.timelineComparisonMode`,
    /// the one shared state `DevelopmentTimelineFullscreenView` also
    /// binds to.
    private var comparisonModePicker: some View {
        Picker("Training View", selection: $viewModel.timelineComparisonMode) {
            ForEach(TimelineComparisonMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("athleteStatistics.timelineComparisonPicker")
    }

    private var seriesToggles: some View {
        HStack(spacing: 12) {
            Toggle("Training", isOn: $viewModel.isTrainingSeriesVisible)
            Toggle("Form", isOn: $viewModel.isFormSeriesVisible)
            Toggle("Sleep", isOn: $viewModel.isSleepSeriesVisible)
        }
        .toggleStyle(.button)
        .font(VoxtrTypography.metadata)
        .accessibilityIdentifier("athleteStatistics.seriesToggles")
    }

    /// Statistics V1 UI (fullscreen Timeline round): the sole entry
    /// point into the fullscreen Development Timeline presentation —
    /// small, calm, and placed alongside the series toggles rather than
    /// added to the shared `VoxtrSectionHeading` (used by every section
    /// header in the app; adding a per-section accessory slot there
    /// would be a wider change than this task's scope). Rotating the
    /// device while still on this normal screen does NOT open
    /// fullscreen — only this explicit action does.
    private var expandTimelineButton: some View {
        Button {
            isShowingFullscreenTimeline = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .accessibilityIdentifier("athleteStatistics.expandTimelineButton")
        .accessibilityLabel("Expand Development Timeline")
    }

    private func loadSportsIfNeeded() {
        guard sports.isEmpty else { return }
        sports = (try? sportRepository.fetchAllSports()) ?? []
    }
}

/// A `Picker`-tag-friendly projection of `StatisticsPeriod`'s two modes
/// — needed only because `.calendarMonth(year:month:)`'s associated
/// values would otherwise make every candidate year/month combination a
/// distinct Picker option; this collapses the whole `.calendarMonth`
/// case to a single "Month…" tag, with the actual year/month chosen by
/// the separate sub-pickers in `monthYearPicker(year:month:)`.
private enum PeriodModeTag: Hashable {
    case rolling(StatisticsPeriod.RollingWindow)
    case month

    init(period: StatisticsPeriod) {
        switch period {
        case .rolling(let window):
            self = .rolling(window)
        case .calendarMonth:
            self = .month
        }
    }
}
