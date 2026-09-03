import Testing
@testable import VoxtrAppShell
import VoxtrCoreContracts

/// Planned Activity Time Range Presentation: focused coverage for the
/// one shared formatter every AppShell surface reuses to render a
/// planned activity's schedule time. Pure/deterministic — no
/// persistence, no SwiftData, runs in every environment.
@Suite("PlannedTimeRangeFormatter")
struct PlannedTimeRangeFormatterTests {

    @Test("Start + duration formats as an en-dash time range")
    func startAndDurationFormatsAsRange() {
        let start = LocalTime(hour: 18, minute: 0)
        #expect(PlannedTimeRangeFormatter.label(start: start, durationMinutes: 90) == "18:00–19:30")
    }

    @Test("Start with no duration shows the start time alone")
    func startWithNoDurationShowsStartAlone() {
        let start = LocalTime(hour: 18, minute: 0)
        #expect(PlannedTimeRangeFormatter.label(start: start, durationMinutes: nil) == "18:00")
    }

    @Test("No start time never derives a range, even when duration is known")
    func noStartTimeNeverDerivesRange() {
        #expect(PlannedTimeRangeFormatter.label(start: nil, durationMinutes: 90) == nil)
        #expect(PlannedTimeRangeFormatter.label(start: nil, durationMinutes: nil) == nil)
    }

    @Test("Minute rollover within the same hour")
    func minuteRollover() {
        let start = LocalTime(hour: 9, minute: 45)
        #expect(PlannedTimeRangeFormatter.label(start: start, durationMinutes: 10) == "09:45–09:55")
    }

    @Test("Hour rollover carries into the next hour correctly")
    func hourRollover() {
        let start = LocalTime(hour: 9, minute: 45)
        #expect(PlannedTimeRangeFormatter.label(start: start, durationMinutes: 30) == "09:45–10:15")
    }

    @Test("Crossing midnight wraps to a valid clock time, never crashing or going out of range")
    func midnightCrossingWraps() {
        let start = LocalTime(hour: 23, minute: 30)
        #expect(PlannedTimeRangeFormatter.label(start: start, durationMinutes: 90) == "23:30–01:00")
    }

    @Test("A duration spanning exactly one full day wraps back to the same start time")
    func fullDayDurationWrapsToSameStart() {
        let start = LocalTime(hour: 8, minute: 0)
        #expect(PlannedTimeRangeFormatter.label(start: start, durationMinutes: 1440) == "08:00–08:00")
    }

    @Test("LocalTime.adding(minutes:) never produces an out-of-range hour or minute")
    func addingMinutesNeverProducesInvalidClockValues() {
        let start = LocalTime(hour: 23, minute: 59)
        let end = start.adding(minutes: 2)
        #expect(end.hour == 0)
        #expect(end.minute == 1)
        #expect((0...23).contains(end.hour))
        #expect((0...59).contains(end.minute))
    }
}
