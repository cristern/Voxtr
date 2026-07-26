import Foundation
import VoxtrMotivationDomain

/// Sprint 15 (correction): infrastructure — loads `Quote` values from
/// a bundled JSON resource (`Resources/Quotes.json`). "Repository"
/// here names its role in the pipeline (something
/// `DailyQuoteApplicationService` reads from), not a SwiftData/
/// persistence concept; this is a read-only bundled resource, not a
/// database.
///
/// CORRECTION: this used to fall back to an empty array on any load or
/// decode failure. `Quotes.json` is a required bundled application
/// resource, not optional content — a missing or malformed resource is
/// a packaging defect, not a normal runtime condition, and hiding it
/// behind a silently-empty result would make that defect invisible.
/// `quotes()` is now throwing, with two explicit error cases.
///
/// TEST SEAM: `Bundle.module` itself cannot be swapped in a unit test.
/// Rather than move resource-loading into a broader, harder-to-test
/// abstraction, the smallest seam that actually helps is injected here
/// — `ResourceLoader` supplies the raw bytes; decoding those bytes into
/// `[Quote]` stays in this type either way. `BundleResourceLoader` is
/// the only production implementation and the only place that ever
/// touches `Bundle.module`.
public struct StaticQuoteRepository: Sendable {
    public enum LoadError: Error, Equatable, Sendable {
        case resourceNotFound
        case decodingFailed
    }

    public protocol ResourceLoader: Sendable {
        func loadQuotesData() throws -> Data
    }

    /// The only production conformer, and the only place in this
    /// feature that references `Bundle.module`.
    public struct BundleResourceLoader: ResourceLoader {
        public init() {}

        public func loadQuotesData() throws -> Data {
            guard let url = Bundle.module.url(forResource: "Quotes", withExtension: "json") else {
                throw LoadError.resourceNotFound
            }
            do {
                return try Data(contentsOf: url)
            } catch {
                // The resource exists but couldn't be read — still a
                // packaging-level problem, not a decoding one.
                throw LoadError.resourceNotFound
            }
        }
    }

    private let resourceLoader: any ResourceLoader

    public init(resourceLoader: any ResourceLoader = BundleResourceLoader()) {
        self.resourceLoader = resourceLoader
    }

    /// No caching — this feature's data is tiny (30 short quotes) and
    /// decoding it is fast; adding a cache here would only add a place
    /// for a stale or partially-failed load to hide, for no measurable
    /// benefit.
    public func quotes() throws -> [Quote] {
        let data = try resourceLoader.loadQuotesData()
        do {
            return try JSONDecoder().decode([Quote].self, from: data)
        } catch {
            throw LoadError.decodingFailed
        }
    }
}
