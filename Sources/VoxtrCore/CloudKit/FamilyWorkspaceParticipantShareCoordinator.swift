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

    /// Idempotency: CloudKit's own documented behavior for accepting a
    /// share the current user already accepted is what actually
    /// determines whether a repeat call here converges cleanly — this
    /// slice does not add its own retry/reconciliation logic on top, and
    /// that specific behavior is a TestFlight/signed-build validation
    /// item (see the suite-level NOTE in `CloudKitTransportTests.swift`).
    /// What this method DOES guarantee itself: given the SAME accepted
    /// share and the SAME fetched root record, `resolveAcceptedShare(share:rootRecord:)`
    /// is a pure function and always produces the identical
    /// `AcceptedFamilyWorkspaceShare` — no random/derived identity is
    /// ever introduced on the participant side.
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
        do {
            acceptedShare = try await transport.accept(metadata)
        } catch {
            log.error("FamilyWorkspace share acceptance failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceShareAcceptanceError.shareAcceptanceFailed(error)
        }

        // Athlete-side access to the Parent-owned FamilyWorkspace root
        // MUST go through the shared database — the Parent's own private
        // database is never reachable from the Athlete's device at all.
        let database = transport.database(for: .shared)
        let rootRecord: CKRecord
        do {
            rootRecord = try await database.record(for: metadata.rootRecordID)
        } catch {
            log.error("FamilyWorkspace root record fetch from shared database failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceShareAcceptanceError.rootRecordUnavailable(error)
        }

        return try Self.resolveAcceptedShare(share: acceptedShare, rootRecord: rootRecord)
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
    nonisolated static func resolveAcceptedShare(share: CKShare, rootRecord: CKRecord) throws -> AcceptedFamilyWorkspaceShare {
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

        return AcceptedFamilyWorkspaceShare(
            workspaceId: payload.workspaceId,
            zoneID: zoneID,
            rootRecordID: rootRecord.recordID,
            shareRecordID: share.recordID
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
    case rootRecordUnavailable(Error)
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
}
