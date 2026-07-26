import Testing
import Foundation
@testable import VoxtrAppShell
@testable import VoxtrMotivationDomain

@Suite("DailyQuoteViewModel (Sprint 15, correction)", .serialized)
struct DailyQuoteViewModelTests {

    private struct ThrowingResourceLoader: StaticQuoteRepository.ResourceLoader {
        struct TestError: Error {}
        func loadQuotesData() throws -> Data { throw TestError() }
    }

    @Test("Initial state is .loading before load() is called")
    @MainActor
    func initialStateIsLoading() {
        let viewModel = DailyQuoteViewModel()
        guard case .loading = viewModel.state else {
            Issue.record("Expected .loading")
            return
        }
    }

    @Test("A successful load produces .loaded with a non-nil quote")
    @MainActor
    func successfulLoadProducesLoadedQuote() {
        let viewModel = DailyQuoteViewModel()

        viewModel.load()

        guard case .loaded(let quote) = viewModel.state else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(quote != nil)
    }

    @Test("A repository failure produces .failed, never a silently-successful empty state")
    @MainActor
    func repositoryFailureProducesFailedState() {
        let failingRepository = StaticQuoteRepository(resourceLoader: ThrowingResourceLoader())
        let service = DailyQuoteApplicationService(repository: failingRepository)
        let viewModel = DailyQuoteViewModel(applicationService: service)

        viewModel.load()

        guard case .failed = viewModel.state else {
            Issue.record("Expected .failed, not a successfully-loaded empty state")
            return
        }
    }
}
