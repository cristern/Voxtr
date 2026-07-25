import Foundation
import VoxtrCoreContracts

/// Sprint 8: semantic emphasis only — not a color, font, or SF Symbol.
/// Deliberately just three cases, matching the coaching architecture's
/// own examples exactly; nothing here names a UI treatment, that
/// decision belongs to whatever renders `CoachingPresentation` later.
public enum CoachingPresentationEmphasis: Sendable, Equatable, CaseIterable {
    case neutral
    case positive
    case attention
}

/// Sprint 8: one presentation-ready line derived from exactly one
/// `CoachingInsight`. `insight` is kept for traceability back to the
/// finding that produced this item — the same way `CoachingResult`
/// itself keeps `athleteId`/`weekStart` for traceability back to the
/// `WeeklyCoachingContext` it came from. Carrying it forward is not a
/// new domain rule; it is the same fact the mapper already consumed.
public struct CoachingPresentationItem: Sendable, Equatable {
    public let insight: CoachingInsight
    public let text: String
    public let emphasis: CoachingPresentationEmphasis

    public init(insight: CoachingInsight, text: String, emphasis: CoachingPresentationEmphasis) {
        self.insight = insight
        self.text = text
        self.emphasis = emphasis
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
