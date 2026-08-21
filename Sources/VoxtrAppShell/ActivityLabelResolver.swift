import Foundation
import SwiftData
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// Resolves primary activity label following the canonical Vǫxtr rule:
/// `primaryActivityLabel = normalizedActivityName ?? resolvedSportDisplayName`
///
/// Semantic contract:
/// 1. normalized Activity Name, if present
/// 2. otherwise canonical Sport display name from `SportRepository` / `Sport`
///
/// Requirements:
/// - Activity Name wins when present
/// - whitespace-only Activity Name counts as absent
/// - Sport-only activity displays canonical Sport name
/// - stable SportId used for lookup
/// - no title/string matching
/// - no ActivityType fallback
/// - no second/hardcoded Sport truth map
/// - one semantic implementation across Views
@MainActor
public struct ActivityLabelResolver: Sendable {
    private let sportRepository: SportRepository?
    private let customSportLookup: (@Sendable (SportId) -> String?)?

    public init(sportRepository: SportRepository? = nil) {
        self.sportRepository = sportRepository
        self.customSportLookup = nil
    }

    public init(modelContext: ModelContext) {
        self.sportRepository = SportRepository(modelContext: modelContext)
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
        if let sportId, let sportLabel = resolvedSportLabel(for: sportId) {
            return sportLabel
        }
        return "Activity"
    }

    /// Factual secondary identity, never a replacement primary label.
    /// A named activity can show its Sport and Type; when Sport is the
    /// primary label, Type remains the only secondary classification.
    public func metadataLabel(name: String?, sportId: SportId?, activityType: ActivityType) -> String {
        if ActivityIdentity.normalizedName(name) != nil,
           let sportId,
           let sportLabel = resolvedSportLabel(for: sportId) {
            return "\(sportLabel) · \(activityType.displayName)"
        }
        return activityType.displayName
    }

    public func primaryLabel(for activity: PlannedActivity) -> String {
        primaryLabel(name: activity.title, sportId: activity.sportId.map(SportId.init(rawValue:)))
    }

    public func primaryLabel(for activity: LoggedActivity) -> String {
        primaryLabel(name: activity.title, sportId: activity.sportId.map(SportId.init(rawValue:)))
    }

    public func primaryLabel(for activity: RecurringPlannedActivity) -> String {
        primaryLabel(name: activity.title, sportId: activity.sportId.map(SportId.init(rawValue:)))
    }

    public func primaryLabel(for suggestion: RecurringActivitySuggestion) -> String {
        primaryLabel(name: suggestion.title, sportId: suggestion.sportId)
    }

    public func metadataLabel(for activity: PlannedActivity) -> String {
        metadataLabel(
            name: activity.title,
            sportId: activity.sportId.map(SportId.init(rawValue:)),
            activityType: activity.activityType
        )
    }

    public func metadataLabel(for activity: LoggedActivity) -> String {
        metadataLabel(
            name: activity.title,
            sportId: activity.sportId.map(SportId.init(rawValue:)),
            activityType: activity.activityType
        )
    }

    public func metadataLabel(for activity: RecurringPlannedActivity) -> String {
        metadataLabel(
            name: activity.title,
            sportId: activity.sportId.map(SportId.init(rawValue:)),
            activityType: activity.activityType
        )
    }

    private func resolvedSportLabel(for sportId: SportId) -> String? {
        if let customSportLookup, let resolved = customSportLookup(sportId) {
            return resolved
        }
        if let sportRepository, let sport = try? sportRepository.fetchSport(byId: sportId) {
            return sport.displayName
        }
        return nil
    }
}
