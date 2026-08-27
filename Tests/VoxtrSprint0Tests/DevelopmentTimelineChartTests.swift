import Testing
import VoxtrCoreContracts
@testable import VoxtrAppShell

/// Review follow-up (PR #24), item 2: pure, UI-independent tests for
/// `DevelopmentTimelineChart.contiguousRuns(_:value:)` — the run-
/// segmentation logic that guarantees a missing Form/Sleep week becomes
/// a genuine break rather than an interpolated-through gap. No View
/// instantiation or rendering involved (Swift Charts marks themselves
/// are not exercised here — this only proves the segmentation the
/// chart's series keys are built from).
@Suite("DevelopmentTimelineChart run segmentation")
struct DevelopmentTimelineChartTests {
    private static func point(_ day: Int, form: Double?) -> DevelopmentTimelinePoint {
        DevelopmentTimelinePoint(
            weekStart: LocalDate(year: 2026, month: 3, day: day),
            trainingMinutes: 0,
            formMean: form,
            sleepMean: nil
        )
    }

    @Test("Every point present produces exactly one run containing all of them")
    func allPresentProducesOneRun() {
        let points = [Self.point(2, form: 3), Self.point(9, form: 4), Self.point(16, form: 5)]
        let runs = DevelopmentTimelineChart.contiguousRuns(points, value: \.formMean)
        #expect(runs.count == 1)
        #expect(runs.first?.count == 3)
    }

    @Test("Every point missing produces no runs at all")
    func allMissingProducesNoRuns() {
        let points = [Self.point(2, form: nil), Self.point(9, form: nil)]
        let runs = DevelopmentTimelineChart.contiguousRuns(points, value: \.formMean)
        #expect(runs.isEmpty)
    }

    @Test("A missing week in the middle splits present weeks into two separate runs")
    func middleGapSplitsIntoTwoRuns() {
        let points = [
            Self.point(2, form: 3),
            Self.point(9, form: 4),
            Self.point(16, form: nil),
            Self.point(23, form: 5),
        ]
        let runs = DevelopmentTimelineChart.contiguousRuns(points, value: \.formMean)
        #expect(runs.count == 2)
        #expect(runs[0].map(\.weekStart) == [LocalDate(year: 2026, month: 3, day: 2), LocalDate(year: 2026, month: 3, day: 9)])
        #expect(runs[1].map(\.weekStart) == [LocalDate(year: 2026, month: 3, day: 23)])
        #expect(runs[0].map(\.value) == [3, 4])
        #expect(runs[1].map(\.value) == [5])
    }

    @Test("Leading and trailing missing weeks are excluded, not padded into the surrounding run")
    func leadingAndTrailingMissingAreExcluded() {
        let points = [
            Self.point(2, form: nil),
            Self.point(9, form: 3),
            Self.point(16, form: nil),
        ]
        let runs = DevelopmentTimelineChart.contiguousRuns(points, value: \.formMean)
        #expect(runs.count == 1)
        #expect(runs.first?.map(\.weekStart) == [LocalDate(year: 2026, month: 3, day: 9)])
    }

    @Test("Multiple gaps produce one run per contiguous present stretch")
    func multipleGapsProduceMultipleRuns() {
        let points = [
            Self.point(2, form: 1),
            Self.point(9, form: nil),
            Self.point(16, form: 2),
            Self.point(23, form: nil),
            Self.point(30, form: 3),
        ]
        let runs = DevelopmentTimelineChart.contiguousRuns(points, value: \.formMean)
        #expect(runs.count == 3)
        #expect(runs.map { $0.count } == [1, 1, 1])
    }

    // MARK: - Time-axis readability: year context

    private static func timelinePoint(_ weekStart: LocalDate) -> DevelopmentTimelinePoint {
        DevelopmentTimelinePoint(weekStart: weekStart, trainingMinutes: 0, formMean: nil, sleepMean: nil)
    }

    @Test("A period entirely within one calendar year shows just that year")
    func yearContextSingleYear() {
        let points = [
            Self.timelinePoint(LocalDate(year: 2026, month: 6, day: 1)),
            Self.timelinePoint(LocalDate(year: 2026, month: 6, day: 8)),
            Self.timelinePoint(LocalDate(year: 2026, month: 6, day: 15)),
        ]
        #expect(DevelopmentTimelineChart.yearContextLabel(for: points) == "2026")
    }

    @Test("A period whose buckets span a year boundary shows both years, never just one")
    func yearContextSpansYearBoundary() {
        // A calendar-month period's own leading bucket can genuinely
        // start in the prior year (e.g. February 2026's own leading
        // canonical week starts 2026-01-26... but the classic case is a
        // January period whose leading week starts in December).
        let points = [
            Self.timelinePoint(LocalDate(year: 2025, month: 12, day: 29)),
            Self.timelinePoint(LocalDate(year: 2026, month: 1, day: 5)),
            Self.timelinePoint(LocalDate(year: 2026, month: 1, day: 12)),
        ]
        #expect(DevelopmentTimelineChart.yearContextLabel(for: points) == "2025 – 2026")
    }

    @Test("An empty bucket set has no year context")
    func yearContextEmptyPoints() {
        #expect(DevelopmentTimelineChart.yearContextLabel(for: []) == nil)
    }

    // MARK: - Time-axis readability: label density

    @Test("Last 4 Weeks (4 buckets) labels every bucket")
    func labeledIndicesFourBucketsLabelsAll() {
        #expect(DevelopmentTimelineChart.labeledIndices(bucketCount: 4) == [0, 1, 2, 3])
    }

    @Test("A calendar-month period with 5 buckets labels every bucket")
    func labeledIndicesFiveBucketsLabelsAll() {
        #expect(DevelopmentTimelineChart.labeledIndices(bucketCount: 5) == [0, 1, 2, 3, 4])
    }

    @Test("A calendar-month period with 6 buckets labels every bucket")
    func labeledIndicesSixBucketsLabelsAll() {
        #expect(DevelopmentTimelineChart.labeledIndices(bucketCount: 6) == [0, 1, 2, 3, 4, 5])
    }

    @Test("Last 13 Weeks uses a reduced, regular density and always includes the final bucket")
    func labeledIndicesThirteenBucketsUsesReducedDensity() {
        let indices = DevelopmentTimelineChart.labeledIndices(bucketCount: 13)
        #expect(indices == [0, 2, 4, 6, 8, 10, 12])
        #expect(indices.last == 12)
        #expect(indices.count < 13)
    }

    @Test("Last 26 Weeks uses a further-reduced, regular density and always includes the final bucket")
    func labeledIndicesTwentySixBucketsUsesFurtherReducedDensity() {
        let indices = DevelopmentTimelineChart.labeledIndices(bucketCount: 26)
        #expect(indices == [0, 4, 8, 12, 16, 20, 24, 25])
        #expect(indices.last == 25)
        #expect(indices.count < 13)
    }

    @Test("An empty bucket set has no labeled indices")
    func labeledIndicesEmptyBucketCount() {
        #expect(DevelopmentTimelineChart.labeledIndices(bucketCount: 0).isEmpty)
    }

    // MARK: - Time-axis readability: week-number label

    @Test("weekNumberLabel reuses the canonical WeekIdentityFormatter week number, prefixed with W")
    func weekNumberLabelMatchesCanonicalWeekNumber() {
        let weekStart = LocalDate(year: 2026, month: 6, day: 1)
        let expected = "W\(WeekIdentityFormatter.weekNumber(forWeekStart: weekStart))"
        #expect(DevelopmentTimelineChart.weekNumberLabel(for: weekStart) == expected)
    }
}
