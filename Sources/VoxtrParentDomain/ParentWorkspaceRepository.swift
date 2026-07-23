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

    /// Creates a `ParentProfile`, a `FamilyWorkspace` owned by that
    /// parent, and a `WorkspaceParticipant` connecting them with the
    /// `workspaceOwner` role — as one unit of work. All three are
    /// inserted before the single `save()` call, so either all three
    /// persist or (if `save()` throws) none of them do.
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
        let parent = ParentProfile(
            accountId: .pending,
            givenName: givenName,
            familyName: familyName,
            preferredName: preferredName
        )
        let workspace = FamilyWorkspace(
            displayName: "\(givenName)'s family",
            technicalOwnerAccountId: .pending
        )
        let now = Date.now
        let participant = WorkspaceParticipant(
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
        try modelContext.save()

        return (parent, workspace, participant)
    }

    public func fetchAllParentProfiles() throws -> [ParentProfile] {
        try modelContext.fetch(FetchDescriptor<ParentProfile>())
    }

    public func fetchAllWorkspaces() throws -> [FamilyWorkspace] {
        try modelContext.fetch(FetchDescriptor<FamilyWorkspace>())
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
