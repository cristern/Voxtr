import Testing
import Foundation
@testable import VoxtrAppShell
@testable import VoxtrMotivationDomain

@Suite("StaticQuoteRepository (Sprint 15, correction)", .serialized)
struct StaticQuoteRepositoryTests {

    private struct StubResourceLoader: StaticQuoteRepository.ResourceLoader {
        let dataToReturn: Data
        func loadQuotesData() throws -> Data { dataToReturn }
    }

    private struct ThrowingResourceLoader: StaticQuoteRepository.ResourceLoader {
        let errorToThrow: Error
        func loadQuotesData() throws -> Data { throw errorToThrow }
    }

    private static func validQuotesData() -> Data {
        let quotes = [Quote(id: "a", text: "Quote A", author: "Author A")]
        return try! JSONEncoder().encode(quotes)
    }

    // MARK: - Valid loading

    @Test("The real repository loads successfully and is not empty")
    func realRepositoryLoadsSuccessfully() throws {
        let repository = StaticQuoteRepository()
        let quotes = try repository.quotes()
        #expect(!quotes.isEmpty)
    }

    @Test("The real repository contains at least 30 quotes")
    func realRepositoryContainsAtLeastThirtyQuotes() throws {
        let repository = StaticQuoteRepository()
        let quotes = try repository.quotes()
        #expect(quotes.count >= 30)
    }

    @Test("Every quote in the real repository has a unique id")
    func realRepositoryContainsUniqueIds() throws {
        let repository = StaticQuoteRepository()
        let ids = try repository.quotes().map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("No quote in the real repository has empty text or an empty author")
    func noQuoteHasEmptyTextOrAuthor() throws {
        let repository = StaticQuoteRepository()
        let quotes = try repository.quotes()
        #expect(quotes.allSatisfy { !$0.text.isEmpty && !$0.author.isEmpty })
    }

    @Test("A repository backed by a valid injected loader decodes correctly")
    func injectedLoaderWithValidDataDecodesCorrectly() throws {
        let repository = StaticQuoteRepository(resourceLoader: StubResourceLoader(dataToReturn: Self.validQuotesData()))
        let quotes = try repository.quotes()
        #expect(quotes == [Quote(id: "a", text: "Quote A", author: "Author A")])
    }

    // MARK: - Missing resource / injected loader failure

    @Test("A resource loader that throws .resourceNotFound propagates that exact error")
    func loaderThrowingResourceNotFoundPropagates() {
        let repository = StaticQuoteRepository(
            resourceLoader: ThrowingResourceLoader(errorToThrow: StaticQuoteRepository.LoadError.resourceNotFound)
        )

        #expect(throws: StaticQuoteRepository.LoadError.resourceNotFound) {
            try repository.quotes()
        }
    }

    // MARK: - Decoding failure

    @Test("Malformed JSON data throws .decodingFailed, never silently returns an empty collection")
    func malformedDataThrowsDecodingFailed() {
        let malformedData = Data("this is not valid JSON".utf8)
        let repository = StaticQuoteRepository(resourceLoader: StubResourceLoader(dataToReturn: malformedData))

        #expect(throws: StaticQuoteRepository.LoadError.decodingFailed) {
            try repository.quotes()
        }
    }

    @Test("JSON that is valid but does not match Quote's shape also throws .decodingFailed")
    func mismatchedShapeThrowsDecodingFailed() {
        let wrongShapeData = Data(#"[{"unexpected": "shape"}]"#.utf8)
        let repository = StaticQuoteRepository(resourceLoader: StubResourceLoader(dataToReturn: wrongShapeData))

        #expect(throws: StaticQuoteRepository.LoadError.decodingFailed) {
            try repository.quotes()
        }
    }
}
