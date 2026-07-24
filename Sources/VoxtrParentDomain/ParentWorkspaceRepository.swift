import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// S1.1 scope only: creates and fetches `ParentProfile`, `FamilyWorkspace`,
/// and `WorkspaceParticipant`. Athlete creation and `AthleteAccessGrant`
/// are explicitly out of scope for this story (S1.2) — this repository
/// does not touch either.
///
/// `@MainActor` because `ModelContext` is not `Sendable` and this
/// repository is built from `ModelContainer.mainContext` — all Sprint 1
/// UI work runs on the main actor anyway, so this isn't a new
/// constraint, just an explicit one.
@MainActor
public final class ParentWorkspaceRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// S1.2a: stages a `ParentProfile`, `FamilyWorkspace`, and
    /// `WorkspaceParticipant` into this repository's `ModelContext` —
    /// INSERTS ONLY, NO SAVE. Used when this creation must be part of a
    /// larger atomic operation spanning multiple domains (see
    /// `FamilyOnboardingCoordinator`), which controls save/rollback on
    /// the shared context itself. Callers using this directly are
    /// responsible for eventually calling `save()` or `rollback()` on
    /// the same context — this method does neither.
    ///
    /// `parentId`/`workspaceId`/`participantId` are injectable (default
    /// to fresh IDs) so tests can force a genuine SwiftData uniqueness
    /// violation at `save()` time, rather than simulating one.
    public func stageParentAndWorkspace(
        parentId: UUID = UUID(),
        workspaceId: WorkspaceId = WorkspaceId(),
        participantId: UUID = UUID(),
        givenName: String,
        familyName: String? = nil,
        preferredName: String? = nil
    ) -> (parent: ParentProfile, workspace: FamilyWorkspace, participant: WorkspaceParticipant) {
        let parent = ParentProfile(
            id: parentId,
            accountId: .pending,
            givenName: givenName,
            familyName: familyName,
            preferredName: preferredName
        )
        let workspace = FamilyWorkspace(
            id: workspaceId,
            displayName: "\(givenName)'s family",
            technicalOwnerAccountId: .pending
        )
        let now = Date.now
        let participant = WorkspaceParticipant(
            id: participantId,
            workspaceId: workspace.workspaceId,
            accountId: .pending,
            role: .workspaceOwner,
            state: .active,
            invitedAt: now,
            acceptedAt: now
        )

        modelContext.insert(parent)
        modelContext.insert(workspace)
        modelContext.insert(participant)

        return (parent, workspace, participant)
    }

    /// Standalone convenience: stage + save in one call, as its own
    /// atomic unit. Preserved for any caller that only needs to create a
    /// parent/workspace on its own — NOT used by
    /// `FamilyOnboardingCoordinator`, which stages via the method above
    /// and controls save/rollback itself across all five entities.
    ///
    /// ASSUMPTION, FLAGGED: the participant record for the
    /// self-creating parent is created directly in `.active` state with
    /// `invitedAt`/`acceptedAt` both set to now — there is no one to
    /// invite them, they're creating the workspace themselves. v1.3's
    /// `WorkspaceParticipant` default (`state: .invited`) is written for
    /// the general case of inviting a second guardian later, not this
    /// one. Flagging as a modeling choice, not a v1.3 requirement.
    ///
    /// AccountId: uses `AccountId.pending` throughout (see
    /// `VoxtrCoreContracts.Identifier.swift`) — CloudKit account
    /// resolution doesn't exist yet.
    public func createParentAndWorkspace(
        givenName: String,
        familyName: String? = nil,
        preferredName: String? = nil
    ) throws -> (parent: ParentProfile, workspace: FamilyWorkspace, participant: WorkspaceParticipant) {
        let staged = stageParentAndWorkspace(givenName: givenName, familyName: familyName, preferredName: preferredName)
        try modelContext.save()
        return staged
    }

    public func fetchAllParentProfiles() throws -> [ParentProfile] {
        try modelContext.fetch(FetchDescriptor<ParentProfile>())
    }

    public func fetchAllWorkspaces() throws -> [FamilyWorkspace] {
        try modelContext.fetch(FetchDescriptor<FamilyWorkspace>())
    }

    /// S1.3: unscoped — returns every `WorkspaceParticipant` regardless
    /// of workspace. Needed so restoration consistency checks can detect
    /// an orphaned participant even when its workspace is itself
    /// missing (a scoped-by-workspace-id query can't find what it
    /// doesn't have a workspace ID for).
    public func fetchAllParticipants() throws -> [WorkspaceParticipant] {
        try modelContext.fetch(FetchDescriptor<WorkspaceParticipant>())
    }

    /// S1.1 FIX: this originally used SwiftData's `#Predicate` macro
    /// (`FetchDescriptor<WorkspaceParticipant>(predicate: #Predicate {
    /// $0.workspaceId == rawId })`). The CI test run crashed
    /// ("Restarting after unexpected exit, crash, or test timeout")
    /// right as this suite started, immediately after every other suite
    /// — including one exercising the same `AppSchema` — passed cleanly.
    /// `#Predicate` was the one genuinely new pattern in this file, and
    /// has documented real-world runtime crash edge cases on some
    /// Xcode/OS combinations. Without a crash log to confirm the exact
    /// cause, the lowest-risk fix is removing the suspect code entirely
    /// rather than guessing at a `#Predicate` workaround: fetch
    /// everything and filter in Swift. Fine at this data scale (a
    /// handful of participants per family); revisit if/when this
    /// becomes a real performance concern.
    public func fetchParticipants(forWorkspace workspaceId: WorkspaceId) throws -> [WorkspaceParticipant] {
        let rawId = workspaceId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<WorkspaceParticipant>())
        return all.filter { $0.workspaceId == rawId }
    }
}
