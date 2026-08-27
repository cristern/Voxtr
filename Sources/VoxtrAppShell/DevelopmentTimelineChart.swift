import SwiftUI
import Charts
import VoxtrCoreContracts
import VoxtrCoreReferenceData

/// Training Breakdown round: one Training category's factual minutes
/// within a single weekly bucket — a plain projection of
/// `SportTrainingMinutes`/`ActivityTypeTrainingMinutes`, already
/// resolved to a display name (Sport/Activity Type reference-data
/// lookup happens where that data is already loaded — `AthleteStatisticsView`
/// — never inside this chart, which owns no repository access).
/// `id` is the STABLE identity key `VoxtrCategoryColor.color(forStableKey:)`
/// keys off — a `SportId`'s UUID string, an `ActivityType`'s raw
/// string, or `TrainingCategorySegment.noSportKey` — never the display
/// name, which is presentation-only and can repeat/localize.
public struct TrainingCategorySegment: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let minutes: Int

    public init(id: String, displayName: String, minutes: Int) {
        self.id = id
        self.displayName = displayName
        self.minutes = minutes
    }

    /// The stable key for a performed activity recorded with no Sport
    /// (`LoggedActivity.sportId == nil`) — a legitimate, factual case
    /// (see `SportTrainingMinutes`'s own doc comment), never a
    /// fabricated Sport identity. Fixed and distinct from any real
    /// `SportId`'s UUID-string form.
    public static let noSportKey = "no-sport"
}

/// One week's plotted values for the Development Timeline — a plain
/// projection of `StatisticsWeekBucket`, never a `@Model` reference.
/// `formMean`/`sleepMean` stay `nil` exactly when that week had no
/// recorded samples (`StatisticsAggregate.mean == nil`) — this type
/// never substitutes a zero.
public struct DevelopmentTimelinePoint: Identifiable, Hashable, Sendable {
    public let weekStart: LocalDate
    public let trainingMinutes: Int
    public let formMean: Double?
    public let sleepMean: Double?
    /// Training Breakdown round: `trainingMinutes`, broken down by
    /// Sport/Activity Type — `[]` on both by default, so every existing
    /// caller/test predating Training Breakdown compiles unchanged and
    /// renders exactly as before (`DevelopmentTimelineChart` only reads
    /// these when its own `breakdownMode` is `.sport`/`.activityType`).
    public let trainingBySport: [TrainingCategorySegment]
    public let trainingByActivityType: [TrainingCategorySegment]

    public var id: LocalDate { weekStart }

    public init(
        weekStart: LocalDate,
        trainingMinutes: Int,
        formMean: Double?,
        sleepMean: Double?,
        trainingBySport: [TrainingCategorySegment] = [],
        trainingByActivityType: [TrainingCategorySegment] = []
    ) {
        self.weekStart = weekStart
        self.trainingMinutes = trainingMinutes
        self.formMean = formMean
        self.sleepMean = sleepMean
        self.trainingBySport = trainingBySport
        self.trainingByActivityType = trainingByActivityType
    }

    /// Fullscreen data-ownership round: the ONE projection from a
    /// loaded `StatisticsAthleteSummary`'s weekly buckets into
    /// chart-ready points — shared by portrait (`AthleteStatisticsView`)
    /// and fullscreen (`DevelopmentTimelineFullscreenView`) so both
    /// render identically from whatever the SAME
    /// `AthleteStatisticsViewModel.loadState` currently holds, never
    /// two independently-maintained projections that could silently
    /// diverge. `sports` is the caller's already-loaded canonical Sport
    /// reference-data list (`SportRepository.fetchAllSports()`) — this
    /// function fetches nothing itself, only resolves a Sport segment's
    /// display label from data already in hand.
    static func points(from summary: StatisticsAthleteSummary, sports: [Sport]) -> [DevelopmentTimelinePoint] {
        summary.weeklyBuckets.map { bucket in
            DevelopmentTimelinePoint(
                weekStart: bucket.weekStart,
                trainingMinutes: bucket.totalActualMinutes,
                formMean: bucket.form.mean,
                sleepMean: bucket.sleep.mean,
                trainingBySport: bucket.trainingBySport.map { segment in
                    TrainingCategorySegment(
                        id: segment.sportId?.rawValue.uuidString ?? TrainingCategorySegment.noSportKey,
                        displayName: sportDisplayName(for: segment.sportId, sports: sports),
                        minutes: segment.minutes
                    )
                },
                trainingByActivityType: bucket.trainingByActivityType.map { segment in
                    TrainingCategorySegment(
                        id: segment.activityType.rawValue,
                        displayName: segment.activityType.displayName,
                        minutes: segment.minutes
                    )
                }
            )
        }
    }

    /// `sportId == nil` means the underlying activity genuinely has no
    /// Sport (see `SportTrainingMinutes`'s own doc comment), a
    /// legitimate case, not an error — "No sport" is calm, factual
    /// presentation text. A non-nil `sportId` that fails to resolve
    /// (deleted/unknown reference data) falls back to "Unknown" rather
    /// than silently dropping the segment's factual minutes.
    private static func sportDisplayName(for sportId: SportId?, sports: [Sport]) -> String {
        guard let sportId else { return "No sport" }
        return sports.first(where: { $0.sportId == sportId })?.displayName ?? "Unknown"
    }
}

/// Statistics V1 UI — Development Timeline, the locked-contract chart:
/// Training as bars on its own minutes axis, Form and Sleep as lines
/// sharing a fixed 1–5 axis, all three independently toggleable.
///
/// TWO-AXIS IMPLEMENTATION CHOICE (see delivery report for the full
/// explanation): Swift Charts (iOS 16+; this app targets iOS 17 — see
/// `Package.swift`) has no native API for two independently-scaled Y
/// axes inside a single `Chart`. Faking a shared axis (plotting Form/
/// Sleep's raw 1–5 values directly against the training-minutes axis)
/// would make one scale silently misread the other — explicitly
/// forbidden by the approved contract. Instead this view uses the
/// standard, honest dual-axis technique:
/// - Training bars plot in their OWN true coordinate space (minutes),
///   using the chart's native leading Y axis.
/// - Form/Sleep values are linearly transformed ONLY for their on-
///   screen Y POSITION — `(value - 1) / (5 - 1) * trainingAxisMax` —
///   into that same minutes-based plotting space. The underlying
///   `formMean`/`sleepMean` values are never altered, only where the
///   mark is drawn; the transform is never applied to anything
///   returned by `StatisticsService`.
/// - A second, manually-drawn trailing axis (fixed "5"–"1" labels, one
///   per unit, evenly spaced to match the linear transform above) is
///   overlaid via `.chartOverlay`, so a Form/Sleep line's vertical
///   position reads as its TRUE 1–5 value, never the training-minutes
///   number underneath it. Both axes carry an explicit caption
///   ("Training (minutes)" / "Form (1–5)" / "Sleep (1–5)") in the
///   legend below, so neither scale can be misread as the other's.
///
/// Review follow-up (PR #24), axis visibility: each axis follows its
/// OWN series toggles, never showing a scale for data that isn't on
/// screen — the leading minutes axis only when Training is visible, the
/// trailing 1–5 axis only when Form and/or Sleep is visible. The
/// underlying `chartYScale` plotting domain stays fixed regardless
/// (Form/Sleep's transform needs a consistent coordinate space to
/// position against even when Training's bars aren't drawn) — only the
/// visible TICK LABELS are conditional, never the math.
///
/// Review follow-up (PR #24), missing-value line gaps: a missing Form/
/// Sleep week is never plotted at zero, and the fix here goes one step
/// further than v1 — every contiguous run of PRESENT values gets its
/// OWN explicit series identity via `.foregroundStyle(by:)` (a
/// `"form-<runIndex>"`/`"sleep-<runIndex>"` key), which is what
/// actually tells Swift Charts not to connect across a gap week — mark
/// ORDER/Swift-loop-nesting alone does not (Swift Charts groups marks
/// into one connected series by their shared value label, regardless of
/// how the drawing code is structured). Every run's key is mapped to
/// the SAME single color via `.chartForegroundStyleScale`, and the
/// chart's own auto-generated legend (which would otherwise show one
/// noisy entry per run) is hidden — the legend below this chart is the
/// only one shown.
public struct DevelopmentTimelineChart: View {
    public let points: [DevelopmentTimelinePoint]
    public let isTrainingVisible: Bool
    public let isFormVisible: Bool
    public let isSleepVisible: Bool
    /// Review follow-up (time-axis round 2): the SAME `StatisticsAthleteSummary
    /// .intervalStart`/`.intervalEnd` the loaded summary already exposes —
    /// the authoritative selected Statistics interval, per `StatisticsPeriod
    /// .interval(today:)`. Passed straight through from
    /// `AthleteStatisticsView` rather than re-derived here, so this chart
    /// never becomes a second owner of period/interval truth (One Truth:
    /// `StatisticsPeriod` proposes the interval, `StatisticsService`
    /// returns it, this Timeline only presents it). Used only for the
    /// year-context label and for clamping a partial leading bucket's
    /// DISPLAYED date — never to alter `points`/bucket data itself.
    public let intervalStart: LocalDate
    public let intervalEnd: LocalDate
    /// Statistics V1 UI (fullscreen Timeline round): the chart's own
    /// plotted height. Defaults to the original, unchanged `240` every
    /// existing embedded-in-`List` call site already renders at — this
    /// parameter exists ONLY so the fullscreen Development Timeline
    /// presentation can request a taller chart from the SAME reusable
    /// component (more available vertical space, especially in
    /// landscape) without forking the bar/line/axis drawing logic into
    /// a second, independently-maintained chart implementation.
    public let chartHeight: CGFloat
    /// Training Breakdown round: which lens Training's bars render
    /// through. `.total` is byte-for-byte the original single-bar
    /// rendering (untouched code path) — `.sport`/`.activityType` stack
    /// each week's bar by `point.trainingBySport`/`.trainingByActivityType`
    /// instead. Never affects Form/Sleep, the Y-scale, or any other
    /// existing chart contract.
    public let breakdownMode: TrainingBreakdownMode

    public init(
        points: [DevelopmentTimelinePoint],
        isTrainingVisible: Bool,
        isFormVisible: Bool,
        isSleepVisible: Bool,
        intervalStart: LocalDate,
        intervalEnd: LocalDate,
        chartHeight: CGFloat = 240,
        breakdownMode: TrainingBreakdownMode = .total
    ) {
        self.points = points
        self.isTrainingVisible = isTrainingVisible
        self.isFormVisible = isFormVisible
        self.isSleepVisible = isSleepVisible
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.chartHeight = chartHeight
        self.breakdownMode = breakdownMode
    }

    private static let scaleMin: Double = 1
    private static let scaleMax: Double = 5

    /// Never degenerate (a chart with a 0-height training axis when
    /// every visible week is genuinely zero would also collapse the
    /// Form/Sleep transform below to zero) — floored to a calm minimum.
    private var trainingAxisMax: Double {
        Double(max(points.map(\.trainingMinutes).max() ?? 0, 60))
    }

    private func transformed(_ value: Double) -> Double {
        (value - Self.scaleMin) / (Self.scaleMax - Self.scaleMin) * trainingAxisMax
    }

    /// One present (week, value) pair within a contiguous run.
    /// Deliberately not `private` — exposed (at the default `internal`
    /// level) so `contiguousRuns(_:value:)` below is directly testable
    /// via `@testable import`, with no View instantiation/rendering
    /// required.
    struct RunPoint: Identifiable, Equatable {
        let weekStart: LocalDate
        let value: Double
        var id: LocalDate { weekStart }
    }

    /// Pure, UI-independent run segmentation: splits `points` into
    /// contiguous runs of weeks that actually have a value — a week
    /// with no value (`valueForPoint` returns `nil`) ends the current
    /// run rather than being interpolated across. `static` and
    /// `internal` (not `private`) for the same testability reason as
    /// `RunPoint` above.
    static func contiguousRuns(
        _ points: [DevelopmentTimelinePoint],
        value valueForPoint: (DevelopmentTimelinePoint) -> Double?
    ) -> [[RunPoint]] {
        var result: [[RunPoint]] = []
        var current: [RunPoint] = []
        for point in points {
            if let value = valueForPoint(point) {
                current.append(RunPoint(weekStart: point.weekStart, value: value))
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private var formRuns: [[RunPoint]] { Self.contiguousRuns(points, value: \.formMean) }
    private var sleepRuns: [[RunPoint]] { Self.contiguousRuns(points, value: \.sleepMean) }

    // MARK: - Training Breakdown

    /// The category segments for one point under the CURRENT
    /// `breakdownMode` — `[]` for `.total` (that mode never stacks;
    /// see the `chart` property below), `point.trainingBySport`/
    /// `.trainingByActivityType` otherwise. Pure selection only, no
    /// aggregation: both arrays already come fully computed from
    /// `AthleteStatisticsView`'s projection of the Statistics read
    /// model.
    private func categorySegments(for point: DevelopmentTimelinePoint) -> [TrainingCategorySegment] {
        switch breakdownMode {
        case .total: return []
        case .sport: return point.trainingBySport
        case .activityType: return point.trainingByActivityType
        }
    }

    /// Every category actually present anywhere in `points` under the
    /// current `breakdownMode`, deduplicated by stable `id` and kept in
    /// first-seen (chronological) order — never the full canonical
    /// Sport/Activity Type catalog. Empty whenever `breakdownMode ==
    /// .total` or Training has no minutes anywhere in the currently
    /// displayed data, which is exactly when the category legend and
    /// the training portion of `seriesColorScale` below both stay
    /// empty too.
    private var presentCategories: [TrainingCategorySegment] {
        guard breakdownMode != .total else { return [] }
        var seenIds = Set<String>()
        var result: [TrainingCategorySegment] = []
        for point in points {
            for segment in categorySegments(for: point) where !seenIds.contains(segment.id) {
                seenIds.insert(segment.id)
                result.append(segment)
            }
        }
        return result
    }

    // MARK: - Time-axis readability (year context + week/date rows)

    /// "2026" for a selected interval entirely within one calendar
    /// year, "2025 – 2026" when the SELECTED INTERVAL itself genuinely
    /// spans a year boundary. Derived from `intervalStart`/`intervalEnd`
    /// (the authoritative selected Statistics interval), never from a
    /// bucket's own canonical `weekStart` — a calendar-month period's
    /// partial leading bucket can start in the preceding month (and
    /// occasionally the preceding year, e.g. January), but the
    /// SELECTED PERIOD itself contains no dates from that adjacent
    /// year, so the year context must not claim it does.
    static func yearContextLabel(intervalStart: LocalDate, intervalEnd: LocalDate) -> String {
        intervalStart.year == intervalEnd.year
            ? "\(intervalStart.year)"
            : "\(intervalStart.year) – \(intervalEnd.year)"
    }

    /// The DISPLAYED calendar date for a bucket's date label — the
    /// first date of that bucket that actually falls within the
    /// selected interval. Equal to `point.weekStart` for every normal,
    /// fully-in-interval bucket (including every rolling-window
    /// bucket, whose own `intervalStart` already IS the first bucket's
    /// `weekStart`); only a calendar-month period's partial LEADING
    /// bucket (whose canonical Monday precedes the selected month's
    /// first day) is ever actually clamped forward. Never changes
    /// `point.weekStart` itself or any other bucket data — presentation
    /// only. The WEEK NUMBER label stays derived from the canonical,
    /// unclamped `point.weekStart` (see `weekNumberLabel` below) — only
    /// the calendar-date text is clamped.
    static func displayDate(for point: DevelopmentTimelinePoint, intervalStart: LocalDate) -> LocalDate {
        max(point.weekStart, intervalStart)
    }

    /// Which bucket INDICES (into `points`, in order) get an x-axis
    /// label — a purely presentational readability choice, never a
    /// second period/bucket calculation: `points` and their order are
    /// taken exactly as already computed by `StatisticsService`/
    /// `StatisticsPeriod`. Every calendar-month period spans 4, 5, or 6
    /// canonical weeks (verified against every month/weekday-start
    /// combination) and "Last 4 Weeks" is always exactly 4, so `<= 6`
    /// safely covers both without needing to know which period type
    /// produced `points` — only the fixed 13/26-week rolling windows
    /// exceed that count, and use progressively reduced, regular
    /// density (per the approved contract's own "approximately every
    /// Nth bucket" wording — a readability target, not an exact
    /// requirement). Anchored on the FINAL bucket and walked backward
    /// by the stride, then reversed into ascending order — this always
    /// includes the final bucket as part of the SAME regular spacing
    /// (never as a separately-appended extra label, which previously
    /// produced two adjacent labels at the right edge for the 26-week
    /// case).
    static func labeledIndices(bucketCount: Int) -> [Int] {
        guard bucketCount > 0 else { return [] }
        let labelStride: Int
        switch bucketCount {
        case ...6: labelStride = 1
        case ...13: labelStride = 2
        default: labelStride = 4
        }
        var indices = Swift.stride(from: bucketCount - 1, through: 0, by: -labelStride).map { $0 }
        indices.reverse()
        return indices
    }

    /// "W23" — reuses `WeekIdentityFormatter.weekNumber(forWeekStart:)`,
    /// the one canonical, locale-independent week-numbering scheme
    /// this app already establishes, never a second/competing one.
    /// Always derived from the canonical `weekStart`, never the
    /// interval-clamped `displayDate(for:intervalStart:)`.
    static func weekNumberLabel(for weekStart: LocalDate) -> String {
        "W\(WeekIdentityFormatter.weekNumber(forWeekStart: weekStart))"
    }

    private var labeledPoints: [DevelopmentTimelinePoint] {
        let indices = Set(Self.labeledIndices(bucketCount: points.count))
        return points.enumerated().compactMap { indices.contains($0.offset) ? $0.element : nil }
    }

    private var labeledPointsByIsoString: [String: DevelopmentTimelinePoint] {
        Dictionary(uniqueKeysWithValues: labeledPoints.map { ($0.weekStart.isoString, $0) })
    }

    /// Every `.foregroundStyle(by:)` series key this chart can draw,
    /// mapped to its metric's single color — built fresh from the
    /// CURRENT run counts (never a fixed-size table), so
    /// `.chartForegroundStyleScale` always covers exactly the series
    /// actually drawn, however many gap-separated runs that turns out
    /// to be for this athlete/period.
    private var seriesColorScale: (domain: [String], range: [Color]) {
        var domain: [String] = []
        var range: [Color] = []
        for index in formRuns.indices {
            domain.append("form-\(index)")
            range.append(VoxtrColor.navy)
        }
        for index in sleepRuns.indices {
            domain.append("sleep-\(index)")
            range.append(VoxtrColor.accentBright)
        }
        // Training Breakdown round: only added when actually stacking —
        // `.total` keeps using its own direct `.foregroundStyle(VoxtrColor
        // .accent)` (see `chart` below), which is entirely independent of
        // this categorical scale, exactly as before this round.
        for category in presentCategories {
            domain.append(Self.trainingSeriesKey(for: category.id))
            range.append(VoxtrCategoryColor.color(forStableKey: category.id))
        }
        return (domain, range)
    }

    /// Namespaces a Training category's stable ID into this chart's ONE
    /// shared `foregroundStyle(by:)` series-key space, alongside the
    /// pre-existing `"form-<n>"`/`"sleep-<n>"` keys — guarantees a
    /// Training category's key can never collide with a Form/Sleep run
    /// key. Purely an internal Swift Charts series-identity detail: the
    /// deterministic COLOUR mapping itself (`VoxtrCategoryColor
    /// .color(forStableKey:)`) always operates on the category's own
    /// unprefixed `id`, never this namespaced form.
    private static func trainingSeriesKey(for categoryId: String) -> String {
        "training-\(categoryId)"
    }

    private var hasAnyVisibleSeries: Bool {
        isTrainingVisible || isFormVisible || isSleepVisible
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.yearContextLabel(intervalStart: intervalStart, intervalEnd: intervalEnd))
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("developmentTimeline.yearContext")

            if hasAnyVisibleSeries {
                chart
            } else {
                // No series toggled on: a calm, intentional empty state
                // — never a blank canvas that could read as broken.
                Text("No series selected")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: chartHeight)
                    .accessibilityIdentifier("developmentTimeline.noSeriesSelected")
            }

            HStack(spacing: 16) {
                if isTrainingVisible && breakdownMode == .total {
                    legendEntry(color: VoxtrColor.accent, label: "Training (minutes)")
                }
                if isFormVisible {
                    legendEntry(color: VoxtrColor.navy, label: "Form (1–5)")
                }
                if isSleepVisible {
                    legendEntry(color: VoxtrColor.accentBright, label: "Sleep (1–5)")
                }
            }
            .font(VoxtrTypography.caption)
            .foregroundStyle(VoxtrColor.textSecondary)

            // Training Breakdown round: a SEPARATE legend for the
            // Training category colours themselves — only relevant (and
            // only shown) once Training is stacked by Sport/Activity
            // Type, and only ever lists categories actually present in
            // the currently displayed/filtered data, never the full
            // canonical Sport/Activity Type catalog. Wraps to multiple
            // lines rather than truncating or scrolling — the category
            // count is data-dependent and unbounded in principle.
            if isTrainingVisible, breakdownMode != .total, !presentCategories.isEmpty {
                FlowLayout(spacing: 12) {
                    ForEach(presentCategories) { category in
                        legendEntry(color: VoxtrCategoryColor.color(forStableKey: category.id), label: category.displayName)
                    }
                }
                .font(VoxtrTypography.caption)
                .foregroundStyle(VoxtrColor.textSecondary)
                .accessibilityIdentifier("developmentTimeline.categoryLegend")
            }
        }
    }

    private var chart: some View {
        let scale = seriesColorScale
        return Chart {
            if isTrainingVisible {
                if breakdownMode == .total {
                    // Unchanged from before Training Breakdown existed —
                    // the exact same single BarMark per week, direct
                    // colour, no categorical scale involvement.
                    ForEach(points) { point in
                        BarMark(
                            x: .value("Week", point.weekStart.isoString),
                            y: .value("Training minutes", point.trainingMinutes)
                        )
                        .foregroundStyle(VoxtrColor.accent)
                    }
                } else {
                    // Swift Charts stacks multiple BarMarks sharing the
                    // same x natively — one mark per present category per
                    // week, each segment's own height is its own factual
                    // minutes, so the stack's total height equals the
                    // SAME `point.trainingMinutes` Total mode draws
                    // (minute conservation is guaranteed at the read-
                    // model layer — see `StatisticsWeekBucket`'s own doc
                    // comment — never re-summed or re-derived here).
                    ForEach(points) { point in
                        ForEach(categorySegments(for: point)) { segment in
                            BarMark(
                                x: .value("Week", point.weekStart.isoString),
                                y: .value("Training minutes", segment.minutes)
                            )
                            .foregroundStyle(by: .value("Series", Self.trainingSeriesKey(for: segment.id)))
                            .accessibilityLabel(segment.displayName)
                            .accessibilityValue("\(segment.minutes) minutes")
                        }
                    }
                }
            }
            if isFormVisible {
                ForEach(Array(formRuns.enumerated()), id: \.offset) { runIndex, run in
                    ForEach(run) { entry in
                        LineMark(
                            x: .value("Week", entry.weekStart.isoString),
                            y: .value("Form", transformed(entry.value))
                        )
                        .foregroundStyle(by: .value("Series", "form-\(runIndex)"))
                        .symbol(.circle)
                        .interpolationMethod(.linear)
                    }
                }
            }
            if isSleepVisible {
                ForEach(Array(sleepRuns.enumerated()), id: \.offset) { runIndex, run in
                    ForEach(run) { entry in
                        LineMark(
                            x: .value("Week", entry.weekStart.isoString),
                            y: .value("Sleep", transformed(entry.value))
                        )
                        .foregroundStyle(by: .value("Series", "sleep-\(runIndex)"))
                        .symbol(.square)
                        .interpolationMethod(.linear)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...trainingAxisMax)
        .chartYAxis {
            if isTrainingVisible {
                AxisMarks(position: .leading)
            }
        }
        .chartXAxis {
            // Time-axis readability round: replaces Swift Charts'
            // default single-line axis (raw ISO date strings, hard to
            // scan) with a two-line "week number / calendar date"
            // label at a density-selected subset of buckets
            // (`labeledPoints`) — year context is shown separately
            // above the chart (`yearContextLabel`), so it is
            // deliberately NOT repeated here. Using the native
            // `AxisMarks(values:)` mechanism (rather than a hand-built
            // parallel row of Text views) guarantees these labels stay
            // pixel-aligned to the actual bucket positions Swift
            // Charts itself computes.
            AxisMarks(values: labeledPoints.map { $0.weekStart.isoString }) { value in
                AxisValueLabel {
                    if let iso = value.as(String.self), let point = labeledPointsByIsoString[iso] {
                        let clampedDate = Self.displayDate(for: point, intervalStart: intervalStart)
                        VStack(spacing: 2) {
                            Text(Self.weekNumberLabel(for: point.weekStart))
                            Text(WeekIdentityFormatter.shortDateLabel(for: clampedDate))
                        }
                        .font(VoxtrTypography.caption)
                        .foregroundStyle(VoxtrColor.textSecondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if isFormVisible || isSleepVisible {
                    let plotFrame = geometry[proxy.plotAreaFrame]
                    VStack {
                        ForEach((Int(Self.scaleMin)...Int(Self.scaleMax)).reversed(), id: \.self) { tick in
                            Text("\(tick)")
                                .font(VoxtrTypography.caption)
                                .foregroundStyle(VoxtrColor.textSecondary)
                            if tick != Int(Self.scaleMin) {
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(width: 16, height: plotFrame.height)
                    .position(x: plotFrame.maxX + 12, y: plotFrame.midY)
                }
            }
        }
        .frame(height: chartHeight)
        .padding(.trailing, 24)
        .accessibilityLabel("Development timeline")
        .accessibilityValue(accessibilitySummary)
    }

    private func legendEntry(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    /// A single textual summary for VoiceOver — every week's exact
    /// value is still available via the underlying Statistics data
    /// elsewhere on screen (Form/Sleep summaries, training total); this
    /// is a calm, at-a-glance description of the chart itself, not a
    /// substitute for per-point navigation.
    private var accessibilitySummary: String {
        let totalMinutes = points.reduce(0) { $0 + $1.trainingMinutes }
        let formValues = points.compactMap(\.formMean)
        let sleepValues = points.compactMap(\.sleepMean)
        var parts: [String] = ["\(points.count) weeks"]
        if isTrainingVisible {
            parts.append("\(totalMinutes) total training minutes")
            if breakdownMode != .total {
                let categoryCount = presentCategories.count
                let breakdownLabel = breakdownMode == .sport ? "Sport" : "Activity Type"
                parts.append("broken down by \(breakdownLabel) into \(categoryCount) \(categoryCount == 1 ? "category" : "categories")")
            }
        }
        if isFormVisible {
            parts.append(formValues.isEmpty ? "no Form data" : "Form recorded in \(formValues.count) weeks")
        }
        if isSleepVisible {
            parts.append(sleepValues.isEmpty ? "no Sleep data" : "Sleep recorded in \(sleepValues.count) weeks")
        }
        return parts.joined(separator: ", ")
    }
}

/// Training Breakdown round: a minimal, presentation-only wrapping row
/// — used only for the Training category legend, whose item count is
/// data-dependent (as many Sport/Activity Type categories as are
/// actually present) and can exceed one line's width. Standard SwiftUI
/// `Layout` (iOS 16+, this app targets 17+), not a general-purpose
/// layout library — the smallest correct tool for "wrap to the next
/// line," avoiding both a truncating fixed `HStack` and unnecessary
/// horizontal-scroll complexity.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
