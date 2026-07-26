import Foundation
import VoxtrCoreContracts
import VoxtrCoachingDomain

/// Sprint 8: semantic emphasis only — not a color, font, or SF Symbol.
/// Deliberately just three cases, matching the coaching architecture's
/// own examples exactly; nothing here names a UI treatment, that
/// decision belongs to whatever renders `CoachingPresentation` later.
public enum CoachingPresentationEmphasis: Sendable, Equatable, CaseIterable {
    case neutral
    case positive
    case attention
}

/// Sprint 10: a pure value type naming which user action, if any, goes
/// with one `CoachingPresentationItem`. Contains no button, no
/// navigation, no closure, no SwiftUI — just an identity the UI later
/// decides how to render and the ViewModel decides how to fulfill.
/// `CoachingEngine`/`CoachingResult` know nothing of this type; it is
/// assigned entirely by `CoachingPresentationMapper`.
///
/// Deliberately only three cases, not the full example list the sprint
/// suggested (`acknowledge`/`remindLater` were also offered as
/// examples). Neither of those two has any backing capability anywhere
/// in this project yet — no dismissal-tracking, no reminder/scheduling
/// mechanism (notifications are an explicit non-goal) — and adding
/// enum cases nothing ever produces or fulfills is exactly the kind of
/// speculative surface this project has already flagged as a repeated
/// mistake elsewhere (see `EventBus`, defined for 23 events with zero
/// real publishers for several sprints). Add them when an actual
/// workflow exists for either, not before.
public enum CoachingPresentationAction: Sendable, Equatable {
    /// No action accompanies this item. Per Sprint 10's own framing,
    /// this is a normal, valid outcome — not every finding needs one.
    case none
    /// Backed by the existing `WeeklyReflectionFormView` flow
    /// (Sprint 5.2/9) — a real, already-functional workflow, not a new
    /// one introduced by this sprint.
    case startWeeklyReflection
    /// No creation UI exists yet for this action (verified before
    /// implementing — there is no parent-observation-authoring screen
    /// anywhere in this project). Exposed here per Sprint 10's explicit
    /// instruction to surface an action even before its feature exists,
    /// while keeping the UI implementation itself minimal rather than
    /// building the missing workflow now.
    case addParentObservation
}

/// Sprint 8: one presentation-ready line derived from exactly one
/// `CoachingInsight`. `insight` is kept for traceability back to the
/// finding that produced this item — the same way `CoachingResult`
/// itself keeps `athleteId`/`weekStart` for traceability back to the
/// `WeeklyCoachingContext` it came from. Carrying it forward is not a
/// new domain rule; it is the same fact the mapper already consumed.
///
/// Sprint 10: added `action`. Which action (if any) belongs to which
/// insight is a presentation-mapping decision, assigned once, in
/// `CoachingPresentationMapper` — never decided by the view that
/// renders this item.
public struct CoachingPresentationItem: Sendable, Equatable {
    public let insight: CoachingInsight
    public let text: String
    public let emphasis: CoachingPresentationEmphasis
    public let action: CoachingPresentationAction

    public init(
        insight: CoachingInsight,
        text: String,
        emphasis: CoachingPresentationEmphasis,
        action: CoachingPresentationAction
    ) {
        self.insight = insight
        self.text = text
        self.emphasis = emphasis
        self.action = action
    }
}

/// Sprint 8: a named group of presentation items. Section titles group
/// insights by the same three existing categories `WeeklyCoachingContext`
/// already has (planned activities, weekly reflection, parent
/// observations) — this organizes already-established categories for
/// display, it does not introduce a new one.
public struct CoachingPresentationSection: Sendable, Equatable {
    public let title: String
    public let items: [CoachingPresentationItem]

    public init(title: String, items: [CoachingPresentationItem]) {
        self.title = title
        self.items = items
    }
}

/// Sprint 8: the mapper's complete output for one athlete/week — the
/// final stage before UI. No SwiftUI dependency, no persistence model,
/// no business logic: only sections and items, each already carrying
/// its own presentation text and semantic emphasis.
///
/// A `CoachingResult` with no insights maps to `sections: []` — a
/// genuinely empty, valid presentation, not a synthesized "everything
/// looks good" message. `CoachingPresentationMapper` never invents a
/// finding `CoachingResult` didn't already represent.
public struct CoachingPresentation: Sendable, Equatable {
    public let athleteId: AthleteId
    public let weekStart: LocalDate
    public let sections: [CoachingPresentationSection]

    public init(athleteId: AthleteId, weekStart: LocalDate, sections: [CoachingPresentationSection]) {
        self.athleteId = athleteId
        self.weekStart = weekStart
        self.sections = sections
    }
}
