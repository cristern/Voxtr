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
}
