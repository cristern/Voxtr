import Foundation
import VoxtrCoreContracts

/// Sprint 8: converts a `CoachingResult` into a `CoachingPresentation`.
/// Pure and stateless — a `struct` with no stored properties, same
/// reasoning `CoachingEngine` already established: nothing to inject,
/// nothing to hold, so no class and no actor isolation needed.
///
/// This type supplies presentation TEXT (the one thing `CoachingEngine`/
/// `CoachingResult` are explicitly forbidden from containing) but
/// invents no new FACTS. Every `CoachingPresentationItem` traces back
/// to exactly one `CoachingInsight` already present in the input
/// `CoachingResult` — the `switch` in `map(_:)` below is exhaustive
/// over `CoachingInsight`'s cases (enforced by the compiler, since
/// `CoachingInsight` is `CaseIterable` and no `default:` is used), so
/// this file cannot silently drop or invent a finding: adding, removing,
/// or renaming a case in `CoachingResult.swift` without updating this
/// mapper is a compile error, not a silent behavior change.
///
/// SECTION GROUPING: the three section titles below group insights by
/// the three categories `WeeklyCoachingContext` already has (planned
/// activities, weekly reflection, parent observations) — this is
/// presentation organization of already-established categories, not a
/// new coaching rule. Section order is fixed (Planned Activities →
/// Weekly Reflection → Parent Observations) regardless of the order
/// insights appear in `CoachingResult.insights` — this is still
/// deterministic (the same input always produces the same output), it
/// just doesn't mirror `CoachingResult`'s own ordering, which groups by
/// evaluation sequence rather than by topic. A section is included only
/// if it has at least one item — this is what makes the empty-result
/// case (`sections: []`) fall out naturally, with no special-casing.
///
/// WORDING: the specific strings below are this mapper's own choice —
/// plain, factual, and neutral in tone (no exclamation points, no
/// motivational framing) — matching "supplies user-facing wording,"
/// not "generates coaching language." EMPHASIS CHOICES are also this
/// mapper's own judgment, not a new threshold: missing a weekly
/// reflection is marked `.attention` because the product constitution
/// already names weekly reflection as required/central ("reflection
/// drives learning"), while the presence or absence of optional parent
/// observations is marked `.neutral` either way, since neither state is
/// established anywhere as more or less desirable than the other.
///
/// Sprint 10: ACTION ASSIGNMENT is this mapper's responsibility too —
/// deciding which `CoachingPresentationAction` (if any) belongs to
/// which insight is presentation mapping, the same category of decision
/// as choosing text or emphasis, not a new business rule. Only two
/// insights get a real action (`noWeeklyReflection` →
/// `.startWeeklyReflection`, `noParentObservations` →
/// `.addParentObservation`); every other insight gets `.none` — a
/// finding not needing an action is a normal, valid outcome, not a gap.
public struct CoachingPresentationMapper: Sendable {
    public init() {}

    public func map(_ result: CoachingResult) -> CoachingPresentation {
        var plannedActivityItems: [CoachingPresentationItem] = []
        var weeklyReflectionItems: [CoachingPresentationItem] = []
        var parentObservationItems: [CoachingPresentationItem] = []

        for insight in result.insights {
            switch insight {
            case .allPlannedActivitiesCompleted:
                plannedActivityItems.append(CoachingPresentationItem(
                    insight: insight,
                    text: "All planned activities were completed this week.",
                    emphasis: .positive,
                    action: .none
                ))
            case .somePlannedActivitiesMissed:
                plannedActivityItems.append(CoachingPresentationItem(
                    insight: insight,
                    text: "Some planned activities were not completed this week.",
                    emphasis: .attention,
                    action: .none
                ))
            case .noWeeklyReflection:
                weeklyReflectionItems.append(CoachingPresentationItem(
                    insight: insight,
                    text: "No weekly reflection was recorded.",
                    emphasis: .attention,
                    action: .startWeeklyReflection
                ))
            case .weeklyReflectionCompleted:
                weeklyReflectionItems.append(CoachingPresentationItem(
                    insight: insight,
                    text: "A weekly reflection was recorded.",
                    emphasis: .positive,
                    action: .none
                ))
            case .noParentObservations:
                parentObservationItems.append(CoachingPresentationItem(
                    insight: insight,
                    text: "No parent observations were recorded this week.",
                    emphasis: .neutral,
                    action: .addParentObservation
                ))
            case .parentObservationsPresent:
                parentObservationItems.append(CoachingPresentationItem(
                    insight: insight,
                    text: "Parent observations were recorded this week.",
                    emphasis: .neutral,
                    action: .none
                ))
            }
        }

        var sections: [CoachingPresentationSection] = []
        if !plannedActivityItems.isEmpty {
            sections.append(CoachingPresentationSection(title: "Planned Activities", items: plannedActivityItems))
        }
        if !weeklyReflectionItems.isEmpty {
            sections.append(CoachingPresentationSection(title: "Weekly Reflection", items: weeklyReflectionItems))
        }
        if !parentObservationItems.isEmpty {
            sections.append(CoachingPresentationSection(title: "Parent Observations", items: parentObservationItems))
        }

        return CoachingPresentation(athleteId: result.athleteId, weekStart: result.weekStart, sections: sections)
    }
}
