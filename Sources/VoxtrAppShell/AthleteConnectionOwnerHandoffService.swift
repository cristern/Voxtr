import CloudKit
import VoxtrCore
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain

/// Athlete Connection Foundation B2.6 (PR #68 architecture follow-up):
/// the ONE ParentApp-side orchestration service that turns "Parent
/// selects an existing `AthleteProfile` and taps Connect Athlete App"
/// into a real, native CloudKit share invite — the owner-side
/// counterpart to `AthleteConnectionLifecycleService` (B2.5, Athlete
/// side).
///
/// SCOPE: this is the smallest legitimate slice that gets a real
/// `CKShare` in front of the Parent's native iOS share sheet, carrying
/// enough information for the Athlete-side chain (B2.2 → hydration →
/// acceptance → B2.3 → B2.4) to resolve back to the EXACT
/// `WorkspaceParticipant`/`AthleteProfile` this action intended — never a
/// heuristically-chosen one, and to bootstrap that identity on a FRESH
/// Athlete device that has none of it locally yet. It does NOT present
/// any UI itself (see `CloudSharingPresenter`), does NOT decide
/// participant permissions beyond `.none` (only an explicitly-added
/// person may join), and does NOT build any custom email/SMS delivery.
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
/// outcome. Never matches by display name, order, age, or any
/// CloudKit-side identity — only `AthleteId`/`WorkspaceId`. A genuinely
/// new athlete (no existing participant at all) creates EXACTLY ONE new
/// `.invited` `WorkspaceParticipant`, via the same canonical
/// `ParentWorkspaceRepository.createInvitedAthleteParticipant(...)` path
/// every other invitation flow in this codebase already uses.
///
/// EACH INVITATION IS ITS OWN CKSHARE (PR #68 fix for the workspace-wide
/// mutable-intent correctness defect): `FamilyWorkspaceOwnerShareCoordinator
/// .ensureSharingRoot(forWorkspace:)` is still called, but ONLY to
/// obtain the already-established custom zone identity (`zoneID`) — its
/// OWN returned `CKShare`/root record are otherwise unused by this flow
/// now. `createInvitationShare(zoneID:payload:)` then creates a BRAND
/// NEW, independent invitation record + `CKShare` every single call —
/// never idempotent, never reused, so a later invitation for a
/// different athlete can never retarget or overwrite an earlier,
/// still-pending one. See `AthleteConnectionInvitationCloudRecordMapping`'s
/// own doc comment for the full rationale.
///
/// CROSS-DEVICE HYDRATION PAYLOAD: this service gathers the Parent's OWN
/// local `ParentProfile`/`FamilyWorkspace`/owner `WorkspaceParticipant`
/// plus the SELECTED athlete's own `AthleteProfile` fields and includes
/// them in the invitation record — see `AthleteConnectionInvitationCloudRecordMapping`'s
/// own doc comment for exactly why and `AthleteIdentityHydrationService`
/// for the Athlete-side consumer. ORDERING: every one of these lookups,
/// and the invitation record/share creation itself, completes here
/// BEFORE this method returns a `AthleteConnectionInvitationHandoff` —
/// the Parent's native share sheet is only ever presented (by the
/// caller, `CloudSharingPresenter`) once a fully resolvable invitation
/// already exists; nothing is ever presented that the Athlete side could
/// not, in principle, immediately resolve.
///
/// COMPOSITIONROOT: registered, but never invoked at `build()` time —
/// every call to `prepareInvitation(...)` originates from an explicit
/// Parent tap (`AthleteFamilyManagementViewModel.connectAthleteApp(for:)`).
///
/// ACTOR ISOLATION: `@MainActor`, matching every collaborator.
@MainActor
public final class AthleteConnectionOwnerHandoffService {

    private let parentWorkspaceRepository: ParentWorkspaceRepository
    private let athleteRepository: AthleteRepository
    private let ownerShareCoordinator: FamilyWorkspaceOwnerShareCoordinator
    private let transport: CloudKitTransport

    public init(
        parentWorkspaceRepository: ParentWorkspaceRepository,
        athleteRepository: AthleteRepository,
        ownerShareCoordinator: FamilyWorkspaceOwnerShareCoordinator,
        transport: CloudKitTransport
    ) {
        self.parentWorkspaceRepository = parentWorkspaceRepository
        self.athleteRepository = athleteRepository
        self.ownerShareCoordinator = ownerShareCoordinator
        self.transport = transport
    }

    /// `invitedBy`: the Parent's own `ActorId` — threaded straight to
    /// `createInvitedAthleteParticipant(invitedBy:)` exactly like every
    /// other invitation-creation call site in this codebase, only when a
    /// NEW participant must be created. Also reused, as a raw `UUID`, as
    /// the transported `ownerParticipantId` hydration field — this
    /// service's own caller (`AthleteFamilyManagementViewModel`) already
    /// derives it from the SAME local owner participant this method
    /// looks up again below to build the hydration payload, so both
    /// values are guaranteed identical; this is not a second, separate
    /// identity.
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

        guard let ownerParticipant = allParticipants.first(where: { $0.role == .workspaceOwner }) else {
            throw AthleteConnectionOwnerHandoffError.ownerParticipantNotFound
        }

        let parent: ParentProfile
        do {
            let parents = try parentWorkspaceRepository.fetchAllParentProfiles()
            guard let sole = parents.first else {
                throw AthleteConnectionOwnerHandoffError.parentProfileNotFound
            }
            parent = sole
        } catch let error as AthleteConnectionOwnerHandoffError {
            throw error
        } catch {
            throw AthleteConnectionOwnerHandoffError.parentProfileLookupFailed(error)
        }

        let workspace: FamilyWorkspace
        do {
            let workspaces = try parentWorkspaceRepository.fetchAllWorkspaces()
            guard let matching = workspaces.first(where: { $0.id == workspaceId.rawValue }) else {
                throw AthleteConnectionOwnerHandoffError.workspaceNotFound
            }
            workspace = matching
        } catch let error as AthleteConnectionOwnerHandoffError {
            throw error
        } catch {
            throw AthleteConnectionOwnerHandoffError.workspaceLookupFailed(error)
        }

        let athlete: AthleteProfile
        do {
            guard let found = try athleteRepository.fetchAthlete(byId: athleteId) else {
                throw AthleteConnectionOwnerHandoffError.athleteProfileNotFound
            }
            athlete = found
        } catch let error as AthleteConnectionOwnerHandoffError {
            throw error
        } catch {
            throw AthleteConnectionOwnerHandoffError.athleteProfileLookupFailed(error)
        }

        let root: FamilyWorkspaceSharingRoot
        do {
            root = try await ownerShareCoordinator.ensureSharingRoot(forWorkspace: workspaceId.rawValue)
        } catch {
            throw AthleteConnectionOwnerHandoffError.shareCreationFailed(error)
        }

        let payload = AthleteConnectionInvitationCloudRecordPayload(
            workspaceId: workspaceId.rawValue,
            intendedParticipantId: participant.id,
            intendedAthleteId: athleteId.rawValue,
            parentId: parent.id,
            parentGivenName: parent.givenName,
            workspaceDisplayName: workspace.displayName,
            ownerParticipantId: ownerParticipant.id,
            athleteGivenName: athlete.givenName,
            athleteBirthDateISO: athlete.birthDate.isoString,
            athleteTimeZoneId: athlete.timeZoneId.rawValue,
            athleteDevelopmentStage: athlete.developmentStage.rawValue
        )

        let share: CKShare
        do {
            share = try await ownerShareCoordinator.createInvitationShare(zoneID: root.zoneID, payload: payload)
        } catch {
            throw AthleteConnectionOwnerHandoffError.invitationMappingFailed(error)
        }

        return AthleteConnectionInvitationHandoff(
            share: share,
            containerIdentifier: transport.containerIdentifier,
            participantId: participant.id,
            athleteId: athleteId
        )
    }

    /// PURE matching only — no persistence I/O, directly unit testable
    /// against plain in-memory `WorkspaceParticipant` fixtures.
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
/// holds a real `CKShare`, mirroring every other CloudKit-adjacent
/// result type's own reasoning — only ever produced/consumed within
/// `@MainActor` isolation.
public struct AthleteConnectionInvitationHandoff {
    public let share: CKShare
    public let containerIdentifier: String
    /// The EXISTING (or just-created) `WorkspaceParticipant.id` this
    /// invitation now durably carries as its intended discriminator.
    public let participantId: UUID
    public let athleteId: AthleteId
}

/// Explicit, differentiated failure semantics — never flattened to a
/// generic/silent failure. Not `Sendable`/`Equatable`: wraps an
/// existential `Error` in most cases; every throw/catch site stays
/// within this service's own `@MainActor` isolation.
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
    /// No `.workspaceOwner` `WorkspaceParticipant` exists locally —
    /// should be structurally impossible on a device that ever
    /// completed onboarding, but surfaced explicitly rather than
    /// force-unwrapped.
    case ownerParticipantNotFound
    /// Fetching the local `ParentProfile` graph failed.
    case parentProfileLookupFailed(Error)
    /// No local `ParentProfile` exists to build the hydration payload
    /// from — should be structurally impossible on a device that ever
    /// completed onboarding.
    case parentProfileNotFound
    /// Fetching the local `FamilyWorkspace` graph failed.
    case workspaceLookupFailed(Error)
    /// No local `FamilyWorkspace` matches `workspaceId`.
    case workspaceNotFound
    /// Fetching the selected athlete's own `AthleteProfile` failed.
    case athleteProfileLookupFailed(Error)
    /// The selected athlete's `AthleteProfile` no longer exists locally
    /// — should not happen given the Parent selected it from an
    /// already-loaded roster moments earlier, but surfaced explicitly.
    case athleteProfileNotFound
    /// `FamilyWorkspaceOwnerShareCoordinator.ensureSharingRoot(forWorkspace:)`
    /// failed — no custom zone exists to place the new invitation record
    /// in yet.
    case shareCreationFailed(Error)
    /// `createInvitationShare(zoneID:payload:)` failed — the new
    /// invitation record and its dedicated `CKShare` could not be
    /// created/saved.
    case invitationMappingFailed(Error)
}
