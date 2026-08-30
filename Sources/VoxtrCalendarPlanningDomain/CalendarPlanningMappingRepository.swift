import Foundation
import SwiftData
import VoxtrCoreContracts

/// Calendar Planning Source V1: insert/fetch/update/delete
/// `CalendarPlanningMapping` only — pure persistence, matching every
/// other repository in this project ("no `#Predicate`, fetch-then-
/// filter"; no cross-domain SwiftData relationships).
@MainActor
public final class CalendarPlanningMappingRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func insert(
        athleteId: AthleteId,
        calendarIdentifier: String,
        calendarTitle: String,
        activityType: ActivityType,
        sportId: SportId?
    ) throws -> CalendarPlanningMapping {
        let mapping = CalendarPlanningMapping(
            athleteId: athleteId,
            calendarIdentifier: calendarIdentifier,
            calendarTitle: calendarTitle,
            activityType: activityType,
            sportId: sportId
        )
        modelContext.insert(mapping)
        try modelContext.save()
        return mapping
    }

    public func fetch(byId id: CalendarPlanningMappingId) throws -> CalendarPlanningMapping? {
        let rawId = id.rawValue
        return try modelContext.fetch(FetchDescriptor<CalendarPlanningMapping>()).first { $0.id == rawId }
    }

    public func fetchAll(forAthlete athleteId: AthleteId) throws -> [CalendarPlanningMapping] {
        let rawId = athleteId.rawValue
        return try modelContext.fetch(FetchDescriptor<CalendarPlanningMapping>())
            .filter { $0.athleteId == rawId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Every enabled mapping, across every athlete — the set
    /// reconciliation actually iterates on each run.
    public func fetchAllEnabled() throws -> [CalendarPlanningMapping] {
        try modelContext.fetch(FetchDescriptor<CalendarPlanningMapping>())
            .filter(\.isEnabled)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func update(
        _ mapping: CalendarPlanningMapping,
        activityType: ActivityType,
        sportId: SportId?
    ) throws -> CalendarPlanningMapping {
        mapping.activityType = activityType
        mapping.sportId = sportId?.rawValue
        mapping.updatedAt = .now
        try modelContext.save()
        return mapping
    }

    public func setEnabled(_ mapping: CalendarPlanningMapping, isEnabled: Bool) throws {
        mapping.isEnabled = isEnabled
        mapping.updatedAt = .now
        try modelContext.save()
    }

    public func recordReconciliation(_ mapping: CalendarPlanningMapping, at date: Date) throws {
        mapping.lastReconciledAt = date
        try modelContext.save()
    }

    public func delete(_ mapping: CalendarPlanningMapping) throws {
        modelContext.delete(mapping)
        try modelContext.save()
    }
}
