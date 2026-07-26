import Foundation

/// Sprint 15: a single inspirational quotation. Pure domain data — no
/// UI information (no color, no font, no layout hint) belongs here;
/// that stays entirely at the `VoxtrAppShell`/`DailyQuoteView` boundary,
/// matching this project's established separation between domain
/// models and presentation.
///
/// `id` is a stable, hand-assigned `String` slug (e.g.
/// `"marcus-aurelius-01"`), not a randomly-generated `UUID`. This
/// feature's own governing rule is "no randomness during a single
/// day" — a `UUID()` generated fresh at repository-construction time
/// would technically violate that spirit even though it doesn't affect
/// *which* quote is selected, so stable identifiers are used instead
/// everywhere in this domain.
/// `Codable`: added so `Quote` can be decoded directly from
/// `StaticQuoteRepository`'s bundled `Quotes.json` (Sprint 15,
/// revised — the curated list moved out of Swift code, into data).
/// This is a general-purpose serialization protocol, not a storage or
/// persistence concept — conforming to it doesn't couple this domain
/// type to any storage mechanism; `VoxtrAppShell` decides how (or
/// whether) to actually serialize it.
public struct Quote: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let text: String
    public let author: String

    public init(id: String, text: String, author: String) {
        self.id = id
        self.text = text
        self.author = author
    }
}
