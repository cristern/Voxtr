import Foundation
import VoxtrCoreContracts

/// Sprint 15 (revised): selects one `Quote` for a given day,
/// deterministically. No longer takes a `referenceDate:` default
/// parameter on each call — "now" is decided once, at construction
/// time, via an injected `DateProvider`. This avoids any hidden call
/// to `Date()`/`.now` inside this type's own logic, and makes tests
/// simpler: construct once with a fixed provider, call `todaysQuote`
/// as many times as needed, with no date to remember to pass each
/// time.
///
/// Still a stateless-in-effect `struct` — the only stored property is
/// the injected `DateProvider` itself, not any mutable state this type
/// owns. Never touches UI, repositories, storage, SwiftUI,
/// `VoxtrAppShell`, or networking — confirmed by inspection: this file
/// imports only `Foundation` and `VoxtrCoreContracts` (for
/// `DateProvider`).
///
/// DETERMINISM: selection is `dayOfYear % quotes.count` against the
/// day's ordinal position in the **UTC** calendar — computed
/// internally, unconditionally, every time, not exposed as a
/// caller-overridable `calendar:` parameter. Exposing that as
/// overridable would risk a caller accidentally computing "today" in
/// local time, which would violate this feature's own explicit
/// requirement ("Same UTC day → Same quote").
public struct DailyQuoteProvider: Sendable {
    private let dateProvider: any DateProvider

    public init(dateProvider: any DateProvider = SystemDateProvider()) {
        self.dateProvider = dateProvider
    }

    /// Returns `nil` only if `quotes` is empty — a defensive case, not
    /// a failure mode this feature is expected to actually reach (a
    /// non-empty repository is a static, compile-time-authored fact,
    /// not something that can fail at runtime). No random number
    /// generator, no persistence, no stored mutable state anywhere in
    /// this method.
    public func todaysQuote(from quotes: [Quote]) -> Quote? {
        guard !quotes.isEmpty else { return nil }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let dayOfYear = utcCalendar.ordinality(of: .day, in: .year, for: dateProvider.now) ?? 1
        let index = (dayOfYear - 1) % quotes.count
        return quotes[index]
    }
}
