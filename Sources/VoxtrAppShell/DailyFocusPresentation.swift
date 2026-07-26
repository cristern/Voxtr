import Foundation
import VoxtrCoreContracts

/// Sprint 13: identifies which existing output a `DailyFocusPresentation`
/// was composed from — the same kind of traceability
/// `CoachingPresentationItem.insight` already provides, not a new
/// concept. Exists so a consumer (or a test) can tell "this focus came
/// from today's training" apart from "this focus came from coaching"
/// without re-deriving it from the title/subtitle text.
public enum DailyFocusSource: Sendable, Equatable {
    case todaysTraining
    case coaching
}

/// Sprint 13: the one thing Daily Focus highlights for today. A
/// presentation-only value type — not a domain model, never persisted.
///
/// `action` reuses `CoachingPresentationAction` directly and is
/// deliberately NOT `CoachingPresentationAction?`. That type already
/// has an explicit `.none` case representing "no action" (Sprint 10),
/// and wrapping an already-non-optional enum with its own `.none` case
/// in `Optional` is exactly the ambiguity that caused a real test
/// failure earlier in this project (`Optional<T>.none` vs `T.none`
/// colliding under `==`) — reusing the type as-is, unwrapped, avoids
/// reintroducing that same class of bug here.
public struct DailyFocusPresentation: Sendable, Equatable {
    public let title: String
    public let subtitle: String
    public let action: CoachingPresentationAction
    public let source: DailyFocusSource

    public init(title: String, subtitle: String, action: CoachingPresentationAction, source: DailyFocusSource) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.source = source
    }
}
