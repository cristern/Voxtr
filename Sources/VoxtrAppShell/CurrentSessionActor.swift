import Foundation
import VoxtrCoreContracts
import VoxtrParentDomain

/// Athlete Connection Foundation A: answers exactly one question —
/// "which `WorkspaceParticipant` is acting in this app session?" —
/// replacing the direct, duplicated `ActorId(rawValue:
/// family.participant.id)` construction that previously appeared at
/// every AppShell business-mutation call site. Introduced so ParentApp
/// (today) and a future AthleteApp session (later) can both produce
/// this same shape without either one inventing its own actor-identity
/// convention.
///
/// Deliberately NOT derived from the currently-selected `AthleteProfile`,
/// screen state, navigation, or timing — it is always resolved once,
/// explicitly, from an already-restored `WorkspaceParticipant` (see
/// `RestoredFamily.currentActor`), and handed down as plain data from
/// there. Selecting a different athlete to view/edit never changes which
/// participant is acting.
public struct CurrentSessionActor: Sendable, Equatable {
    /// The stable `WorkspaceParticipant.id` this actor resolves to.
    public let participantId: UUID
    /// The workspace this participant belongs to — every mutation this
    /// actor performs is scoped to this workspace.
    public let workspaceId: WorkspaceId
    public let role: WorkspaceRole
    /// Set only for an `.athlete`-role participant — `nil` for the
    /// workspace owner. Exposed so a future Athlete session can resolve
    /// which `AthleteProfile` this actor speaks for, without this type
    /// hardcoding any assumption about what role is "the" production
    /// actor.
    public let linkedAthleteId: AthleteId?

    public init(
        participantId: UUID,
        workspaceId: WorkspaceId,
        role: WorkspaceRole,
        linkedAthleteId: AthleteId? = nil
    ) {
        self.participantId = participantId
        self.workspaceId = workspaceId
        self.role = role
        self.linkedAthleteId = linkedAthleteId
    }

    /// The one, canonical way this actor is represented at every
    /// domain/service mutation boundary that takes an `ActorId` —
    /// `WorkspaceParticipant.id` reinterpreted as the typed ID v1.3
    /// Section 18 defines for exactly this purpose ("ActorId references
    /// WorkspaceParticipant").
    public var actorId: ActorId { ActorId(rawValue: participantId) }

    /// Resolves a `CurrentSessionActor` from an already-restored
    /// `WorkspaceParticipant` — works identically for a `.workspaceOwner`
    /// or an `.athlete` participant, so this is also the seam a future
    /// Athlete session resolves through; nothing about this factory
    /// assumes which role is calling it.
    public static func resolve(from participant: WorkspaceParticipant) -> CurrentSessionActor {
        CurrentSessionActor(
            participantId: participant.id,
            workspaceId: WorkspaceId(rawValue: participant.workspaceId),
            role: participant.role,
            linkedAthleteId: participant.linkedAthleteId.map { AthleteId(rawValue: $0) }
        )
    }
}
