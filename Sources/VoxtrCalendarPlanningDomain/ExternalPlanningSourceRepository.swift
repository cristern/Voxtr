import Foundation
import SwiftData
import VoxtrCoreContracts

/// Family-Owned Calendar Sources V1: insert/fetch/update
/// `ExternalPlanningSource` only — pure persistence, matching every
/// other repository in this project ("no `#Predicate`, fetch-then-
/// filter"; no cross-domain SwiftData relationships). Every fetch below
/// is scoped by `workspaceId` (except `fetch(byId:)`, matching the
/// established "fetch a single already-known ID directly, workspace
/// scoping was already applied wherever that ID was obtained" pattern
/// `AthleteRepository.fetchAthlete(byId:)` already follows) — a source
/// belonging to a DIFFERENT workspace must never be visible through
/// any workspace-scoped method here.
///
/// Lead Review follow-up (Blocker 3): there is deliberately NO physical
/// `delete(_:)` here — a source is never hard-deleted by this domain.
/// "Disconnect" is `setLifecycleStatus(_:.disconnected)`, which
/// preserves the row's stable ID (and every `CalendarImportDecision`
/// that already references it) so a later reconnect can reuse it. See
/// `ExternalPlanningSource`'s own doc comment.
@MainActor
public final class ExternalPlanningSourceRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func insert(
        workspaceId: WorkspaceId,
        providerKind: ExternalPlanningSourceProviderKind,
        externalContainerIdentifier: String,
        displayName: String
    ) throws -> ExternalPlanningSource {
        let source = ExternalPlanningSource(
            workspaceId: workspaceId,
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

    /// Every CONNECTED source for one workspace — the normal "connected
    /// calendars" list the Family Calendar Sources screen shows. A
    /// `.disconnected` source is deliberately excluded (see
    /// `ExternalPlanningSourceLifecycleStatus`'s own doc comment); use
    /// `fetch(forWorkspace:providerKind:externalContainerIdentifier:)`
    /// to look up a source regardless of lifecycle status (needed for
    /// the duplicate-check / reconnect-detection on create).
    public func fetchAllConnected(forWorkspace workspaceId: WorkspaceId) throws -> [ExternalPlanningSource] {
        let rawWorkspaceId = workspaceId.rawValue
        return try modelContext.fetch(FetchDescriptor<ExternalPlanningSource>())
            .filter { $0.workspaceId == rawWorkspaceId && $0.lifecycleStatus == .connected }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Every CONNECTED, enabled source for one workspace — the set
    /// reconciliation actually iterates on each run. A `.disconnected`
    /// source is excluded regardless of `isEnabled` (disconnect always
    /// wins — see `ExternalPlanningSourceLifecycleStatus`'s own doc
    /// comment).
    public func fetchAllEnabled(forWorkspace workspaceId: WorkspaceId) throws -> [ExternalPlanningSource] {
        let rawWorkspaceId = workspaceId.rawValue
        return try modelContext.fetch(FetchDescriptor<ExternalPlanningSource>())
            .filter { $0.workspaceId == rawWorkspaceId && $0.lifecycleStatus == .connected && $0.isEnabled }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Looks up a source by its full identity tuple — (workspace,
    /// provider, container) — regardless of `lifecycleStatus`
    /// (deliberately includes `.disconnected` rows, so both the
    /// duplicate-check on create AND reconnect-detection use this ONE
    /// lookup). A DIFFERENT workspace's source for the SAME
    /// `externalContainerIdentifier` never matches here — see
    /// `ExternalPlanningSource`'s own doc comment on why two workspaces
    /// must never collapse into one row.
    public func fetch(
        forWorkspace workspaceId: WorkspaceId,
        providerKind: ExternalPlanningSourceProviderKind,
        externalContainerIdentifier: String
    ) throws -> ExternalPlanningSource? {
        let rawWorkspaceId = workspaceId.rawValue
        return try modelContext.fetch(FetchDescriptor<ExternalPlanningSource>())
            .first {
                $0.workspaceId == rawWorkspaceId
                    && $0.providerKind == providerKind
                    && $0.externalContainerIdentifier == externalContainerIdentifier
            }
    }

    public func setEnabled(_ source: ExternalPlanningSource, isEnabled: Bool) throws {
        source.isEnabled = isEnabled
        source.updatedAt = .now
        try modelContext.save()
    }

    /// Lead Review follow-up (Blocker 3): flips `lifecycleStatus`
    /// without touching `id`, `workspaceId`, `externalContainerIdentifier`,
    /// or `isEnabled` — reconnecting later
    /// (`setLifecycleStatus(_:.connected)`, via `CalendarPlanningCoordinationService.createSource`'s
    /// own reconnect branch) restores the exact same row, never a new
    /// one. `displayName` MAY be refreshed on reconnect (the calendar
    /// may have been renamed since disconnect) — pass a non-nil
    /// `displayName` to update it, `nil` to leave it as-is.
    public func setLifecycleStatus(
        _ source: ExternalPlanningSource,
        _ lifecycleStatus: ExternalPlanningSourceLifecycleStatus,
        displayName: String? = nil
    ) throws {
        source.lifecycleStatus = lifecycleStatus
        if let displayName {
            source.displayName = displayName
        }
        source.updatedAt = .now
        try modelContext.save()
    }

    public func recordReconciliation(_ source: ExternalPlanningSource, at date: Date) throws {
        source.lastReconciledAt = date
        try modelContext.save()
    }
}
