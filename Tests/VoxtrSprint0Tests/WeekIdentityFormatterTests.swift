import Testing
import Foundation
@testable import VoxtrAppShell
import VoxtrCoreContracts

@Suite("WeekIdentityFormatter")
struct WeekIdentityFormatterTests {

    @Test("Date range within one month formats as 'DD–DD Mon'")
    func dateRangeWithinOneMonth() {
        let weekStart = LocalDate(year: 2026, month: 8, day: 10)
        #expect(WeekIdentityFormatter.dateRangeLabel(forWeekStart: weekStart) == "10–16 Aug")
    }

    @Test("Date range spanning two months includes both month abbreviations")
    func dateRangeSpanningTwoMonths() {
        let weekStart = LocalDate(year: 2026, month: 7, day: 27)
        #expect(WeekIdentityFormatter.dateRangeLabel(forWeekStart: weekStart) == "27 Jul–02 Aug")
    }

    @Test("Identity label (legacy combined form) now returns the stable week-number + date-range identity, without relative context blended in")
    func combinedIdentityLabel() {
        let thisWeek = LocalDate(year: 2026, month: 8, day: 10)
        let distantWeek = thisWeek.adding(days: -21)

        #expect(WeekIdentityFormatter.identityLabel(forWeekStart: thisWeek, referenceWeekStart: thisWeek) == "Week 33 · 10–16 Aug")
        #expect(WeekIdentityFormatter.identityLabel(forWeekStart: distantWeek, referenceWeekStart: thisWeek) == WeekIdentityFormatter.stableIdentityLabel(forWeekStart: distantWeek))
    }

    @Test("Week number is deterministic and derived from the canonical Monday weekStart")
    func weekNumberIsDeterministic() {
        // 10 Aug 2026 is a Monday, ISO week 33.
        let weekStart = LocalDate(year: 2026, month: 8, day: 10)
        #expect(WeekIdentityFormatter.weekNumber(forWeekStart: weekStart) == 33)
    }

    @Test("Week number handles a year boundary deterministically")
    func weekNumberHandlesYearBoundary() {
        // 28 Dec 2026 is a Monday — belongs to ISO week 53 of 2026.
        let lateDecemberMonday = LocalDate(year: 2026, month: 12, day: 28)
        #expect(WeekIdentityFormatter.weekNumber(forWeekStart: lateDecemberMonday) == 53)
    }

    @Test("Stable identity label is 'Week N · date range' — never week number alone")
    func stableIdentityLabelStructure() {
        let weekStart = LocalDate(year: 2026, month: 8, day: 10)
        #expect(WeekIdentityFormatter.stableIdentityLabel(forWeekStart: weekStart) == "Week 33 · 10–16 Aug")
    }

    @Test("Only THIS WEEK and PREVIOUS WEEK receive a relative badge — older weeks get none, never '2 weeks ago' style labels")
    func onlyThisAndPreviousWeekGetBadges() {
        let thisWeek = LocalDate(year: 2026, month: 8, day: 10)
        let previousWeek = thisWeek.adding(days: -7)
        let twoWeeksAgo = thisWeek.adding(days: -14)
        let nextWeek = thisWeek.adding(days: 7)

        #expect(WeekIdentityFormatter.contextualLabel(for: thisWeek, referenceWeekStart: thisWeek) == "THIS WEEK")
        #expect(WeekIdentityFormatter.contextualLabel(for: previousWeek, referenceWeekStart: thisWeek) == "PREVIOUS WEEK")
        #expect(WeekIdentityFormatter.contextualLabel(for: twoWeeksAgo, referenceWeekStart: thisWeek) == nil)
        // "Next week" is deliberately not a badge per the approved
        // contract — only THIS WEEK/PREVIOUS WEEK qualify.
        #expect(WeekIdentityFormatter.contextualLabel(for: nextWeek, referenceWeekStart: thisWeek) == nil)
    }
}
