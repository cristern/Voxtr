import Testing
import Foundation
import VoxtrCoreContracts
@testable import VoxtrAppShell

/// Statistics — Trend View round: pure, UI-independent tests for
/// `DevelopmentTimelineTrendProjector.points(from:)` — no View
/// instantiation/rendering, no persistence, no Statistics fetch
/// involved. Exercises exactly the deterministic rolling-average rules
/// the approved contract specifies.
@Suite("DevelopmentTimelineTrendProjector")
struct DevelopmentTimelineTrendProjectorTests {
    private static func point(_ day: Int, minutes: Int, form: Double? = nil, sleep: Double? = nil) -> DevelopmentTimelinePoint {
        DevelopmentTimelinePoint(
            weekStart: LocalDate(year: 2026, month: 3, day: day),
            trainingMinutes: minutes,
            formMean: form,
            sleepMean: sleep
        )
    }

    /// Required test 1: the approved contract's own worked example —
    /// progressive window for the first 3 weeks, full trailing 4-week
    /// window from week 4 onward.
    @Test("Training: 4-week rolling average with a progressive window for the first 3 weeks")
    func trainingProgressiveWindowMatchesApprovedExample() {
        let points = [Self.point(2, minutes: 100), Self.point(9, minutes: 0), Self.point(16, minutes: 80), Self.point(23, minutes: 60)]
        let trend = DevelopmentTimelineTrendProjector.points(from: points)
        #expect(trend.map(\.trainingTrendMinutes) == [100, 50, 60, 60])
    }

    /// Required test 2: a 5th week's trend drops the oldest (week 1)
    /// bucket from its trailing 4-week window.
    @Test("Training: a 5th week uses a trailing window that drops the oldest bucket")
    func trainingFifthWeekDropsOldestBucket() {
        let points = [
            Self.point(2, minutes: 100), Self.point(9, minutes: 0), Self.point(16, minutes: 80),
            Self.point(23, minutes: 60), Self.point(30, minutes: 160),
        ]
        let trend = DevelopmentTimelineTrendProjector.points(from: points)
        #expect(trend.count == 5)
        #expect(trend.last?.trainingTrendMinutes == 75) // (0 + 80 + 60 + 160) / 4
    }

    /// Required test 3: a genuine zero-training week is a real,
    /// participating value — never excluded as if it were missing.
    @Test("Training: a genuine zero-training week participates in the average, never excluded")
    func trainingZeroParticipatesInAverage() {
        let points = [Self.point(2, minutes: 0), Self.point(9, minutes: 0)]
        let trend = DevelopmentTimelineTrendProjector.points(from: points)
        #expect(trend.map(\.trainingTrendMinutes) == [0, 0])
    }

    /// Required test 4: a missing weekly Form value contributes nothing
    /// to the rolling mean — never treated as zero.
    @Test("Form: a missing weekly value is excluded from the mean, never treated as zero")
    func formMissingIsExcludedNeverZero() {
        let points = [
            Self.point(2, minutes: 0, form: 4), Self.point(9, minutes: 0, form: nil),
            Self.point(16, minutes: 0, form: 2), Self.point(23, minutes: 0, form: nil),
        ]
        let trend = DevelopmentTimelineTrendProjector.points(from: points)
        // Window at index 2 = [4, nil, 2] -> mean of [4, 2] = 3, not (4+0+2)/3.
        #expect(trend[2].formTrendMean == 3)
        // Window at index 3 = [4, nil, 2, nil] -> still just [4, 2] = 3.
        #expect(trend[3].formTrendMean == 3)
    }

    /// Required test 5: a single available Form observation never
    /// fabricates a trend value; the SECOND available value entering the
    /// window is what makes a trend point appear.
    @Test("Form: a single observation produces no trend value; a second available value makes one appear")
    func formMinimumSampleRequiresTwoValues() {
        let points = [Self.point(2, minutes: 0, form: 4), Self.point(9, minutes: 0, form: 3)]
        let trend = DevelopmentTimelineTrendProjector.points(from: points)
        #expect(trend[0].formTrendMean == nil)
        #expect(trend[1].formTrendMean == 3.5)
    }

    /// Required test 6: Sleep mirrors Form's exact missing/minimum-
    /// sample semantics.
    @Test("Sleep: mirrors Form's missing/minimum-sample semantics exactly")
    func sleepMirrorsFormMissingAndMinimumSampleSemantics() {
        let points = [
            Self.point(2, minutes: 0, sleep: 5), Self.point(9, minutes: 0, sleep: nil),
            Self.point(16, minutes: 0, sleep: 3),
        ]
        let trend = DevelopmentTimelineTrendProjector.points(from: points)
        #expect(trend[0].sleepTrendMean == nil) // single observation
        #expect(trend[1].sleepTrendMean == nil) // still only one available value ([5, nil])
        #expect(trend[2].sleepTrendMean == 4) // [5, nil, 3] -> mean of [5, 3]
    }

    /// Required test 9: the projector never considers anything outside
    /// the array it was actually given — the FIRST point's trend is
    /// exactly its own value, never influenced by data the caller didn't
    /// include (i.e., never a hidden "warm-up" fetch before the selected
    /// period).
    @Test("The first point's trend is bounded exactly to the provided array — no data outside it ever contributes")
    func firstPointTrendIsBoundedToProvidedArrayOnly() {
        let points = [Self.point(2, minutes: 40, form: 5, sleep: 5)]
        let trend = DevelopmentTimelineTrendProjector.points(from: points)
        #expect(trend.count == 1)
        #expect(trend[0].trainingTrendMinutes == 40)
        // A single Form/Sleep observation never produces a trend value,
        // proving the window is genuinely just this one provided point,
        // not silently padded with any assumed prior data.
        #expect(trend[0].formTrendMean == nil)
        #expect(trend[0].sleepTrendMean == nil)
    }

    /// Required test 10: the projector treats every `DevelopmentTimelinePoint`
    /// uniformly — a caller-supplied "partial calendar-month bucket"
    /// value (already computed upstream by `StatisticsService`) is
    /// consumed exactly as given, with no reconstruction of a full
    /// canonical week's worth of data.
    @Test("A partial-bucket value is consumed exactly as provided, never reconstructed to a full week")
    func partialBucketValueIsConsumedAsProvided() {
        // A partial leading calendar-month bucket might factually only
        // have, say, 15 minutes of training for its truncated slice —
        // the projector has no way to know (and must not care) that this
        // differs from a full week's own value.
        let points = [Self.point(2, minutes: 15), Self.point(9, minutes: 60)]
        let trend = DevelopmentTimelineTrendProjector.points(from: points)
        #expect(trend.map(\.trainingTrendMinutes) == [15, 37.5])
    }

    @Test("An empty input produces no trend points")
    func emptyInputProducesNoTrendPoints() {
        #expect(DevelopmentTimelineTrendProjector.points(from: []).isEmpty)
    }

    @Test("Every trend point's weekStart matches its source point's canonical weekStart, in order")
    func trendPointWeekStartsMatchSourceOrder() {
        let points = [Self.point(2, minutes: 10), Self.point(9, minutes: 20), Self.point(16, minutes: 30)]
        let trend = DevelopmentTimelineTrendProjector.points(from: points)
        #expect(trend.map(\.weekStart) == points.map(\.weekStart))
    }
}
