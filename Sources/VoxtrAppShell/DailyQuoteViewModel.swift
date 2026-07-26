import Foundation
import Observation
import VoxtrMotivationDomain

/// Sprint 15 (correction): added `.failed` back. The original design
/// omitted it because nothing in the pipeline could throw — that
/// reasoning no longer holds now that `StaticQuoteRepository.quotes()`
/// throws on a missing or malformed bundled resource. This is exactly
/// the same care applied in reverse: a state is only speculative dead
/// code when nothing can reach it; once something genuinely can, it
/// belongs.
///
/// `.loaded(nil)` remains distinct from `.failed` — `nil` still means
/// "the pipeline succeeded but there was nothing to show" (not
/// currently reachable given a non-empty bundled resource, but
/// `DailyQuoteProvider` still handles it correctly if it ever were);
/// `.failed` means the pipeline itself threw.
public enum DailyQuotePresentationState {
    case loading
    case loaded(Quote?)
    case failed
}

/// Sprint 15: requests today's quote and exposes immutable
/// presentation state. No business logic — it does not decide which
/// quote today's is (`DailyQuoteProvider`'s job, inside
/// `DailyQuoteApplicationService`) and does not choose wording
/// (there is none to choose; a `Quote`'s `text`/`author` are rendered
/// as-is, and the one piece of UI-authored text for the failure state
/// lives in `DailyQuoteStrings`, not here).
///
/// CORRECTION: `load()` now handles a thrown error honestly — it
/// becomes `.failed`, never a silently-empty `.loaded(nil)`. Those two
/// outcomes are not the same thing and must not be conflated.
@MainActor
@Observable
public final class DailyQuoteViewModel {
    public private(set) var state: DailyQuotePresentationState = .loading

    private let applicationService: DailyQuoteApplicationService

    public init(applicationService: DailyQuoteApplicationService = DailyQuoteApplicationService()) {
        self.applicationService = applicationService
    }

    public func load() {
        state = .loading
        do {
            state = .loaded(try applicationService.todaysQuote())
        } catch {
            state = .failed
        }
    }
}
