import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// Persists and fetches `ParentProfile`, `FamilyWorkspace`, and
/// `WorkspaceParticipant` records. As of ADR-0001, `WorkspaceParticipant`
/// records are created for both guardian roles (`.workspaceOwner`) and,
/// via `createInvitedAthleteParticipant`, the `.athlete` role. This
/// repository does not create `AthleteProfile` (owned by
/// `AthleteRepository`, `VoxtrAthleteDomain`) or `AthleteAccessGrant`
/// (owned by `AthleteAccessGrantRepository`) — both remain other
/// repositories' responsibility, unchanged by ADR-0001.
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

    /// ADR-0001: creates a `WorkspaceParticipant` with `role: .athlete`,
    /// linked to `linkedAthleteId` — the mechanism ADR-0001 approves for
    /// representing an athlete acting on their own behalf. Nothing else:
    /// no invitation UI, no acceptance flow, no session binding — see
    /// the scope note below.
    ///
    /// STATE: always created in `.invited`, never `.active` — hence this
    /// method's name. Matching `createParentAndWorkspace`'s own doc
    /// comment above, which already establishes that `.invited` is the
    /// v1.3-intended default for inviting a *second* participant (unlike
    /// the self-creating parent's own participant, which has no one to
    /// invite them). Transitioning `.invited` → `.active` is acceptance,
    /// which this method never performs and which ADR-0001 explicitly
    /// defers, along with restoration/lifecycle rules for `.invited`,
    /// `.active`, `.declined`, and `.revoked` participants — none of
    /// that is decided or implemented here.
    ///
    /// `invitedBy`: the inviting guardian's own `ActorId`, derived from
    /// their existing `WorkspaceParticipant` by the caller — this method
    /// never derives an `ActorId` from `AthleteId` itself, per ADR-0001.
    ///
    /// SCOPE NOTE — the caller is responsible for, and this method does
    /// NOT verify:
    /// - that `linkedAthleteId` actually belongs to `workspaceId` (this
    ///   method persists whatever `AthleteId` it is given, unchecked);
    /// - that the inviting actor (`invitedBy`) itself belongs to, and
    ///   may act in, `workspaceId` (no authorization check is performed);
    /// - that no athlete participant already exists for this athlete
    ///   (this method does not check for or prevent duplicates).
    /// None of these policies are implemented in this task — they are
    /// named here so a future caller cannot mistake their absence for an
    /// oversight.
    ///
    /// Atomic (insert + save in one call), matching
    /// `PlanningRepository.deletePlannedActivity`'s established
    /// precedent for a single, self-contained repository operation —
    /// this is one entity, not the five-entity graph
    /// `FamilyOnboardingCoordinator` exists to coordinate, so no
    /// separate coordinator is introduced for it.
    public func createInvitedAthleteParticipant(
        id: UUID = UUID(),
        workspaceId: WorkspaceId,
        linkedAthleteId: AthleteId,
        invitedBy: ActorId
    ) throws -> WorkspaceParticipant {
        try createInvitedAthleteParticipant(
            id: id,
            workspaceId: workspaceId,
            linkedAthleteId: linkedAthleteId,
            invitedBy: invitedBy,
            saveOverride: nil
        )
    }

    /// Test-only seam, mirroring `FamilyOnboardingCoordinator`'s own
    /// established `saveOverride` pattern exactly: `@Attribute(.unique)`
    /// is upsert, not a rejecting constraint, in this project (a known,
    /// previously-documented fact), so a genuine SwiftData save failure
    /// cannot be reliably forced by a duplicate-id trick — this lets a
    /// test inject a deterministic failure at the exact point `save()`
    /// would run instead. Not `public` — reachable only via
    /// `@testable import`. Every production call site goes through the
    /// public overload above, which always passes `nil`.
    func createInvitedAthleteParticipant(
        id: UUID = UUID(),
        workspaceId: WorkspaceId,
        linkedAthleteId: AthleteId,
        invitedBy: ActorId,
        saveOverride: (() throws -> Void)?
    ) throws -> WorkspaceParticipant {
        let participant = WorkspaceParticipant(
            id: id,
            workspaceId: workspaceId,
            accountId: .pending,
            role: .athlete,
            state: .invited,
            linkedAthleteId: linkedAthleteId,
            invitedBy: invitedBy,
            invitedAt: .now
        )
        modelContext.insert(participant)
        if let saveOverride {
            try saveOverride()
        } else {
            try modelContext.save()
        }
        return participant
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

    /// VX-037 (ADR-0002): locates the current `WorkspaceParticipant`
    /// record for a specific athlete in a specific workspace,
    /// regardless of its `state`. Deliberately state-agnostic, for the
    /// same reason `fetchInvitation` was in the reverted design:
    /// distinguishing "no record at all" from "record exists but is
    /// `.active`/`.revoked`/`.declined`" is `AcceptWorkspaceInvitationService`'s
    /// job, not this repository's — it needs all of those facts to
    /// produce different results.
    public func findParticipant(forAthlete athleteId: AthleteId, workspaceId: WorkspaceId) throws -> WorkspaceParticipant? {
        let rawAthleteId = athleteId.rawValue
        let rawWorkspaceId = workspaceId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<WorkspaceParticipant>())
        return all.first { $0.role == .athlete && $0.linkedAthleteId == rawAthleteId && $0.workspaceId == rawWorkspaceId }
    }

    /// VX-037 (ADR-0002): transitions an existing `WorkspaceParticipant`
    /// from `.invited` to `.active` — a single mutation of the one
    /// aggregate that already represents the invitation, not a second
    /// entity's creation. Precondition: the caller has already
    /// confirmed `participant.state == .invited` — interpreting state
    /// is the orchestration service's responsibility, matching
    /// `markAccepted`'s precedent in the reverted design.
    public func acceptInvitation(_ participant: WorkspaceParticipant) throws {
        try acceptInvitation(participant, saveOverride: nil)
    }

    /// Test-only seam, mirroring `createInvitedAthleteParticipant`'s
    /// own `saveOverride` pattern exactly — not `public`, reachable
    /// only via `@testable import`. Every production call site goes
    /// through the public overload above, which always passes `nil`.
    ///
    /// VX-039: the leading `precondition` is the actual, minimal
    /// enforcement of `WorkspaceParticipant`'s own documented
    /// invariant — never more than one of
    /// `acceptedAt`/`declinedAt`/`revokedAt` populated at once. Every
    /// service that calls this already checks `state == .invited`
    /// first (so this never fires for any existing, correct caller);
    /// this precondition exists specifically so a caller that bypassed
    /// that check — calling this repository method directly — cannot
    /// silently corrupt the aggregate. Crashes rather than throws,
    /// matching this type's own `role != .athlete || linkedAthleteId
    /// != nil` precondition precedent: this represents a caller error,
    /// not a runtime/environment failure.
    func acceptInvitation(_ participant: WorkspaceParticipant, saveOverride: (() throws -> Void)?) throws {
        precondition(participant.state == .invited, "acceptInvitation requires state == .invited; got \(participant.state)")
        participant.state = .active
        participant.acceptedAt = .now
        if let saveOverride {
            try saveOverride()
        } else {
            try modelContext.save()
        }
    }

    /// VX-038/VX-039: transitions an existing `WorkspaceParticipant`
    /// from `.invited` to `.declined` — a single mutation of the one
    /// aggregate that already represents the invitation, matching
    /// `acceptInvitation`'s established shape. Precondition: the
    /// caller has already confirmed `participant.state == .invited` —
    /// interpreting state is the orchestration service's
    /// responsibility, not this repository's.
    ///
    /// VX-039: sets `declinedAt`, a real field on `WorkspaceParticipant`
    /// as of this change — correcting an earlier version of this
    /// method that reused the generic `updatedAt` field because no
    /// dedicated one existed yet. That absence was determined to be a
    /// gap in the aggregate, not a deliberate omission, so it was
    /// closed rather than worked around.
    public func declineInvitation(_ participant: WorkspaceParticipant) throws {
        try declineInvitation(participant, saveOverride: nil)
    }

    /// Test-only seam, mirroring `acceptInvitation`'s own
    /// `saveOverride` pattern exactly. See `acceptInvitation`'s own
    /// doc comment for why the leading `precondition` exists.
    func declineInvitation(_ participant: WorkspaceParticipant, saveOverride: (() throws -> Void)?) throws {
        precondition(participant.state == .invited, "declineInvitation requires state == .invited; got \(participant.state)")
        participant.state = .declined
        participant.declinedAt = .now
        if let saveOverride {
            try saveOverride()
        } else {
            try modelContext.save()
        }
    }

    /// VX-038: transitions an existing `WorkspaceParticipant` from
    /// `.invited` to `.revoked` — a single mutation of the one
    /// aggregate that already represents the invitation, matching
    /// `acceptInvitation`'s established shape. Precondition: the
    /// caller has already confirmed `participant.state == .invited` —
    /// interpreting state is the orchestration service's
    /// responsibility, not this repository's.
    public func revokeInvitation(_ participant: WorkspaceParticipant) throws {
        try revokeInvitation(participant, saveOverride: nil)
    }

    /// Test-only seam, mirroring `acceptInvitation`'s own
    /// `saveOverride` pattern exactly. See `acceptInvitation`'s own
    /// doc comment for why the leading `precondition` exists.
    func revokeInvitation(_ participant: WorkspaceParticipant, saveOverride: (() throws -> Void)?) throws {
        precondition(participant.state == .invited, "revokeInvitation requires state == .invited; got \(participant.state)")
        participant.state = .revoked
        participant.revokedAt = .now
        if let saveOverride {
            try saveOverride()
        } else {
            try modelContext.save()
        }
    }

    /// VX-038: returns every `WorkspaceParticipant` in a workspace
    /// currently `.invited` — the pending invitations awaiting a
    /// response. Built on `fetchParticipants(forWorkspace:)`, the
    /// existing unscoped-by-state fetch, filtered in Swift — matching
    /// this repository's own established fetch-then-filter convention
    /// (see that method's own doc comment on why `#Predicate` is
    /// avoided here).
    public func fetchPendingParticipants(forWorkspace workspaceId: WorkspaceId) throws -> [WorkspaceParticipant] {
        try fetchParticipants(forWorkspace: workspaceId).filter { $0.state == .invited }
    }

    /// VX-038: returns every `WorkspaceParticipant` in a workspace
    /// currently `.active` — standing membership, as opposed to
    /// pending invitations or resolved (declined/revoked) ones.
    public func fetchActiveParticipants(forWorkspace workspaceId: WorkspaceId) throws -> [WorkspaceParticipant] {
        try fetchParticipants(forWorkspace: workspaceId).filter { $0.state == .active }
    }
}
