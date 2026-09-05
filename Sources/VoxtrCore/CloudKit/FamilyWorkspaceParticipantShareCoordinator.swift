import CloudKit
import Foundation

/// Athlete Connection Foundation B2.2 (PR #68 architecture follow-up):
/// the PARTICIPANT-SIDE counterpart to `FamilyWorkspaceOwnerShareCoordinator`
/// (B2.1) — resolves an incoming Parent-owned `CKShare` (already handed
/// to the app by iOS, as `CKShare.Metadata`) into the real shared-database
/// location, the stable Vǫxtr `workspaceId` it points at, EXACTLY which
/// participant/athlete it intends, and the minimum cross-device identity
/// projection needed to hydrate a fresh Athlete device's local graph.
///
/// ARCHITECTURE CHANGE (PR #68): this no longer fetches a SEPARATE
/// FamilyWorkspace root record plus a child invitation-intent record.
/// Since `AthleteConnectionOwnerHandoffService.prepareInvitation` now
/// creates ONE independent, immutable `CKShare` PER INVITATION — rooted
/// directly on an `AthleteConnectionInvitationCloudRecordMapping` record
/// carrying everything this flow needs — `metadata.hierarchicalRootRecordID`
/// IS that invitation record's own ID. One fetch, one record, one
/// decode. See `AthleteConnectionInvitationCloudRecordMapping`'s own doc
/// comment for the full rationale (this is also the fix for the
/// workspace-wide-mutable-intent correctness defect a prior round of
/// this PR shipped).
///
/// SCOPE (B2.2 only): this type ends at "here is the transport-level
/// truth about an accepted share." It does NOT decide which
/// `WorkspaceParticipant`/`AthleteProfile` this corresponds to LOCALLY,
/// does NOT touch `CurrentSessionActor`, and does NOT create or mutate
/// any SwiftData model itself — see `AcceptedFamilyWorkspaceShare`'s own
/// doc comment for exactly what it carries, and
/// `AthleteIdentityHydrationService` for the type that actually turns
/// this payload into local rows. `CKShare.Participant` is never
/// referenced here and must not be confused with Vǫxtr's own
/// `WorkspaceParticipant`.
///
/// CRITICAL IDENTITY RULE this type exists to enforce: the real, CloudKit-
/// reported `CKRecordZone.ID` — including its true `ownerName` (the
/// Parent's actual CloudKit identity) — is preserved exactly as CloudKit
/// hands it back from share acceptance. Nothing here ever constructs an
/// `ownerName` locally.
///
/// DATABASE SCOPE: always `.shared` — the current (Athlete) device's own
/// shared database, i.e. zones shared TO it by another owner (the
/// Parent). Never `.private`.
///
/// PROVIDER-NEUTRAL RESULT: like B2.1, this type's public result carries
/// only raw `UUID`/`String` values, never real `VoxtrParentDomain`/
/// `VoxtrAthleteDomain` SwiftData models — `VoxtrCore` cannot import
/// either.
///
/// ACTOR ISOLATION: `@MainActor`, matching `CloudKitTransport` (its one
/// dependency).
///
/// XCTEST-SAFETY: `resolveAcceptedShare(from:)` performs real CloudKit
/// network I/O and realizes a real `CKContainer`, so it must never be
/// called from a unit test; `CKShare.Metadata` itself also has no public
/// initializer reachable without a real accepted share. What IS fully
/// unit-testable is the PURE decode/validation step this method
/// delegates to, `resolveAcceptedShare(share:invitationRecord:)`, which
/// takes an already-accepted `CKShare` and an already-fetched `CKRecord`
/// — both locally constructible with no entitlement.
@MainActor
public final class FamilyWorkspaceParticipantShareCoordinator {

    private let transport: CloudKitTransport
    private let log = VoxtrLog.logger(.cloudKit)

    public init(transport: CloudKitTransport) {
        self.transport = transport
    }

    /// Idempotency (PR #64 follow-up): does NOT depend on however
    /// CloudKit happens to respond to a repeated `accept` call against an
    /// already-accepted share — that was undocumented behavior this
    /// slice should not lean on. Instead, `metadata.participantStatus`
    /// (Apple's own documented signal for exactly this) is inspected
    /// FIRST, via the pure `action(forParticipantStatus:)` below.
    public func resolveAcceptedShare(from metadata: CKShare.Metadata) async throws -> AcceptedFamilyWorkspaceShare {
        guard metadata.containerIdentifier == transport.containerIdentifier else {
            throw FamilyWorkspaceShareAcceptanceError.containerMismatch(
                expected: transport.containerIdentifier,
                actual: metadata.containerIdentifier
            )
        }

        let availability = await transport.refreshAvailability()
        guard availability == .available else {
            throw FamilyWorkspaceShareAcceptanceError.accountUnavailable(availability)
        }

        let acceptedShare: CKShare
        switch Self.action(forParticipantStatus: metadata.participantStatus) {
        case .accept:
            do {
                acceptedShare = try await transport.accept(metadata)
            } catch {
                log.error("FamilyWorkspace share acceptance failed: \(error.localizedDescription, privacy: .public)")
                throw FamilyWorkspaceShareAcceptanceError.shareAcceptanceFailed(error)
            }
        case .resolveExisting:
            acceptedShare = metadata.share
        case .reject:
            log.error("FamilyWorkspace share metadata reported an unsupported participant status.")
            throw FamilyWorkspaceShareAcceptanceError.unsupportedParticipantStatus(metadata.participantStatus)
        }

        // PR #68: the accepted share's own hierarchical root record IS
        // the invitation record itself now — see this file's own
        // ARCHITECTURE CHANGE doc comment. `hierarchicalRootRecordID` is
        // the current, non-deprecated API for that identity.
        guard let invitationRecordID = metadata.hierarchicalRootRecordID else {
            throw FamilyWorkspaceShareAcceptanceError.missingHierarchicalRootRecordID
        }

        let database = transport.database(for: .shared)
        let invitationRecord = try await fetchInvitationRecord(recordID: invitationRecordID, database: database)

        return try Self.resolveAcceptedShare(share: acceptedShare, invitationRecord: invitationRecord)
    }

    /// Distinguishes "CloudKit has not yet finished propagating the
    /// newly-accepted share's data into the shared database" (Apple
    /// documents this residual server-side work can continue briefly
    /// after acceptance completes) from a genuinely malformed/missing
    /// identity or an unrelated failure. Deliberately does NOT retry,
    /// sleep, or poll here — that residual-propagation race is left as
    /// an explicit, recoverable error a later lifecycle/sync integration
    /// can re-resolve.
    private func fetchInvitationRecord(recordID: CKRecord.ID, database: CKDatabase) async throws -> CKRecord {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where Self.isSharedRootNotYetAvailable(code: error.code) {
            log.error("AthleteConnectionInvitation record not yet available in the shared database.")
            throw FamilyWorkspaceShareAcceptanceError.invitationRecordNotYetAvailable(error)
        } catch {
            log.error("AthleteConnectionInvitation record fetch from shared database failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceShareAcceptanceError.invitationRecordUnavailable(error)
        }
    }

    /// PURE decision only — no CloudKit I/O, so directly unit testable
    /// against plain `CKShare.ParticipantAcceptanceStatus` values.
    enum ParticipantAcceptanceAction: Equatable {
        case accept
        case resolveExisting
        case reject
    }

    nonisolated static func action(forParticipantStatus status: CKShare.ParticipantAcceptanceStatus) -> ParticipantAcceptanceAction {
        switch status {
        case .pending: .accept
        case .accepted: .resolveExisting
        case .unknown, .removed: .reject
        @unknown default: .reject
        }
    }

    /// PURE decision only — no CloudKit I/O.
    nonisolated static func isSharedRootNotYetAvailable(code: CKError.Code) -> Bool {
        switch code {
        case .zoneNotFound, .unknownItem:
            true
        default:
            false
        }
    }

    /// PURE decode/validation only — no CloudKit I/O.
    ///
    /// VALIDATION PERFORMED (explicit, differentiated failures — never
    /// collapsed to `nil`/`Bool`):
    /// 1. the fetched invitation record lives in the SAME zone as the
    ///    accepted share itself (`invitationRecordZoneMismatch`
    ///    otherwise) — the one place this function asserts anything
    ///    about zone identity; it never constructs or guesses a zone ID,
    ///    only compares two zone IDs CloudKit itself already reported.
    /// 2. the record decodes via `AthleteConnectionInvitationCloudRecordMapping
    ///    .payload(from:)` (`invitationRecordDecodeFailed` otherwise,
    ///    wrapping that mapping's own `DecodeError`).
    ///
    /// PR #68: there is no longer a separate "does this record's own
    /// recordID match a deterministic naming rule" check — this
    /// record's identity IS whatever CloudKit reported as the accepted
    /// share's own hierarchical root; there is no second, independently-
    /// derivable expected name to compare it against any more (see
    /// `AthleteConnectionInvitationCloudRecordMapping`'s own doc comment
    /// for why record identity is now random-per-invitation rather than
    /// workspace-deterministic).
    nonisolated static func resolveAcceptedShare(
        share: CKShare,
        invitationRecord: CKRecord
    ) throws -> AcceptedFamilyWorkspaceShare {
        let zoneID = share.recordID.zoneID

        guard invitationRecord.recordID.zoneID == zoneID else {
            throw FamilyWorkspaceShareAcceptanceError.invitationRecordZoneMismatch
        }

        let payload: AthleteConnectionInvitationCloudRecordPayload
        do {
            payload = try AthleteConnectionInvitationCloudRecordMapping.payload(from: invitationRecord)
        } catch {
            throw FamilyWorkspaceShareAcceptanceError.invitationRecordDecodeFailed(error)
        }

        return AcceptedFamilyWorkspaceShare(
            workspaceId: payload.workspaceId,
            zoneID: zoneID,
            rootRecordID: invitationRecord.recordID,
            shareRecordID: share.recordID,
            intendedParticipantId: payload.intendedParticipantId,
            intendedAthleteId: payload.intendedAthleteId,
            hydration: payload
        )
    }
}

/// The transport-level truth about an accepted Parent invitation —
/// deliberately not richer than what B2.3/B2.4/`AthleteIdentityHydrationService`
/// actually need. Explicitly does NOT carry a real `AthleteProfile`,
/// `WorkspaceParticipant`, current-actor concept, or UI state — binding
/// these facts to an existing/hydrated Vǫxtr identity is
/// `AthleteIdentityHydrationService`'s and B2.3's job, never decided
/// here. `zoneID` is the REAL `CKRecordZone.ID` CloudKit reported (true
/// `ownerName` included) — never reconstructed or derived from
/// `workspaceId`. Not `Sendable`: only ever produced/consumed within
/// this coordinator's own `@MainActor` isolation.
public struct AcceptedFamilyWorkspaceShare {
    public let workspaceId: UUID
    public let zoneID: CKRecordZone.ID
    public let rootRecordID: CKRecord.ID
    public let shareRecordID: CKRecord.ID
    /// The EXISTING `WorkspaceParticipant.id` this invitation intends to
    /// connect — the actual discriminator `AthleteConnectionIdentityBindingService`
    /// (B2.3) binds against.
    public let intendedParticipantId: UUID
    /// The `AthleteProfile.id` that participant is linked to.
    public let intendedAthleteId: UUID
    /// PR #68: the minimum cross-device identity projection a fresh
    /// Athlete device needs to hydrate before B2.3/B2.4 can succeed —
    /// reuses the same payload type the invitation record itself
    /// carries (`workspaceId`/`intendedParticipantId`/`intendedAthleteId`
    /// are redundant with the fields above, kept so this whole payload
    /// can be handed to `AthleteIdentityHydrationService` as one value).
    /// See `AthleteConnectionInvitationCloudRecordMapping`'s own doc
    /// comment for exactly what each field is and why it's the minimum
    /// needed.
    public let hydration: AthleteConnectionInvitationCloudRecordPayload
}

/// Explicit, differentiated failure semantics — never collapsed to `nil`
/// or a generic Bool. Not `Sendable`: wraps an existential `Error`;
/// every throw/catch site is within `FamilyWorkspaceParticipantShareCoordinator`'s
/// own `@MainActor` isolation.
public enum FamilyWorkspaceShareAcceptanceError: Error {
    /// The share metadata's own `containerIdentifier` did not match this
    /// device's configured Vǫxtr container — malformed/unsupported share
    /// metadata, not a transient failure worth retrying.
    case containerMismatch(expected: String, actual: String)
    /// CloudKit itself is not usable right now.
    case accountUnavailable(CloudKitAvailability)
    case shareAcceptanceFailed(Error)
    /// The share metadata's `participantStatus` was neither `.pending`
    /// (acceptable) nor `.accepted` (already established).
    case unsupportedParticipantStatus(CKShare.ParticipantAcceptanceStatus)
    /// `metadata.hierarchicalRootRecordID` was `nil` — this metadata does
    /// not describe the single-record shared hierarchy Vǫxtr expects.
    case missingHierarchicalRootRecordID
    /// PR #68: the invitation record is not yet visible in the shared
    /// database — either genuinely still propagating (Apple documents
    /// this can briefly continue after acceptance), or (structurally
    /// impossible under this design, since the record and its share are
    /// always saved together in ONE atomic `modifyRecords` call) never
    /// created. Recoverable: not solved here by retrying/sleeping/polling.
    case invitationRecordNotYetAvailable(Error)
    /// The invitation record fetch failed for a reason other than "not
    /// yet available."
    case invitationRecordUnavailable(Error)
    /// The fetched invitation record's zone did not match the accepted
    /// share's own zone — should not happen given both come from the
    /// same CloudKit-reported share, but surfaced explicitly rather than
    /// silently trusting either value alone.
    case invitationRecordZoneMismatch
    /// Wraps `AthleteConnectionInvitationCloudRecordMapping.DecodeError` —
    /// wrong record type, missing, or malformed field.
    case invitationRecordDecodeFailed(Error)
}
