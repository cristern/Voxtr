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
                        sportFilterMenu
                        activityTypeFilterMenu
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
                        seriesToggles
                        DevelopmentTimelineChart(
                            points: points(from: summary),
                            isTrainingVisible: viewModel.isTrainingSeriesVisible,
                            isFormVisible: viewModel.isFormSeriesVisible,
                            isSleepVisible: viewModel.isSleepSeriesVisible
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

    private func points(from summary: StatisticsAthleteSummary) -> [DevelopmentTimelinePoint] {
        summary.weeklyBuckets.map { bucket in
            DevelopmentTimelinePoint(
                weekStart: bucket.weekStart,
                trainingMinutes: bucket.totalActualMinutes,
                formMean: bucket.form.mean,
                sleepMean: bucket.sleep.mean
            )
        }
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

    private var periodPicker: some View {
        Picker("Period", selection: Binding(
            get: { viewModel.period },
            set: { viewModel.setPeriod($0) }
        )) {
            ForEach(StatisticsPeriod.allCases) { period in
                Text(period.displayName).tag(period)
            }
        }
        .accessibilityIdentifier("athleteStatistics.periodPicker")
    }

    /// No "No sport" filter option in this V1 UI — `StatisticsFilter
    /// .sportId == nil` already means "no constraint" (every activity
    /// matches, per that type's own doc comment), so it cannot also
    /// mean "only activities with no Sport" without a fragile
    /// workaround. "All Sports" here maps to that same `nil`; a
    /// concrete Sport is the only other option, sourced from the
    /// canonical `SportRepository.fetchAllSports()` list (the same
    /// source/ordering `ActivityIdentityInputView` already uses).
    private var sportFilterMenu: some View {
        Menu {
            Button("All Sports") { viewModel.setSportFilter(nil) }
            if !sports.isEmpty {
                Divider()
                ForEach(sports) { sport in
                    Button(sport.displayName) { viewModel.setSportFilter(sport.sportId) }
                }
            }
        } label: {
            LabeledContent("Sport", value: selectedSportName)
        }
        .accessibilityIdentifier("athleteStatistics.sportFilter")
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
        .accessibilityIdentifier("athleteStatistics.activityTypeFilter")
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

    private func loadSportsIfNeeded() {
        guard sports.isEmpty else { return }
        sports = (try? sportRepository.fetchAllSports()) ?? []
    }
}
