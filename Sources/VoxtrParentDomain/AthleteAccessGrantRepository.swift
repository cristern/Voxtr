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

    /// S1.2a: stages an `AthleteAccessGrant` into this repository's
    /// `ModelContext` — INSERT ONLY, NO SAVE. Used when this creation
    /// must be part of a larger atomic operation spanning multiple
    /// domains (see `FamilyOnboardingCoordinator`). `grantId` is
    /// injectable (defaults to a fresh ID) so tests can force a genuine
    /// SwiftData uniqueness violation at `save()` time.
    ///
    /// Every permission is `true` — the approved default for the
    /// onboarding parent's own grant to the athlete they just created.
    public func stageFullAccessGrant(
        grantId: UUID = UUID(),
        workspaceId: WorkspaceId,
        participantId: UUID,
        athleteId: AthleteId
    ) -> AthleteAccessGrant {
        let grant = AthleteAccessGrant(
            id: grantId,
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
        return grant
    }

    /// Standalone convenience: stage + save in one call. Preserved for
    /// any caller that only needs to create a grant on its own — NOT
    /// used by `FamilyOnboardingCoordinator`, which stages via the
    /// method above and controls save/rollback itself. This is still
    /// the only grant-creation method in S1.2 — a method for partial
    /// permissions (e.g. a second guardian later) is not built here.
    public func createFullAccessGrant(
        workspaceId: WorkspaceId,
        participantId: UUID,
        athleteId: AthleteId
    ) throws -> AthleteAccessGrant {
        let grant = stageFullAccessGrant(workspaceId: workspaceId, participantId: participantId, athleteId: athleteId)
        try modelContext.save()
        return grant
    }

    public func fetchGrants(forAthlete athleteId: AthleteId) throws -> [AthleteAccessGrant] {
        let rawId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<AthleteAccessGrant>())
        return all.filter { $0.athleteId == rawId }
    }

    /// S1.3: unscoped — returns every `AthleteAccessGrant` regardless of
    /// athlete. Needed so restoration consistency checks can detect an
    /// orphaned grant even when its athlete is itself missing.
    public func fetchAllGrants() throws -> [AthleteAccessGrant] {
        try modelContext.fetch(FetchDescriptor<AthleteAccessGrant>())
    }
}
