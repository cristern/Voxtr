import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrCoreReferenceData
@testable import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

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

    // MARK: - Time-axis readability: year context (review follow-up round 2)

    private static func timelinePoint(_ weekStart: LocalDate) -> DevelopmentTimelinePoint {
        DevelopmentTimelinePoint(weekStart: weekStart, trainingMinutes: 0, formMean: nil, sleepMean: nil)
    }

    /// Required test 1: a calendar-month January period whose first
    /// canonical weekly bucket starts 2025-12-29 must still show ONLY
    /// "2026" — the SELECTED INTERVAL (2026-01-01...2026-01-31)
    /// contains no dates from 2025, even though a bucket's own
    /// canonical `weekStart` does.
    @Test("A January calendar-month period shows only 2026, even though its leading bucket starts in December 2025")
    func yearContextJanuaryCalendarMonthShowsOnlySelectedYear() {
        let label = DevelopmentTimelineChart.yearContextLabel(
            intervalStart: LocalDate(year: 2026, month: 1, day: 1),
            intervalEnd: LocalDate(year: 2026, month: 1, day: 31)
        )
        #expect(label == "2026")
    }

    @Test("A period entirely within one calendar year shows just that year")
    func yearContextSingleYear() {
        let label = DevelopmentTimelineChart.yearContextLabel(
            intervalStart: LocalDate(year: 2026, month: 6, day: 1),
            intervalEnd: LocalDate(year: 2026, month: 6, day: 30)
        )
        #expect(label == "2026")
    }

    /// Required test 4: a genuinely multi-year SELECTED INTERVAL (not
    /// just a bucket's own canonical week start) must show both years.
    @Test("An interval that itself genuinely spans two calendar years shows both years")
    func yearContextTrueMultiYearInterval() {
        let label = DevelopmentTimelineChart.yearContextLabel(
            intervalStart: LocalDate(year: 2025, month: 12, day: 1),
            intervalEnd: LocalDate(year: 2026, month: 1, day: 31)
        )
        #expect(label == "2025 – 2026")
    }

    // MARK: - Time-axis readability: partial-bucket date-label clamping

    /// Required test 2: the canonical week start (2025-12-29) is
    /// outside the selected interval (starts 2026-01-01) — the
    /// DISPLAYED date must clamp forward to the interval's own start,
    /// never show a date the selected Statistics period doesn't
    /// actually contain.
    @Test("A partial leading bucket's displayed date clamps to the interval start, not the canonical week start")
    func displayDateClampsJanuaryPartialLeadingBucket() {
        let point = Self.timelinePoint(LocalDate(year: 2025, month: 12, day: 29))
        let intervalStart = LocalDate(year: 2026, month: 1, day: 1)
        let clamped = DevelopmentTimelineChart.displayDate(for: point, intervalStart: intervalStart)
        #expect(clamped == intervalStart)
        #expect(WeekIdentityFormatter.shortDateLabel(for: clamped) == "Jan 1")
        // The week number must still derive from the CANONICAL week start.
        #expect(DevelopmentTimelineChart.weekNumberLabel(for: point.weekStart) == "W1")
    }

    /// Required test 3: August 2026's own leading canonical week starts
    /// 2026-07-27 (before the selected month begins); the displayed
    /// date must clamp to 2026-08-01.
    @Test("August 2026's partial leading bucket displays Aug 1, not the canonical July week start")
    func displayDateClampsAugustPartialLeadingBucket() {
        let point = Self.timelinePoint(LocalDate(year: 2026, month: 7, day: 27))
        let intervalStart = LocalDate(year: 2026, month: 8, day: 1)
        let clamped = DevelopmentTimelineChart.displayDate(for: point, intervalStart: intervalStart)
        #expect(clamped == intervalStart)
        #expect(WeekIdentityFormatter.shortDateLabel(for: clamped) == "Aug 1")
        // The week number must still derive from the CANONICAL week start.
        #expect(DevelopmentTimelineChart.weekNumberLabel(for: point.weekStart) == "W31")
    }

    @Test("A normal, fully-in-interval bucket's displayed date is unchanged — equal to its own week start")
    func displayDateUnchangedForNormalBucket() {
        let point = Self.timelinePoint(LocalDate(year: 2026, month: 6, day: 8))
        let clamped = DevelopmentTimelineChart.displayDate(for: point, intervalStart: LocalDate(year: 2026, month: 6, day: 1))
        #expect(clamped == point.weekStart)
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

    /// Review follow-up (round 2), required test 5: the previous
    /// algorithm appended the final bucket (25) separately whenever it
    /// wasn't already reached by the stride, producing adjacent labels
    /// at indices 24 and 25 — undermining the whole point of reduced
    /// density. Anchoring the stride ON the final bucket and walking
    /// backward (see `labeledIndices`'s own doc comment) keeps the
    /// final bucket as part of the SAME regular spacing instead.
    @Test("Last 26 Weeks uses a further-reduced, regular density, includes the final bucket, and never clusters two adjacent labels")
    func labeledIndicesTwentySixBucketsUsesFurtherReducedDensityWithNoAdjacentCluster() {
        let indices = DevelopmentTimelineChart.labeledIndices(bucketCount: 26)
        #expect(indices == [1, 5, 9, 13, 17, 21, 25])
        #expect(indices.last == 25)
        #expect(indices.count < 13)
        for (previous, next) in zip(indices, indices.dropFirst()) {
            #expect(next - previous > 1)
        }
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

/// Fullscreen data-ownership round: focused coverage for
/// `DevelopmentTimelinePoint.points(from:sports:)` — the ONE shared
/// projection `AthleteStatisticsView` and `DevelopmentTimelineFullscreenView`
/// both now call (extracted specifically so neither could duplicate or
/// silently diverge from the other). Exercises it against a REAL
/// `StatisticsAthleteSummary` produced by `StatisticsService` (the same
/// fixture style `StatisticsServiceTests`/`StatisticsViewModelTests`
/// already use), not a hand-rolled read-model literal.
@Suite("DevelopmentTimelinePoint.points(from:sports:) shared projection")
struct DevelopmentTimelinePointProjectionTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }

    /// Proves the extraction preserved behavior: factual minutes/Form/
    /// Sleep project through unchanged, and Sport segment display names
    /// resolve correctly through BOTH fallback paths this shared
    /// function owns — "No sport" for a genuinely Sport-less activity,
    /// "Unknown" for a real `SportId` the caller's `sports` list can't
    /// resolve (here, deliberately empty) — never a dropped segment.
    @Test("Shared projection maps factual minutes and resolves Sport display-name fallbacks correctly")
    @MainActor
    func projectionMapsFactualDataAndResolvesSportFallbacks() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let football = SportId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)

        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: nil, activityType: .other, title: "General fitness",
            startedAt: Self.date(2026, 3, 4), durationMinutes: 20, status: .completed
        )
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Planned session", localDate: LocalDate(year: 2026, month: 3, day: 5),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 40
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        // Empty canonical Sport catalog — the football SportId above is
        // real (has recorded history) but deliberately unresolvable
        // here, proving the "Unknown" fallback rather than a dropped
        // segment or a crash.
        let points = DevelopmentTimelinePoint.points(from: summary, sports: [])
        let point = try #require(points.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })

        #expect(point.trainingMinutes == 50)
        #expect(point.formMean == summary.weeklyBuckets.first { $0.weekStart == point.weekStart }?.form.mean)
        #expect(point.sleepMean == summary.weeklyBuckets.first { $0.weekStart == point.weekStart }?.sleep.mean)

        #expect(point.trainingBySport.count == 2)
        #expect(point.trainingBySport.first { $0.id == TrainingCategorySegment.noSportKey }?.displayName == "No sport")
        #expect(point.trainingBySport.first { $0.id == football.rawValue.uuidString }?.displayName == "Unknown")

        #expect(point.trainingByActivityType.count == 2)
        #expect(point.trainingByActivityType.first { $0.id == ActivityType.teamTraining.rawValue }?.displayName == ActivityType.teamTraining.displayName)
        #expect(point.trainingByActivityType.first { $0.id == ActivityType.other.rawValue }?.displayName == ActivityType.other.displayName)

        // Plan vs Actual round: `plannedMinutes` projects straight
        // through from the SAME weekly bucket `trainingMinutes` above
        // already came from — no independent recomputation in the
        // shared projection.
        #expect(point.plannedMinutes == 40)
        #expect(point.plannedMinutes == summary.weeklyBuckets.first { $0.weekStart == point.weekStart }?.plannedMinutes)
    }
}
