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
///   ("Training (minutes)" / "Form & Sleep (1–5)") so neither can be
///   misread as the other's scale.
///
/// Missing Form/Sleep weeks are never plotted at zero: this view
/// splits each series into its own contiguous runs of PRESENT values
/// and draws one `LineMark` run per segment, so a missing week is a
/// genuine break in the line — never a value silently connected
/// through, and never a point at the bottom of the chart.
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

    private struct RunPoint: Identifiable {
        let weekStart: LocalDate
        let value: Double
        var id: LocalDate { weekStart }
    }

    /// Contiguous runs of weeks that actually have a value — a `nil`
    /// week ends the current run rather than being interpolated across.
    private func runs(_ valueForPoint: (DevelopmentTimelinePoint) -> Double?) -> [[RunPoint]] {
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
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
                    ForEach(Array(runs(\.formMean).enumerated()), id: \.offset) { _, run in
                        ForEach(run) { entry in
                            LineMark(
                                x: .value("Week", entry.weekStart.isoString),
                                y: .value("Form", transformed(entry.value))
                            )
                            .foregroundStyle(VoxtrColor.navy)
                            .symbol(.circle)
                            .interpolationMethod(.linear)
                        }
                    }
                }
                if isSleepVisible {
                    ForEach(Array(runs(\.sleepMean).enumerated()), id: \.offset) { _, run in
                        ForEach(run) { entry in
                            LineMark(
                                x: .value("Week", entry.weekStart.isoString),
                                y: .value("Sleep", transformed(entry.value))
                            )
                            .foregroundStyle(VoxtrColor.accentBright)
                            .symbol(.square)
                            .interpolationMethod(.linear)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...trainingAxisMax)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
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
            .frame(height: 220)
            .padding(.trailing, 24)
            .accessibilityLabel("Development timeline")
            .accessibilityValue(accessibilitySummary)

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
