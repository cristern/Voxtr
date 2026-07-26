import Testing
import Foundation
import VoxtrCoreContracts
@testable import VoxtrAppShell
@testable import VoxtrMotivationDomain

@Suite("DailyQuoteApplicationService (Sprint 15, correction)", .serialized)
struct DailyQuoteApplicationServiceTests {

    private struct FixedDateProvider: DateProvider {
        let now: Date
    }

    private struct ThrowingResourceLoader: StaticQuoteRepository.ResourceLoader {
        let errorToThrow: Error
        func loadQuotesData() throws -> Data { throw errorToThrow }
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

    @Test("Returns today's quote, matching what the provider alone would select from the same repository")
    func returnsTodaysQuote() throws {
        let repository = StaticQuoteRepository()
        let fixedProvider = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 1, day: 15)))
        let service = DailyQuoteApplicationService(repository: repository, provider: fixedProvider)

        let fromService = try service.todaysQuote()
        let directlyFromProvider = fixedProvider.todaysQuote(from: try repository.quotes())

        #expect(fromService == directlyFromProvider)
        #expect(fromService != nil)
    }

    @Test("Uses the exact quotes the repository it was given exposes — no filtering, reordering, or substitution")
    func usesExactlyTheRepositoryQuotesItWasGiven() throws {
        let repository = StaticQuoteRepository()
        let provider = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 4, day: 10)))
        let service = DailyQuoteApplicationService(repository: repository, provider: provider)

        let result = try #require(service.todaysQuote())
        #expect(try repository.quotes().contains(result))
    }

    @Test("The same fixed provider always produces the same quote through the full service")
    func sameFixedProviderProducesSameQuoteThroughService() throws {
        let fixedProvider = DailyQuoteProvider(dateProvider: FixedDateProvider(now: Self.utcDate(year: 2026, month: 6, day: 1)))
        let service = DailyQuoteApplicationService(provider: fixedProvider)

        let first = try service.todaysQuote()
        let second = try service.todaysQuote()

        #expect(first == second)
    }

    @Test("The default initializer produces a quote for today without requiring any explicit dependency")
    func defaultInitializerProducesTodaysQuote() throws {
        let service = DailyQuoteApplicationService()
        #expect(try service.todaysQuote() != nil)
    }

    // MARK: - Failure propagation

    @Test("A repository failure propagates through the service, rather than being swallowed into a fake successful result")
    func repositoryFailurePropagatesThroughService() {
        let failingRepository = StaticQuoteRepository(
            resourceLoader: ThrowingResourceLoader(errorToThrow: StaticQuoteRepository.LoadError.resourceNotFound)
        )
        let service = DailyQuoteApplicationService(repository: failingRepository)

        #expect(throws: StaticQuoteRepository.LoadError.resourceNotFound) {
            try service.todaysQuote()
        }
    }
}
