import Foundation
import VoxtrMotivationDomain

/// Sprint 15 (revised): the orchestrator of the Daily Quote pipeline.
/// Loads quotes from `StaticQuoteRepository`, invokes
/// `DailyQuoteProvider`, returns today's `Quote`. Nothing else — no
/// caching, no retry, no analytics, matching
/// `CoachingApplicationService`'s own "deliberately minimal" scope.
///
/// CORRECTION: now `throws`. `StaticQuoteRepository.quotes()` can fail
/// (a missing or malformed bundled resource is a real packaging
/// defect, not a normal condition) — this service propagates that
/// failure honestly rather than swallowing it into a fake successful
/// result. `DailyQuoteViewModel` is what turns a thrown error into an
/// explicit `.failed` presentation state.
///
/// Not `@MainActor` — unlike `CoachingApplicationService`, this type
/// has no dependency on an actor-isolated protocol, so there is no
/// reason to force main-actor isolation on it. `Sendable`, matching
/// the rest of this pipeline.
public struct DailyQuoteApplicationService: Sendable {
    private let repository: StaticQuoteRepository
    private let provider: DailyQuoteProvider

    public init(
        repository: StaticQuoteRepository = StaticQuoteRepository(),
        provider: DailyQuoteProvider = DailyQuoteProvider()
    ) {
        self.repository = repository
        self.provider = provider
    }

    public func todaysQuote() throws -> Quote? {
        let quotes = try repository.quotes()
        return provider.todaysQuote(from: quotes)
    }
}
