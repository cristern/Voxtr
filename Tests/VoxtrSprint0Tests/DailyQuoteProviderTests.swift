import Testing
import Foundation
import VoxtrCoreContracts
@testable import VoxtrMotivationDomain

@Suite("DailyQuoteProvider (Sprint 15, revised)", .serialized)
struct DailyQuoteProviderTests {

    private static let quotes = [
        Quote(id: "a", text: "Quote A", author: "Author A"),
        Quote(id: "b", text: "Quote B", author: "Author B"),
        Quote(id: "c", text: "Quote C", author: "Author C"),
    ]

    /// A deterministic, fixed-`now` `DateProvider` for tests — no
    /// hidden call to `Date()` anywhere in this file either.
    private struct FixedDateProvider: DateProvider {
        let now: Date
    }

    private static func utcDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    @Test("The same UTC day always produces the same quote")
    func sameUTCDayProducesSameQuote() {
        let provider = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 1, day: 15)))

        let first = provider.todaysQuote(from: Self.quotes)
        let second = provider.todaysQuote(from: Self.quotes)

        #expect(first == second)
    }

    @Test("A different UTC day produces a different quote when the day-of-year values differ by an amount not divisible by the quote count")
    func differentDayProducesDifferentQuote() {
        let day15 = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 1, day: 15)))
            .todaysQuote(from: Self.quotes)
        let day16 = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 1, day: 16)))
            .todaysQuote(from: Self.quotes)

        #expect(day15 != day16)
    }

    @Test("Selection wraps around after quotes.count days — the day after wrapping matches the first day again")
    func selectionWrapsAroundAfterQuoteCountDays() {
        // Day-of-year 15 and day-of-year 18 (15 + quotes.count, 3)
        // land on the same modulo index.
        let day15 = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 1, day: 15)))
            .todaysQuote(from: Self.quotes)
        let day18 = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 1, day: 18)))
            .todaysQuote(from: Self.quotes)

        #expect(day15 == day18)
    }

    @Test("An empty quote collection returns nil, never crashes")
    func emptyCollectionReturnsNil() {
        let provider = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 1, day: 15)))
        #expect(provider.todaysQuote(from: []) == nil)
    }

    @Test("A single-quote collection always returns that quote, regardless of the day")
    func singleQuoteCollectionAlwaysReturnsItself() {
        let single = [Quote(id: "only", text: "Only quote", author: "Only Author")]

        let day1 = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 1, day: 1)))
            .todaysQuote(from: single)
        let day200 = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 7, day: 19)))
            .todaysQuote(from: single)

        #expect(day1 == single.first)
        #expect(day200 == single.first)
    }

    @Test("Repeated calls against the same fixed provider are deterministic")
    func repeatedCallsAreDeterministic() {
        let provider = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 3, day: 10)))

        let results = (0..<5).map { _ in provider.todaysQuote(from: Self.quotes) }
        let uniqueIds = Set(results.compactMap { $0?.id })

        #expect(uniqueIds.count == 1)
    }

    @Test("The default initializer uses SystemDateProvider and produces a quote for today")
    func defaultInitializerUsesSystemDateProvider() {
        // Confirms the convenience default still works end to end
        // without requiring every call site to inject a provider —
        // real production usage never passes one explicitly.
        let provider = DailyQuoteProvider()
        #expect(provider.todaysQuote(from: Self.quotes) != nil)
    }
}
