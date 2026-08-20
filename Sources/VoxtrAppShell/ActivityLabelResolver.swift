import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// Resolves primary activity label following the canonical Vǫxtr rule:
/// `primaryActivityLabel = normalizedActivityName ?? resolvedSportDisplayName`
///
/// Semantic contract:
/// 1. normalized Activity Name, if present
/// 2. otherwise canonical Sport display name
///
/// Requirements:
/// - Activity Name wins when present
/// - whitespace-only Activity Name counts as absent
/// - Sport-only activity displays canonical Sport name
/// - stable SportId used for lookup
/// - no title/string matching
/// - no ActivityType fallback
/// - one semantic implementation across Views
@MainActor
public struct ActivityLabelResolver: Sendable {
    private let sportRepository: SportRepository?
    private let customSportLookup: (@Sendable (SportId) -> String?)?

    private static let wellKnownSportNames: [SportId: String] = [
        SportId(rawValue: UUID(uuidString: "9E3F6E9E-2B7A-4A0B-8C1D-000000000001")!): "Football",
        SportId(rawValue: UUID(uuidString: "9E3F6E9E-2B7A-4A0B-8C1D-000000000002")!): "Hockey",
        SportId(rawValue: UUID(uuidString: "9E3F6E9E-2B7A-4A0B-8C1D-000000000003")!): "Bandy"
    ]

    public init(sportRepository: SportRepository? = nil) {
        self.sportRepository = sportRepository
        self.customSportLookup = nil
    }

    public init(customSportLookup: @escaping @Sendable (SportId) -> String?) {
        self.sportRepository = nil
        self.customSportLookup = customSportLookup
    }

    /// Resolves primary activity label for a given name and sportId.
    public func primaryLabel(name: String?, sportId: SportId?) -> String {
        if let normalized = ActivityIdentity.normalizedName(name) {
            return normalized
        }
        if let sportId {
            if let customSportLookup, let resolved = customSportLookup(sportId) {
                return resolved
            }
            if let sportRepository, let sport = try? sportRepository.fetchSport(byId: sportId) {
                return sport.displayName
            }
            if let wellKnown = Self.wellKnownSportNames[sportId] {
                return wellKnown
            }
        }
        return "Activity"
    }

    public func primaryLabel(name: String?, sportIdString: String?) -> String {
        let typedSportId = sportIdString.flatMap { UUID(uuidString: $0) }.map(SportId.init(rawValue:))
        return primaryLabel(name: name, sportId: typedSportId)
    }

    public func primaryLabel(for activity: PlannedActivity) -> String {
        primaryLabel(name: activity.title, sportIdString: activity.sportId)
    }

    public func primaryLabel(for activity: LoggedActivity) -> String {
        primaryLabel(name: activity.title, sportIdString: activity.sportId)
    }

    public func primaryLabel(for activity: RecurringPlannedActivity) -> String {
        primaryLabel(name: activity.title, sportIdString: activity.sportId)
    }

    public func primaryLabel(for suggestion: RecurringActivitySuggestion) -> String {
        primaryLabel(name: suggestion.title, sportId: suggestion.sportId)
    }
}
