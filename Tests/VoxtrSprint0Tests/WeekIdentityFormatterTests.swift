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

    @Test("This week's label is contextual, prior/next weeks are labeled, other weeks have no context label")
    func contextualLabeling() {
        let thisWeek = LocalDate(year: 2026, month: 8, day: 10)
        let previousWeek = thisWeek.adding(days: -7)
        let nextWeek = thisWeek.adding(days: 7)
        let distantWeek = thisWeek.adding(days: -21)

        #expect(WeekIdentityFormatter.contextualLabel(for: thisWeek, referenceWeekStart: thisWeek) == "This week")
        #expect(WeekIdentityFormatter.contextualLabel(for: previousWeek, referenceWeekStart: thisWeek) == "Previous week")
        #expect(WeekIdentityFormatter.contextualLabel(for: nextWeek, referenceWeekStart: thisWeek) == "Next week")
        #expect(WeekIdentityFormatter.contextualLabel(for: distantWeek, referenceWeekStart: thisWeek) == nil)
    }

    @Test("Identity label combines context and date range when a context exists; date range alone otherwise")
    func combinedIdentityLabel() {
        let thisWeek = LocalDate(year: 2026, month: 8, day: 10)
        let distantWeek = thisWeek.adding(days: -21)

        #expect(WeekIdentityFormatter.identityLabel(forWeekStart: thisWeek, referenceWeekStart: thisWeek) == "This week · 10–16 Aug")
        #expect(WeekIdentityFormatter.identityLabel(forWeekStart: distantWeek, referenceWeekStart: thisWeek) == "20–26 Jul")
    }
}
