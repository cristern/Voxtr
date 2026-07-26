import Foundation

/// Sprint 15 (revision): an injectable "current time" abstraction.
/// Introduced so `VoxtrMotivationDomain.DailyQuoteProvider` (and any
/// future code with the same need) never calls `Date()`/`.now`
/// directly inside its own logic — the caller decides what "now" means
/// by injecting a `DateProvider` at construction time, not by passing
/// an overridable default parameter to each individual call.
///
/// Lives here, in the shared contracts package, rather than inside
/// `VoxtrMotivationDomain` — this is a general-purpose testability
/// abstraction, not something specific to quotes or motivation, so it
/// belongs where every domain package can reach it, the same way
/// `AthleteId`/`LocalDate` do.
public protocol DateProvider: Sendable {
    var now: Date { get }
}

/// The real, production implementation — genuinely reads the system
/// clock. The only place in this abstraction's own files that calls
/// `Date()` at all.
public struct SystemDateProvider: DateProvider {
    public init() {}

    public var now: Date { Date() }
}
