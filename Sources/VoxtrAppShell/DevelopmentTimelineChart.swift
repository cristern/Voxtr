import SwiftUI
import Charts
import VoxtrCoreContracts

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

    public var id: LocalDate { weekStart }

    public init(weekStart: LocalDate, trainingMinutes: Int, formMean: Double?, sleepMean: Double?) {
        self.weekStart = weekStart
        self.trainingMinutes = trainingMinutes
        self.formMean = formMean
        self.sleepMean = sleepMean
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

    public init(points: [DevelopmentTimelinePoint], isTrainingVisible: Bool, isFormVisible: Bool, isSleepVisible: Bool) {
        self.points = points
        self.isTrainingVisible = isTrainingVisible
        self.isFormVisible = isFormVisible
        self.isSleepVisible = isSleepVisible
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
        return (domain, range)
    }

    private var hasAnyVisibleSeries: Bool {
        isTrainingVisible || isFormVisible || isSleepVisible
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasAnyVisibleSeries {
                chart
            } else {
                // No series toggled on: a calm, intentional empty state
                // — never a blank canvas that could read as broken.
                Text("No series selected")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .accessibilityIdentifier("developmentTimeline.noSeriesSelected")
            }

            HStack(spacing: 16) {
                if isTrainingVisible {
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
        }
    }

    private var chart: some View {
        let scale = seriesColorScale
        return Chart {
            if isTrainingVisible {
                ForEach(points) { point in
                    BarMark(
                        x: .value("Week", point.weekStart.isoString),
                        y: .value("Training minutes", point.trainingMinutes)
                    )
                    .foregroundStyle(VoxtrColor.accent)
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
        .frame(height: 220)
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
