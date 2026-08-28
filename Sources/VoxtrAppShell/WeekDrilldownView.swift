import SwiftUI
import VoxtrCoreContracts
import VoxtrCoreReferenceData

/// Week Drilldown round: the factual explanation of ONE canonical
/// Statistics week — "what actually happened," never why. Reads
/// exclusively through `WeekDrilldownViewModel`/`StatisticsWeekDetail`
/// (never `PlanningRepository`/`TrainingRepository` directly), and owns
/// no filter controls of its own: it inherits the exact Sport/Activity
/// Type filter snapshot the parent Statistics screen was showing when
/// the user opened this week (see `WeekDrilldownViewModel`'s own doc
/// comment) — Week Drilldown is never a second, independent filter
/// owner. No score, no adherence/completion percentage, no red/green
/// judgement, no heuristic pairing between Planned and Performed rows —
/// two separate factual lists, per the approved V1 contract.
public struct WeekDrilldownView: View {
    @State private var viewModel: WeekDrilldownViewModel
    private let sports: [Sport]

    @Environment(\.dismiss) private var dismiss

    public init(viewModel: WeekDrilldownViewModel, sports: [Sport]) {
        _viewModel = State(initialValue: viewModel)
        self.sports = sports
    }

    public var body: some View {
        NavigationStack {
            content
                .voxtrScreenBackground()
                .navigationTitle("Week Drilldown")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .tint(VoxtrColor.accent)
        .accessibilityIdentifier("weekDrilldown.root")
        .onAppear {
            viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("weekDrilldown.loadingIndicator")
        case .failed:
            ContentUnavailableView(
                "Couldn't load this week",
                systemImage: "exclamationmark.triangle",
                description: Text("Try again in a moment.")
            )
            .accessibilityIdentifier("weekDrilldown.errorState")
        case .loaded(let detail):
            List {
                Section {
                    Text(WeekIdentityFormatter.stableIdentityLabel(forWeekStart: detail.weekStart))
                        .font(VoxtrTypography.cardTitle)
                        .foregroundStyle(VoxtrColor.textPrimary)
                        .accessibilityIdentifier("weekDrilldown.weekIdentity")
                }
                .voxtrRowSurface()

                Section {
                    LabeledContent(
                        "Planned",
                        value: "\(StatisticsFormatting.minutes(detail.plannedMinutes)) · \(detail.plannedActivityCount) activities"
                    )
                    .accessibilityIdentifier("weekDrilldown.planned")

                    LabeledContent(
                        "Actual",
                        value: "\(StatisticsFormatting.minutes(detail.totalActualMinutes)) · \(detail.performedActivityCount) activities"
                    )
                    .accessibilityIdentifier("weekDrilldown.actual")
                } header: {
                    VoxtrSectionHeading("Plan vs Actual")
                }
                .voxtrRowSurface()

                Section {
                    if detail.plannedActivities.isEmpty {
                        Text("No planned training in this week.")
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                            .accessibilityIdentifier("weekDrilldown.plannedEmptyState")
                    } else {
                        ForEach(detail.plannedActivities) { row in
                            plannedRow(row)
                                .accessibilityIdentifier("weekDrilldown.plannedRow.\(row.plannedActivityId.rawValue.uuidString)")
                        }
                    }
                } header: {
                    VoxtrSectionHeading("Planned")
                }
                .voxtrRowSurface()

                Section {
                    if detail.performedActivities.isEmpty {
                        Text("No performed training in this week.")
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                            .accessibilityIdentifier("weekDrilldown.performedEmptyState")
                    } else {
                        ForEach(detail.performedActivities) { row in
                            performedRow(row)
                                .accessibilityIdentifier("weekDrilldown.performedRow.\(row.loggedActivityId.rawValue.uuidString)")
                        }
                    }
                } header: {
                    VoxtrSectionHeading("Performed")
                }
                .voxtrRowSurface()

                Section {
                    LabeledContent("Form", value: aggregateSummary(detail.form, unit: "response", pluralUnit: "responses"))
                        .accessibilityIdentifier("weekDrilldown.formSummary")
                    LabeledContent("Sleep", value: aggregateSummary(detail.sleep, unit: "night", pluralUnit: "nights"))
                        .accessibilityIdentifier("weekDrilldown.sleepSummary")
                } header: {
                    VoxtrSectionHeading("Form & Sleep")
                }
                .voxtrRowSurface()

                // Weekly Reflection Context round: the section is omitted
                // entirely — not shown with an empty state — when
                // `weeklyReflection` is nil. That covers BOTH "nothing
                // recorded yet" and "recorded but not visible to Parent
                // Statistics" identically (see `StatisticsService
                // .isVisibleToParentStatistics`'s own doc comment) —
                // Statistics never prompts the athlete to reflect, and
                // never discloses that a private reflection exists.
                if let reflection = detail.weeklyReflection {
                    Section {
                        if let overallSatisfaction = reflection.overallSatisfaction {
                            LabeledContent("Overall satisfaction", value: "\(overallSatisfaction) / 5")
                                .accessibilityLabel("Overall satisfaction, \(overallSatisfaction) out of 5")
                                .accessibilityIdentifier("weekDrilldown.reflection.overallSatisfaction")
                        }
                        if let loadFelt = reflection.loadFelt {
                            LabeledContent("Load felt", value: "\(loadFelt) / 5")
                                .accessibilityLabel("Load felt, \(loadFelt) out of 5")
                                .accessibilityIdentifier("weekDrilldown.reflection.loadFelt")
                        }
                        if let whatWorked = reflection.whatWorked, !whatWorked.isEmpty {
                            reflectionTextRow(title: "What worked", text: whatWorked)
                                .accessibilityIdentifier("weekDrilldown.reflection.whatWorked")
                        }
                        if let whatWasDifficult = reflection.whatWasDifficult, !whatWasDifficult.isEmpty {
                            reflectionTextRow(title: "What was difficult", text: whatWasDifficult)
                                .accessibilityIdentifier("weekDrilldown.reflection.whatWasDifficult")
                        }
                        if let learning = reflection.learning, !learning.isEmpty {
                            reflectionTextRow(title: "Learning", text: learning)
                                .accessibilityIdentifier("weekDrilldown.reflection.learning")
                        }
                        if let nextWeekConsideration = reflection.nextWeekConsideration, !nextWeekConsideration.isEmpty {
                            reflectionTextRow(title: "Next week", text: nextWeekConsideration)
                                .accessibilityIdentifier("weekDrilldown.reflection.nextWeekConsideration")
                        }
                    } header: {
                        // Deliberately neutral — "Weekly Reflection," never
                        // a Sport-scoped label — a `WeeklyReflection` is
                        // week-level and is never filtered by the Sport/
                        // Activity Type filter this drilldown inherited
                        // (see `StatisticsService.weekDetail`'s own doc
                        // comment for the same rule already established
                        // for the Sleep aggregate).
                        VoxtrSectionHeading("Weekly Reflection")
                    } footer: {
                        if isPartialReflectionWeek(detail) {
                            Text("Reflects the full week, even though this view covers only part of it.")
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                                .accessibilityIdentifier("weekDrilldown.reflection.partialWeekNote")
                        }
                    }
                    .voxtrRowSurface()
                }
            }
            .voxtrScreenBackground()
        }
    }

    /// The SAME title-or-Sport fallback rule `ActivityLabelResolver`
    /// already establishes elsewhere in this app (`ActivityIdentity
    /// .normalizedName`, then a resolved Sport label, then a generic
    /// "Activity" fallback) — never a second, independently-invented
    /// rule. Implemented directly here rather than via
    /// `ActivityLabelResolver(customSportLookup:)`: that initializer
    /// requires a `@Sendable` closure, and `sports: [Sport]` is a
    /// `@Model`-backed array — not `Sendable` — so capturing it there
    /// would not compile under this package's Swift 6 strict-concurrency
    /// mode. `sports` is the caller's already-loaded canonical Sport
    /// catalog (the SAME one `AthleteStatisticsView`/`DevelopmentTimelineChart`
    /// already use via `DevelopmentTimelinePoint.points(from:sports:)`)
    /// — this view never queries `SportRepository` itself.
    private func sportDisplayName(for sportId: SportId?) -> String? {
        guard let sportId else { return nil }
        return sports.first(where: { $0.sportId == sportId })?.displayName
    }

    private func primaryLabel(title: String?, sportId: SportId?) -> String {
        if let normalized = ActivityIdentity.normalizedName(title) {
            return normalized
        }
        if let sportLabel = sportDisplayName(for: sportId) {
            return sportLabel
        }
        return "Activity"
    }

    private func metadataLabel(title: String?, sportId: SportId?, activityType: ActivityType) -> String {
        if ActivityIdentity.normalizedName(title) != nil, let sportLabel = sportDisplayName(for: sportId) {
            return "\(sportLabel) · \(activityType.displayName)"
        }
        return activityType.displayName
    }

    private func plannedRow(_ row: StatisticsPlannedActivityRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primaryLabel(title: row.title, sportId: row.sportId))
                .font(VoxtrTypography.cardTitle)
                .foregroundStyle(VoxtrColor.textPrimary)
            Text(plannedRowMetadata(row))
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
        }
    }

    /// Sport/Activity Type, then the planned duration IF the canonical
    /// `PlannedActivity` actually recorded one — never a fabricated
    /// value when `plannedDurationMinutes == nil` (the row still shows,
    /// just without a duration clause).
    private func plannedRowMetadata(_ row: StatisticsPlannedActivityRow) -> String {
        let base = metadataLabel(title: row.title, sportId: row.sportId, activityType: row.activityType)
        guard let plannedDurationMinutes = row.plannedDurationMinutes else { return base }
        return "\(base) · \(StatisticsFormatting.minutes(plannedDurationMinutes))"
    }

    private func performedRow(_ row: StatisticsPerformedActivityRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primaryLabel(title: row.title, sportId: row.sportId))
                .font(VoxtrTypography.cardTitle)
                .foregroundStyle(VoxtrColor.textPrimary)
            Text("\(metadataLabel(title: row.title, sportId: row.sportId, activityType: row.activityType)) · \(StatisticsFormatting.minutes(row.durationMinutes))")
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
        }
    }

    /// "3.8 · 3 responses" when samples exist, "No data" when they
    /// don't — missing Form/Sleep is never shown as a fabricated zero,
    /// matching `StatisticsFormatting.average`'s own established
    /// contract.
    private func aggregateSummary(_ aggregate: StatisticsAggregate, unit: String, pluralUnit: String) -> String {
        guard let mean = aggregate.mean else { return "No data" }
        let unitLabel = aggregate.sampleCount == 1 ? unit : pluralUnit
        return "\(StatisticsFormatting.average(mean)) · \(aggregate.sampleCount) \(unitLabel)"
    }

    /// One free-text Reflection field: the label, then the athlete's own
    /// text shown verbatim — no truncation, no summarization, no
    /// sentiment/keyword analysis. Only ever called for an already
    /// non-empty string (see each call site's own `if let ..., !isEmpty`
    /// guard).
    private func reflectionTextRow(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            Text(text)
                .font(VoxtrTypography.cardTitle)
                .foregroundStyle(VoxtrColor.textPrimary)
        }
    }

    /// True when this drilldown's selected Statistics period only covers
    /// part of the Reflection's own full canonical week (a calendar-month
    /// period's leading/trailing edge week — see `StatisticsService
    /// .weekDetail`'s own EFFECTIVE INTERVAL doc comment). Drives a
    /// single, calm footer note so the distinction is clear without
    /// over-explaining it — never a warning, never a second Plan/Actual/
    /// Form-style interval label.
    private func isPartialReflectionWeek(_ detail: StatisticsWeekDetail) -> Bool {
        detail.intervalStart != detail.weekStart || detail.intervalEnd != detail.weekStart.adding(days: 6)
    }
}
