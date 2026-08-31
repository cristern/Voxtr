import Foundation
import SwiftData
import VoxtrCoreContracts

/// Family-Owned Calendar Sources V1: insert/fetch/update/delete
/// `ExternalPlanningSource` only — pure persistence, matching every
/// other repository in this project ("no `#Predicate`, fetch-then-
/// filter"; no cross-domain SwiftData relationships).
@MainActor
public final class ExternalPlanningSourceRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func insert(
        providerKind: ExternalPlanningSourceProviderKind,
        externalContainerIdentifier: String,
        displayName: String
    ) throws -> ExternalPlanningSource {
        let source = ExternalPlanningSource(
            providerKind: providerKind,
            externalContainerIdentifier: externalContainerIdentifier,
            displayName: displayName
        )
        modelContext.insert(source)
        try modelContext.save()
        return source
    }

    public func fetch(byId id: ExternalPlanningSourceId) throws -> ExternalPlanningSource? {
        let rawId = id.rawValue
        return try modelContext.fetch(FetchDescriptor<ExternalPlanningSource>()).first { $0.id == rawId }
    }

    /// Every family source — this app has no per-athlete scoping to
    /// apply, unlike the legacy `CalendarPlanningMappingRepository.fetchAll(forAthlete:)`
    /// it replaces; a source belongs to the family, not to one athlete.
    public func fetchAll() throws -> [ExternalPlanningSource] {
        try modelContext.fetch(FetchDescriptor<ExternalPlanningSource>())
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Every enabled source — the set reconciliation actually iterates
    /// on each run.
    public func fetchAllEnabled() throws -> [ExternalPlanningSource] {
        try modelContext.fetch(FetchDescriptor<ExternalPlanningSource>())
            .filter(\.isEnabled)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func fetch(byExternalContainerIdentifier externalContainerIdentifier: String) throws -> ExternalPlanningSource? {
        try modelContext.fetch(FetchDescriptor<ExternalPlanningSource>())
            .first { $0.externalContainerIdentifier == externalContainerIdentifier }
    }

    public func setEnabled(_ source: ExternalPlanningSource, isEnabled: Bool) throws {
        source.isEnabled = isEnabled
        source.updatedAt = .now
        try modelContext.save()
    }

    public func recordReconciliation(_ source: ExternalPlanningSource, at date: Date) throws {
        source.lastReconciledAt = date
        try modelContext.save()
    }

    public func delete(_ source: ExternalPlanningSource) throws {
        modelContext.delete(source)
        try modelContext.save()
    }
}
