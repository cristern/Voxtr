import CloudKit
import VoxtrCore
import VoxtrCoreContracts
import VoxtrParentDomain

/// Athlete Connection Foundation B2.6: the ONE ParentApp-side
/// orchestration service that turns "Parent selects an existing
/// `AthleteProfile` and taps Connect Athlete App" into a real, native
/// CloudKit share invite — the owner-side counterpart to
/// `AthleteConnectionLifecycleService` (B2.5, Athlete-side).
///
/// SCOPE: this is the smallest legitimate slice that gets a real
/// `FamilyWorkspace` `CKShare` in front of the Parent's native iOS share
/// sheet, carrying enough information for the Athlete-side chain
/// (B2.2 → acceptance → B2.3 → B2.4) to resolve back to the EXACT
/// `WorkspaceParticipant`/`AthleteProfile` this action intended — never a
/// heuristically-chosen one. It does NOT present any UI itself (see
/// `CloudSharingPresenter`), does NOT decide participant permissions
/// beyond what B2.1's `ensureSharingRoot` already establishes, and does
/// NOT build any custom email/SMS delivery — Apple's own native sharing
/// UI is the only send mechanism.
///
/// PARTICIPANT RESOLUTION (no duplicates, no heuristics): mirrors
/// `ParentWorkspaceRepository.findParticipant(forAthlete:workspaceId:)`'s
/// own state-agnostic, stable-ID-only matching — reimplemented here as a
/// pure, testable static function (`matchingAthleteParticipants`) over an
/// already-fetched `[WorkspaceParticipant]` rather than calling that
/// method directly, so an existing-but-duplicate state (should be
/// structurally impossible given `@Attribute(.unique)` on
/// `WorkspaceParticipant.id`, but never given a chance to silently
/// resolve to a first-match winner) is its own explicit, testable
/// outcome rather than swallowed by `.first`. Never matches by display
/// name, order, age, or any CloudKit-side identity — only `AthleteId`/
/// `WorkspaceId`. A genuinely new athlete (no existing participant at
/// all) creates EXACTLY ONE new `.invited` `WorkspaceParticipant`, via
/// the same canonical `ParentWorkspaceRepository.createInvitedAthleteParticipant(...)`
/// path every other invitation flow in this codebase already uses — no
/// ad-hoc model insertion.
///
/// CLOUDKIT SEQUENCING: reuses B2.1's `FamilyWorkspaceOwnerShareCoordinator
/// .ensureSharingRoot(forWorkspace:)` (idempotent — a second "Connect
/// Athlete App" action for the SAME workspace converges on the SAME
/// `CKShare`, never a second one) and B2.6's own `ensureInvitationIntent(
/// for:intendedParticipantId:intendedAthleteId:)` to durably carry which
/// participant/athlete THIS action intends, via the separate
/// `AthleteConnectionInvitationCloudRecordMapping` child record — see
/// that type's own doc comment for why a `CKShare.Participant` cannot
/// carry this instead.
///
/// KNOWN LIMITATION (documented, not solved here — matches
/// `AthleteConnectionInvitationCloudRecordMapping`'s own doc comment):
/// `ensureInvitationIntent` keeps exactly ONE invitation-intent record
/// per workspace. Calling `prepareInvitation` for a DIFFERENT athlete on
/// the SAME workspace before the first invitation is accepted OVERWRITES
/// the earlier intent — this bounded Internal Alpha slice does not
/// support truly simultaneous pending invitations to more than one
/// athlete on the same share. A later slice needing that would extend
/// the mapping to a per-participant keyed record.
///
/// COMPOSITIONROOT: registered, but never invoked at `build()` time —
/// every call to `prepareInvitation(...)` originates from an explicit
/// Parent tap (`AthleteFamilyManagementViewModel.connectAthleteApp(for:)`).
///
/// ACTOR ISOLATION: `@MainActor`, matching both collaborators
/// (`ParentWorkspaceRepository` touches `ModelContext`;
/// `FamilyWorkspaceOwnerShareCoordinator` matches `CloudKitTransport`'s
/// own isolation — see each type's own doc comment).
@MainActor
public final class AthleteConnectionOwnerHandoffService {

    private let parentWorkspaceRepository: ParentWorkspaceRepository
    private let ownerShareCoordinator: FamilyWorkspaceOwnerShareCoordinator
    private let transport: CloudKitTransport

    public init(
        parentWorkspaceRepository: ParentWorkspaceRepository,
        ownerShareCoordinator: FamilyWorkspaceOwnerShareCoordinator,
        transport: CloudKitTransport
    ) {
        self.parentWorkspaceRepository = parentWorkspaceRepository
        self.ownerShareCoordinator = ownerShareCoordinator
        self.transport = transport
    }

    /// `invitedBy`: the Parent's own `ActorId` — threaded straight to
    /// `createInvitedAthleteParticipant(invitedBy:)` exactly like every
    /// other invitation-creation call site in this codebase, only when a
    /// NEW participant must be created. Never consulted at all when an
    /// existing participant (any state) is reused.
    public func prepareInvitation(
        forAthlete athleteId: AthleteId,
        workspaceId: WorkspaceId,
        invitedBy: ActorId
    ) async throws -> AthleteConnectionInvitationHandoff {
        let allParticipants: [WorkspaceParticipant]
        do {
            allParticipants = try parentWorkspaceRepository.fetchAllParticipants()
        } catch {
            throw AthleteConnectionOwnerHandoffError.participantLookupFailed(error)
        }

        let participant: WorkspaceParticipant
        switch Self.matchingAthleteParticipants(athleteId: athleteId, workspaceId: workspaceId, participants: allParticipants) {
        case .none:
            do {
                participant = try parentWorkspaceRepository.createInvitedAthleteParticipant(
                    workspaceId: workspaceId,
                    linkedAthleteId: athleteId,
                    invitedBy: invitedBy
                )
            } catch {
                throw AthleteConnectionOwnerHandoffError.participantCreationFailed(error)
            }
        case .one(let existing):
            participant = existing
        case .duplicate:
            throw AthleteConnectionOwnerHandoffError.duplicateAthleteParticipant
        }

        let root: FamilyWorkspaceSharingRoot
        do {
            root = try await ownerShareCoordinator.ensureSharingRoot(forWorkspace: workspaceId.rawValue)
        } catch {
            throw AthleteConnectionOwnerHandoffError.shareCreationFailed(error)
        }

        do {
            try await ownerShareCoordinator.ensureInvitationIntent(
                for: root,
                intendedParticipantId: participant.id,
                intendedAthleteId: athleteId.rawValue
            )
        } catch {
            throw AthleteConnectionOwnerHandoffError.invitationMappingFailed(error)
        }

        return AthleteConnectionInvitationHandoff(
            share: root.share,
            containerIdentifier: transport.containerIdentifier,
            participantId: participant.id,
            athleteId: athleteId
        )
    }

    /// PURE matching only — no persistence I/O, directly unit testable
    /// against plain in-memory `WorkspaceParticipant` fixtures. `nonisolated`
    /// for the same reason as every other pure decision in this
    /// codebase's B2.x work (see `AthleteConnectionIdentityBindingService
    /// .resolve`'s own doc comment): touches no instance state, and
    /// would otherwise inherit `@MainActor` isolation merely by being
    /// declared inside this type, making it uncallable from a
    /// synchronous, nonisolated unit test.
    enum ParticipantMatchResult {
        case none
        case one(WorkspaceParticipant)
        case duplicate
    }

    nonisolated static func matchingAthleteParticipants(
        athleteId: AthleteId,
        workspaceId: WorkspaceId,
        participants: [WorkspaceParticipant]
    ) -> ParticipantMatchResult {
        let matches = participants.filter {
            $0.role == .athlete && $0.linkedAthleteId == athleteId.rawValue && $0.workspaceId == workspaceId.rawValue
        }
        if matches.isEmpty {
            return .none
        }
        guard matches.count == 1, let onlyMatch = matches.first else {
            return .duplicate
        }
        return .one(onlyMatch)
    }
}

/// The minimum the ParentApp UI needs to present Apple's native sharing
/// UI and label it correctly — deliberately not richer. Not `Sendable`:
/// holds a real `CKShare`, mirroring every other B1/B2 CloudKit-adjacent
/// result type's own reasoning (see `FamilyWorkspaceSharingRoot`) — only
/// ever produced/consumed within `@MainActor` isolation.
public struct AthleteConnectionInvitationHandoff {
    public let share: CKShare
    public let containerIdentifier: String
    /// The EXISTING (or just-created) `WorkspaceParticipant.id` this
    /// invitation now durably carries as its intended discriminator.
    public let participantId: UUID
    public let athleteId: AthleteId
}

/// Explicit, differentiated failure semantics — never flattened to a
/// generic/silent failure, per this slice's own explicit error-handling
/// requirement. Not `Sendable`/`Equatable`: wraps an existential `Error`
/// in most cases, mirroring B2.1/B2.2/B2.5's own established reasoning;
/// every throw/catch site stays within this service's own `@MainActor`
/// isolation.
public enum AthleteConnectionOwnerHandoffError: Error {
    /// Fetching the existing participant graph failed — a genuine
    /// persistence failure, not "no participant exists yet."
    case participantLookupFailed(Error)
    /// More than one `WorkspaceParticipant` in this workspace links to
    /// this exact `AthleteId` — should be structurally impossible given
    /// SwiftData's own uniqueness enforcement on `WorkspaceParticipant.id`,
    /// but surfaced explicitly rather than silently reusing a first
    /// match.
    case duplicateAthleteParticipant
    /// No existing participant matched, and creating a new `.invited`
    /// one failed.
    case participantCreationFailed(Error)
    /// B2.1's `ensureSharingRoot(forWorkspace:)` failed — no CKShare
    /// exists to invite anyone to yet.
    case shareCreationFailed(Error)
    /// The share (and participant) exist, but durably recording which
    /// participant/athlete this invitation intends
    /// (`ensureInvitationIntent`) failed — the Athlete-side chain would
    /// have no way to disambiguate on acceptance.
    case invitationMappingFailed(Error)
}
