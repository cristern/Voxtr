import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// S1.2 scope only: creates and fetches `AthleteAccessGrant`, connecting
/// a `WorkspaceParticipant` (parent) to an `AthleteProfile`. Owned by
/// the Parent domain per v1.3 Section 7.5.
///
/// No `#Predicate` usage — S1.1's `ParentWorkspaceRepository` hit a real
/// Swift Testing crash traced to that macro; every fetch method in this
/// repository fetches then filters in plain Swift instead.
@MainActor
public final class AthleteAccessGrantRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Creates a grant with every permission `true` — the approved
    /// default for the onboarding parent's own grant to the athlete
    /// they just created (workspace owner, full access to their own
    /// newly-created athlete). This is the only grant-creation method
    /// S1.2 implements; a method for creating a grant with partial
    /// permissions (e.g. for a second guardian later) is not built here
    /// — out of scope.
    public func createFullAccessGrant(
        workspaceId: WorkspaceId,
        participantId: UUID,
        athleteId: AthleteId
    ) throws -> AthleteAccessGrant {
        let grant = AthleteAccessGrant(
            workspaceId: workspaceId,
            participantId: participantId,
            athleteId: athleteId,
            canViewSchedule: true,
            canEditDraftPlans: true,
            canCommitPlans: true,
            canViewSharedReflections: true,
            canViewDevelopmentInsights: true
        )
        modelContext.insert(grant)
        try modelContext.save()
        return grant
    }

    public func fetchGrants(forAthlete athleteId: AthleteId) throws -> [AthleteAccessGrant] {
        let rawId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<AthleteAccessGrant>())
        return all.filter { $0.athleteId == rawId }
    }
}
