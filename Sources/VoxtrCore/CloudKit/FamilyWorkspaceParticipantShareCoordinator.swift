import CloudKit
import Foundation

/// Athlete Connection Foundation B2.2: the PARTICIPANT-SIDE counterpart
/// to `FamilyWorkspaceOwnerShareCoordinator` (B2.1) — resolves an incoming
/// Parent-owned `CKShare` (already handed to the app by iOS, as
/// `CKShare.Metadata`) into the real shared-database location and stable
/// Vǫxtr `workspaceId` it points at.
///
/// SCOPE (B2.2 only): this type ends at "here is the transport-level
/// truth about an accepted share." It does NOT decide which
/// `WorkspaceParticipant`/`AthleteProfile` this corresponds to, does NOT
/// touch `CurrentSessionActor`, and does NOT create or mutate any
/// SwiftData model — see `AcceptedFamilyWorkspaceShare`'s own doc comment
/// for exactly what it does and does not carry. `CKShare.Participant` is
/// never referenced here and must not be confused with Vǫxtr's own
/// `WorkspaceParticipant` (a SwiftData model owned by `VoxtrParentDomain`,
/// not this type) — see `FamilyWorkspaceOwnerShareCoordinator`'s own doc
/// comment for the same distinction on the owner side. Binding these
/// transport facts to an existing Vǫxtr identity
/// (workspace → WorkspaceParticipant/AthleteAccessGrant → AthleteProfile →
/// CurrentSessionActor) is explicitly a LATER slice's responsibility.
///
/// CRITICAL IDENTITY RULE this type exists to enforce: the real, CloudKit-
/// reported `CKRecordZone.ID` — including its true `ownerName` (the
/// Parent's actual CloudKit identity) — is preserved exactly as CloudKit
/// hands it back from share acceptance. Nothing here ever constructs an
/// `ownerName` locally, and `FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace:)`
/// (owner-side only, per that type's own doc comment) is never called
/// from this file.
///
/// DATABASE SCOPE: always `.shared` — the current (Athlete) device's own
/// shared database, i.e. zones shared TO it by another owner (the
/// Parent). Never `.private`; that would be the Athlete's OWN private
/// data, an entirely different concept from a zone shared to it. `.shared`
/// here names a CloudKit DATABASE scope, not an actor role — see
/// `CloudKitDatabaseScope`'s own doc comment.
///
/// PROVIDER-NEUTRAL RESULT: like B2.1, this type's public result carries
/// only a raw workspace `UUID`, never a real `FamilyWorkspace` SwiftData
/// model — `VoxtrCore` cannot import `VoxtrParentDomain`.
///
/// ACTOR ISOLATION: `@MainActor`, matching `CloudKitTransport` (its one
/// dependency) — same reasoning as `FamilyWorkspaceOwnerShareCoordinator`
/// (see that type's own doc comment for why isolation, not `@unchecked
/// Sendable`, is this codebase's established fix for this dependency
/// shape).
///
/// XCTEST-SAFETY: `resolveAcceptedShare(from:)` performs real CloudKit
/// network I/O (share acceptance, root-record fetch) and realizes a real
/// `CKContainer`, so — per B1/B2.1's own established lesson — it must
/// never be called from a unit test. `CKShare.Metadata` itself also has
/// no public initializer reachable without a real accepted share, so no
/// test double could supply one anyway. What IS fully unit-testable is
/// the PURE decode/validation step this method delegates to,
/// `resolveAcceptedShare(share:rootRecord:)`, which takes an already-
/// accepted `CKShare` and an already-fetched `CKRecord` — both
/// locally constructible with no entitlement (`CKShare(rootRecord:)` and
/// `CKRecord(recordType:recordID:)` are plain, local value/model object
/// constructors, exactly like B2.1's own `FamilyWorkspaceCloudRecordMapping`
/// relies on).
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
    /// FIRST, via the pure `action(forParticipantStatus:)` below:
    /// `.pending` calls `transport.accept(metadata)` exactly once;
    /// `.accepted` skips acceptance entirely and resolves directly from
    /// `metadata.share` (the participant is already established — no
    /// second acceptance call is made or needed); any other status fails
    /// explicitly rather than silently assuming success. What this
    /// method ALSO still guarantees itself: given the SAME accepted
    /// share and the SAME fetched root record,
    /// `resolveAcceptedShare(share:rootRecord:)` is a pure function and
    /// always produces the identical `AcceptedFamilyWorkspaceShare` — no
    /// random/derived identity is ever introduced on the participant
    /// side.
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
            // Already an established participant — `metadata.share` is
            // CloudKit's own record for this share, no different from
            // what a fresh `accept` call would hand back; calling
            // `accept` again is neither necessary nor something this
            // slice should rely on behaving safely.
            acceptedShare = metadata.share
        case .reject:
            log.error("FamilyWorkspace share metadata reported an unsupported participant status.")
            throw FamilyWorkspaceShareAcceptanceError.unsupportedParticipantStatus(metadata.participantStatus)
        }

        // Vǫxtr's B2.1 sharing contract is a single-record hierarchy
        // rooted on the FamilyWorkspace record (`CKShare(rootRecord:)`).
        // `hierarchicalRootRecordID` is the current, non-deprecated API
        // for that root's identity — `rootRecordID` is deprecated and
        // deliberately not used. It is optional; metadata that lacks it
        // does not describe the shared-record hierarchy Vǫxtr expects,
        // so that is rejected explicitly rather than fabricating a root
        // ID or falling back to owner-side deterministic zone
        // construction (which participant-side code must never do at all
        // — see this file's own CRITICAL IDENTITY RULE above).
        guard let rootRecordID = metadata.hierarchicalRootRecordID else {
            throw FamilyWorkspaceShareAcceptanceError.missingHierarchicalRootRecordID
        }

        // Athlete-side access to the Parent-owned FamilyWorkspace root
        // MUST go through the shared database — the Parent's own private
        // database is never reachable from the Athlete's device at all.
        let database = transport.database(for: .shared)
        let rootRecord = try await fetchSharedRootRecord(recordID: rootRecordID, database: database)

        // Athlete Connection Foundation B2.6: the invitation-intent
        // child record — see `AthleteConnectionInvitationCloudRecordMapping`'s
        // own doc comment for why this exists and
        // `AthleteConnectionOwnerHandoffService` for who creates it. Its
        // deterministic ID is keyed on the root record's own decoded
        // `workspaceId` (never the root record's own name) combined with
        // the SAME zone the share/root record already reported
        // (`rootRecord.recordID.zoneID`), never a participant-side-
        // constructed guess — mirrors this file's own CRITICAL IDENTITY
        // RULE for the root record itself. This decode is redundant with
        // the authoritative one the pure `resolveAcceptedShare(share:
        // rootRecord:invitationIntent:)` below performs again on the same
        // record — deliberately so: that function stays the single
        // source of truth for root-record validation/failure semantics,
        // this call exists only to learn `workspaceId` early enough to
        // locate the invitation record. A missing or malformed mapping is
        // an explicit failure, not a silent fallback to ambiguous
        // resolution: B2.3 (`AthleteConnectionIdentityBindingService`)
        // now requires an exact intended participant ID to bind against.
        let rootPayloadForInvitationLookup: FamilyWorkspaceCloudRecordPayload
        do {
            rootPayloadForInvitationLookup = try FamilyWorkspaceCloudRecordMapping.payload(from: rootRecord)
        } catch {
            throw FamilyWorkspaceShareAcceptanceError.rootRecordDecodeFailed(error)
        }
        let invitationRecordID = AthleteConnectionInvitationCloudRecordMapping.recordID(
            forWorkspace: rootPayloadForInvitationLookup.workspaceId,
            zoneID: rootRecord.recordID.zoneID
        )
        let invitationRecord = try await fetchInvitationIntentRecord(recordID: invitationRecordID, database: database)
        let invitationIntent: AthleteConnectionInvitationCloudRecordPayload
        do {
            invitationIntent = try AthleteConnectionInvitationCloudRecordMapping.payload(from: invitationRecord)
        } catch {
            throw FamilyWorkspaceShareAcceptanceError.invitationIntentDecodeFailed(error)
        }

        return try Self.resolveAcceptedShare(share: acceptedShare, rootRecord: rootRecord, invitationIntent: invitationIntent)
    }

    /// Distinguishes "the Parent has not yet performed (or CloudKit has
    /// not yet propagated) the 'Connect Athlete App' action that creates
    /// this record" (`missingInvitationIntent` — an explicit, actionable
    /// failure: the Athlete accepted a share the Parent never actually
    /// pointed at a specific athlete, or propagation is still catching
    /// up) from a genuinely unrelated fetch failure
    /// (`invitationIntentFetchFailed`). Mirrors `fetchSharedRootRecord(
    /// recordID:database:)`'s own established `.unknownItem`/
    /// `.zoneNotFound` distinction exactly. Deliberately does not retry,
    /// sleep, or poll — same reasoning as that method.
    private func fetchInvitationIntentRecord(recordID: CKRecord.ID, database: CKDatabase) async throws -> CKRecord {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where Self.isSharedRootNotYetAvailable(code: error.code) {
            log.error("AthleteConnectionInvitation record not yet available in the shared database.")
            throw FamilyWorkspaceShareAcceptanceError.missingInvitationIntent(error)
        } catch {
            log.error("AthleteConnectionInvitation record fetch from shared database failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceShareAcceptanceError.invitationIntentFetchFailed(error)
        }
    }

    /// PURE decision only — no CloudKit I/O, so directly unit testable
    /// against plain `CKShare.ParticipantAcceptanceStatus` values.
    /// `nonisolated` for the same reason as every other pure decision in
    /// this codebase's CloudKit layer (see
    /// `FamilyWorkspaceOwnerShareCoordinator.isRecoverableShareCreationConflict(code:)`'s
    /// own PR #63 doc comment): touches no instance state, and declaring
    /// it inside an `@MainActor` type would otherwise make it uncallable
    /// from plain, synchronous, nonisolated unit tests.
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

    /// Distinguishes "CloudKit has not yet finished propagating the
    /// newly-accepted share's data into the shared database" (Apple
    /// documents this residual server-side work can continue briefly
    /// after acceptance completes) from a genuinely malformed/missing
    /// root identity or an unrelated failure. Deliberately does NOT
    /// retry, sleep, or poll here — per this follow-up's own explicit
    /// constraint, that residual-propagation race is left as an
    /// explicit, recoverable error a later lifecycle/sync integration
    /// can re-resolve, not something this slice solves with a timing
    /// hack. `.zoneNotFound`/`.unknownItem` are the fetch-time codes that
    /// legitimately mean "not visible from this side yet," mirroring how
    /// B2.1's own `fetchExistingRootRecord` already treats `.unknownItem`
    /// as a distinct, non-generic-failure case.
    private func fetchSharedRootRecord(recordID: CKRecord.ID, database: CKDatabase) async throws -> CKRecord {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where Self.isSharedRootNotYetAvailable(code: error.code) {
            log.error("FamilyWorkspace shared root record not yet available in the shared database.")
            throw FamilyWorkspaceShareAcceptanceError.sharedRootNotYetAvailable(error)
        } catch {
            log.error("FamilyWorkspace root record fetch from shared database failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceShareAcceptanceError.rootRecordUnavailable(error)
        }
    }

    /// PURE decision only — no CloudKit I/O. See `fetchSharedRootRecord(recordID:database:)`'s
    /// own doc comment for what this distinguishes and why.
    nonisolated static func isSharedRootNotYetAvailable(code: CKError.Code) -> Bool {
        switch code {
        case .zoneNotFound, .unknownItem:
            true
        default:
            false
        }
    }

    /// PURE decode/validation only — no CloudKit I/O. See this file's own
    /// XCTEST-SAFETY doc comment for why this is the seam actually
    /// covered by unit tests, and `FamilyWorkspaceCloudRecordMappingTests`
    /// in `CloudKitTransportTests.swift` for the tests themselves.
    ///
    /// `nonisolated`: touches no coordinator instance state (`transport`,
    /// `log`) — mirrors `FamilyWorkspaceOwnerShareCoordinator.isRecoverableShareCreationConflict(code:)`'s
    /// own PR #63 follow-up fix; declaring this `static` inside an
    /// `@MainActor` type would otherwise inherit that isolation and make
    /// it uncallable from plain, synchronous, nonisolated unit tests.
    ///
    /// VALIDATION PERFORMED (explicit, differentiated failures — never
    /// collapsed to `nil`/`Bool`):
    /// 1. the fetched root record lives in the SAME zone as the accepted
    ///    share itself (`rootRecordZoneMismatch` otherwise) — the one
    ///    place this function asserts anything about zone identity; it
    ///    never constructs or guesses a zone ID, only compares two
    ///    zone IDs CloudKit itself already reported.
    /// 2. the record decodes via B2.1's own `FamilyWorkspaceCloudRecordMapping.payload(from:)`
    ///    (record type + workspaceId parsing — `rootRecordDecodeFailed`
    ///    otherwise, wrapping that mapping's own `DecodeError` rather
    ///    than re-implementing field access here).
    /// 3. the record's own `recordID` matches EXACTLY what B2.1's
    ///    deterministic naming rule would produce for the decoded
    ///    `workspaceId` in this same zone (`rootRecordIdentityMismatch`
    ///    otherwise) — guards against a record that decodes a plausible
    ///    workspaceId but was not actually named the way this codebase's
    ///    own owner-side code names it.
    /// 4. Athlete Connection Foundation B2.6: the supplied
    ///    `invitationIntent`'s own `workspaceId` matches this SAME
    ///    decoded root-record `workspaceId` (`invitationIntentWorkspaceMismatch`
    ///    otherwise) — the invitation record's `CKRecord.ID` is already
    ///    derived from a workspaceId the caller read off this same root
    ///    record (see `resolveAcceptedShare(from:)`), so a mismatch here
    ///    would mean the record's own decoded payload disagrees with the
    ///    ID it was fetched by, which should never happen but is
    ///    surfaced explicitly rather than silently trusted.
    nonisolated static func resolveAcceptedShare(
        share: CKShare,
        rootRecord: CKRecord,
        invitationIntent: AthleteConnectionInvitationCloudRecordPayload
    ) throws -> AcceptedFamilyWorkspaceShare {
        let zoneID = share.recordID.zoneID

        guard rootRecord.recordID.zoneID == zoneID else {
            throw FamilyWorkspaceShareAcceptanceError.rootRecordZoneMismatch
        }

        let payload: FamilyWorkspaceCloudRecordPayload
        do {
            payload = try FamilyWorkspaceCloudRecordMapping.payload(from: rootRecord)
        } catch {
            throw FamilyWorkspaceShareAcceptanceError.rootRecordDecodeFailed(error)
        }

        let expectedRecordID = FamilyWorkspaceCloudRecordMapping.recordID(forWorkspace: payload.workspaceId, zoneID: zoneID)
        guard rootRecord.recordID == expectedRecordID else {
            throw FamilyWorkspaceShareAcceptanceError.rootRecordIdentityMismatch
        }

        guard invitationIntent.workspaceId == payload.workspaceId else {
            throw FamilyWorkspaceShareAcceptanceError.invitationIntentWorkspaceMismatch
        }

        return AcceptedFamilyWorkspaceShare(
            workspaceId: payload.workspaceId,
            zoneID: zoneID,
            rootRecordID: rootRecord.recordID,
            shareRecordID: share.recordID,
            intendedParticipantId: invitationIntent.intendedParticipantId,
            intendedAthleteId: invitationIntent.intendedAthleteId
        )
    }
}

/// The minimum transport-level truth about an accepted Parent share —
/// deliberately not richer. Explicitly does NOT carry an `AthleteProfile`,
/// `WorkspaceParticipant`, current-actor concept, UI state, or email —
/// binding these facts to an existing Vǫxtr identity is a later slice's
/// responsibility (see this file's own SCOPE doc comment), never decided
/// here. `zoneID` is the REAL `CKRecordZone.ID` CloudKit reported (true
/// `ownerName` included) — never reconstructed or derived from
/// `workspaceId`. Not `Sendable`: mirrors `FamilyWorkspaceSharingRoot`'s
/// own B2.1 reasoning — only ever produced/consumed within this
/// coordinator's own `@MainActor` isolation.
public struct AcceptedFamilyWorkspaceShare {
    public let workspaceId: UUID
    public let zoneID: CKRecordZone.ID
    public let rootRecordID: CKRecord.ID
    public let shareRecordID: CKRecord.ID
    /// Athlete Connection Foundation B2.6: the EXISTING `WorkspaceParticipant
    /// .id` the Parent's "Connect Athlete App" action intended this
    /// accepted share to connect — decoded from the separate
    /// `AthleteConnectionInvitationCloudRecordMapping` child record, never
    /// inferred from `CKShare.Participant`/CloudKit ownerName/display
    /// name. The actual discriminator `AthleteConnectionIdentityBindingService`
    /// (B2.3) now binds against.
    public let intendedParticipantId: UUID
    /// The `AthleteProfile.id` (`AthleteId.rawValue`) that participant is
    /// linked to — see `AthleteConnectionInvitationCloudRecordPayload
    /// .intendedAthleteId`'s own doc comment for why this is carried
    /// redundantly alongside `intendedParticipantId`.
    public let intendedAthleteId: UUID
}

/// Explicit, differentiated failure semantics — never collapsed to `nil`
/// or a generic Bool, mirroring `FamilyWorkspaceSharingError`'s own B2.1
/// reasoning. Not `Sendable`: wraps an existential `Error`; every
/// throw/catch site is within `FamilyWorkspaceParticipantShareCoordinator`'s
/// own `@MainActor` isolation (the `nonisolated` pure decode/validation
/// function throws these too, but is only ever awaited from that same
/// isolation domain), so this never needs to cross an actor boundary.
public enum FamilyWorkspaceShareAcceptanceError: Error {
    /// The share metadata's own `containerIdentifier` did not match this
    /// device's configured Vǫxtr container — malformed/unsupported share
    /// metadata, not a transient failure worth retrying.
    case containerMismatch(expected: String, actual: String)
    /// CloudKit itself is not usable right now — surfaced via the
    /// existing B1 `CloudKitAvailability` path, same as B2.1's own
    /// `accountUnavailable` case.
    case accountUnavailable(CloudKitAvailability)
    case shareAcceptanceFailed(Error)
    /// The share metadata's `participantStatus` was neither `.pending`
    /// (acceptable) nor `.accepted` (already established) — e.g.
    /// `.removed` or `.unknown` — so Vǫxtr cannot safely treat
    /// participation as established without silently inferring success.
    case unsupportedParticipantStatus(CKShare.ParticipantAcceptanceStatus)
    /// `metadata.hierarchicalRootRecordID` was `nil` — this metadata does
    /// not describe the single-record shared hierarchy Vǫxtr's B2.1
    /// sharing contract expects.
    case missingHierarchicalRootRecordID
    case rootRecordUnavailable(Error)
    /// CloudKit accepted the share, but the shared root record is not
    /// yet visible in the shared database — Apple documents this
    /// residual propagation can briefly continue after acceptance
    /// completes. Recoverable: a later attempt (lifecycle/sync
    /// integration, not this slice) may succeed without anything else
    /// changing.
    case sharedRootNotYetAvailable(Error)
    /// The fetched root record's zone did not match the accepted share's
    /// own zone — should not happen given both come from the same
    /// CloudKit-reported share, but surfaced explicitly rather than
    /// silently trusting either value alone.
    case rootRecordZoneMismatch
    /// Wraps `FamilyWorkspaceCloudRecordMapping.DecodeError` — wrong
    /// record type, missing, or malformed `workspaceId`.
    case rootRecordDecodeFailed(Error)
    /// The record decoded a plausible `workspaceId`, but its own
    /// `recordID` does not match what B2.1's deterministic naming rule
    /// would produce for that `workspaceId` in this zone.
    case rootRecordIdentityMismatch
    /// Athlete Connection Foundation B2.6: the invitation-intent record
    /// (`AthleteConnectionInvitationCloudRecordMapping`) is not yet
    /// visible in the shared database — either the Parent has not
    /// performed "Connect Athlete App" for this share, or (mirroring
    /// `sharedRootNotYetAvailable`'s own reasoning) CloudKit's residual
    /// post-acceptance propagation has not yet caught up. Recoverable in
    /// the same sense as `sharedRootNotYetAvailable`: not solved here by
    /// retrying/sleeping/polling.
    case missingInvitationIntent(Error)
    /// The invitation-intent record fetch failed for a reason other than
    /// "not yet available."
    case invitationIntentFetchFailed(Error)
    /// Wraps `AthleteConnectionInvitationCloudRecordMapping.DecodeError` —
    /// wrong record type, missing, or malformed field.
    case invitationIntentDecodeFailed(Error)
    /// The invitation-intent record's own decoded `workspaceId` did not
    /// match the root record's — see `resolveAcceptedShare(share:
    /// rootRecord:invitationIntent:)`'s own doc comment for why this
    /// should never happen but is still checked explicitly.
    case invitationIntentWorkspaceMismatch
}
