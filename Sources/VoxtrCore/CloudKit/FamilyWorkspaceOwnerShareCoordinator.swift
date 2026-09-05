import CloudKit
import Foundation

/// Athlete Connection Foundation B2.1: the OWNER-SIDE orchestration that
/// turns an existing local `FamilyWorkspace` into a real, sharable
/// CloudKit structure — a private-database custom zone, a deterministic
/// root `CKRecord` inside it, and a `CKShare` rooted on that record.
///
/// SCOPE (B2.1 only): this type ends at "a share exists, rooted on the
/// FamilyWorkspace record." It does NOT invite any participant, does NOT
/// build any invitation/acceptance UI, and does NOT touch the Athlete's
/// shared-database side at all — B2.2 owns accepting a share and B3 owns
/// participant invitation UI. `CKShare.Participant` is never referenced
/// here and must not be confused with Vǫxtr's own `WorkspaceParticipant`
/// (a SwiftData model owned by `VoxtrParentDomain`, not this type).
///
/// PROVIDER-NEUTRAL INPUT: like `FamilyWorkspaceCloudRecordMapping`, this
/// type takes a raw workspace `UUID`, never the real `FamilyWorkspace`
/// SwiftData model — `VoxtrCore` cannot import `VoxtrParentDomain`. The
/// caller (`VoxtrAppShell`) extracts `FamilyWorkspace.id` and hands it in.
///
/// ACTOR ISOLATION: `@MainActor`, matching `CloudKitTransport` (its one
/// dependency) — see that type's own PR #61 follow-up doc comment for
/// why isolation, not `@unchecked Sendable`, is this codebase's chosen
/// fix for exactly this shape of dependency. Every CloudKit type this
/// coordinator touches or returns (`CKRecordZone.ID`, `CKRecord.ID`,
/// `CKShare`) therefore never needs to cross an actor boundary.
///
/// XCTEST-SAFETY: `ensureSharingRoot(forWorkspace:)` itself performs real
/// CloudKit network I/O (zone save, record fetch/save, share fetch/save)
/// and — via `CloudKitTransport.refreshAvailability()` — realizes a real
/// `CKContainer`. Per B1's own hard-won lesson (`CKContainer.m:748`, no
/// entitlement in the XCTest host), this method must never be called from
/// a unit test; only the pure mapping it depends on
/// (`FamilyWorkspaceCloudRecordMapping`, `FamilyWorkspaceCloudZoneIdentifier`)
/// is unit-testable. Constructing this coordinator itself IS safe
/// (mirrors `CloudKitTransport()`'s own construction safety — it does no
/// I/O, just stores a reference).
@MainActor
public final class FamilyWorkspaceOwnerShareCoordinator {

    private let transport: CloudKitTransport
    private let log = VoxtrLog.logger(.cloudKit)

    public init(transport: CloudKitTransport) {
        self.transport = transport
    }

    /// Idempotent: repeated calls for the SAME `workspaceId` converge on
    /// the same zone, the same root record, and the same share — never a
    /// duplicate of any of the three. See each private step below for
    /// exactly how each one converges rather than merely hoping a bare
    /// `save` happens to be idempotent.
    public func ensureSharingRoot(forWorkspace workspaceId: UUID) async throws -> FamilyWorkspaceSharingRoot {
        let availability = await transport.refreshAvailability()
        guard availability == .available else {
            throw FamilyWorkspaceSharingError.accountUnavailable(availability)
        }

        let database = transport.database(for: .private)
        let zoneID = try await ensureZone(workspaceId: workspaceId, database: database)
        let rootRecord = try await ensureRootRecord(workspaceId: workspaceId, zoneID: zoneID, database: database)
        let share = try await ensureShare(rootRecord: rootRecord, workspaceId: workspaceId, zoneID: zoneID, database: database)

        return FamilyWorkspaceSharingRoot(
            workspaceId: workspaceId,
            zoneID: zoneID,
            rootRecordID: rootRecord.recordID,
            share: share
        )
    }

    /// A shareable custom zone is identified purely by its `CKRecordZone.ID`
    /// — CloudKit documents saving a zone that already exists as
    /// converging on the existing zone, not creating a second one, so no
    /// explicit "does it already exist" lookup is needed here the way the
    /// root record below requires one. Owner-side only: uses
    /// `FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace:)`,
    /// which is explicitly documented as correct only when the current
    /// user IS the zone's owner — true here, since this whole coordinator
    /// is the OWNER-side flow.
    private func ensureZone(workspaceId: UUID, database: CKDatabase) async throws -> CKRecordZone.ID {
        let zoneID = FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace: workspaceId)
        do {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        } catch {
            log.error("FamilyWorkspace zone save failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceSharingError.zoneCreationFailed(error)
        }
        return zoneID
    }

    /// Explicit fetch-before-create, per this slice's own idempotency
    /// contract: a fresh `CKRecord` object (never fetched from the
    /// server) has no change tag, so saving one whose deterministic ID
    /// already exists on the server is a genuine conflict CloudKit
    /// reports (`.serverRecordChanged`), not a silent no-op the way a
    /// zone save is. Fetching first (and falling back to the server's
    /// own copy if a save still races) is what actually guarantees "no
    /// duplicate root record for the same workspace" rather than relying
    /// on accidental save semantics.
    private func ensureRootRecord(workspaceId: UUID, zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> CKRecord {
        let recordID = FamilyWorkspaceCloudRecordMapping.recordID(forWorkspace: workspaceId, zoneID: zoneID)

        if let existing = try await fetchExistingRootRecord(recordID: recordID, database: database) {
            return existing
        }

        let payload = FamilyWorkspaceCloudRecordPayload(workspaceId: workspaceId)
        let record = FamilyWorkspaceCloudRecordMapping.makeRecord(for: payload, zoneID: zoneID)
        do {
            return try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Lost a race with a concurrent ensure (or a prior attempt
            // whose response we never saw) — CloudKit's own error carries
            // the record that actually exists now; converge on that
            // rather than treating this as a failure. Read via the
            // NSError bridge (`(error as NSError).userInfo`) rather than
            // a CKError-specific accessor property — every Swift Error
            // bridges to NSError, so this is the one universally
            // guaranteed way to reach `CKRecordChangedErrorServerRecordKey`
            // regardless of which convenience property (if any) this SDK
            // version's CKError itself exposes.
            if let serverRecord = (error as NSError).userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                return serverRecord
            }
            log.error("FamilyWorkspace root record save reported serverRecordChanged with no server record attached.")
            throw FamilyWorkspaceSharingError.rootRecordFailed(error)
        } catch {
            log.error("FamilyWorkspace root record save failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceSharingError.rootRecordFailed(error)
        }
    }

    private func fetchExistingRootRecord(recordID: CKRecord.ID, database: CKDatabase) async throws -> CKRecord? {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            // The expected, legitimate "not created yet" case — not a
            // failure, so it is not wrapped/logged as one.
            return nil
        } catch {
            log.error("FamilyWorkspace root record fetch failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceSharingError.rootRecordFailed(error)
        }
    }

    /// A root record's associated share (if any) is discoverable via its
    /// own `share` reference — checked first, so a repeated call returns
    /// the SAME share rather than creating a second one. Only when no
    /// share exists yet is a new `CKShare` constructed and saved
    /// alongside the root record, per Apple's documented CKShare creation
    /// flow (a share must be saved together with its root record in the
    /// same operation). `publicPermission = .none`: this slice adds no
    /// participants and builds no invitation flow, so the share must not
    /// be openly joinable by anyone who finds the link — B3 owns
    /// deciding actual participant permissions when invitation exists.
    ///
    /// PR #63 follow-up (concurrent-creation race): the sequential check
    /// above (`rootRecord.share`) only helps when the record we already
    /// hold is caught up. Two concurrent `ensure` calls can both observe
    /// no share, both construct their own `CKShare`, and both attempt to
    /// save `[rootRecord, share]` against the SAME `rootRecord` change
    /// tag — the loser's save is rejected as a conflict, not because
    /// there's a genuine failure, but because the winner already moved
    /// the root record forward. `isRecoverableShareCreationConflict(code:)`
    /// recognizes that shape of failure; on a match, the authoritative
    /// root record is refetched by its own deterministic ID and its
    /// (now up to date) `share` reference is followed — converging on
    /// the WINNER's share rather than treating the loser's save as a
    /// terminal error.
    private func ensureShare(rootRecord: CKRecord, workspaceId: UUID, zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> CKShare {
        if let shareReference = rootRecord.share {
            return try await fetchExistingShare(recordID: shareReference.recordID, database: database)
        }

        let share = CKShare(rootRecord: rootRecord)
        share.publicPermission = .none
        do {
            let result = try await database.modifyRecords(saving: [rootRecord, share], deleting: [])
            // `modifyRecords` mutates the CKRecord/CKShare instances we
            // passed in in place (system fields like recordChangeTag) —
            // it does not hand back new objects to adopt — so the
            // already-held `share` reference is what we return; only the
            // per-record result is inspected, to surface a genuine
            // per-record failure explicitly rather than assuming success
            // because the batch call itself did not throw.
            guard let shareResult = result.saveResults[share.recordID] else {
                throw FamilyWorkspaceSharingError.shareSaveResultMissing
            }
            _ = try shareResult.get()
            return share
        } catch let error as FamilyWorkspaceSharingError {
            throw error
        } catch let error as CKError where Self.isRecoverableShareCreationConflict(code: error.code) {
            return try await convergeOnExistingShareAfterCreationConflict(
                workspaceId: workspaceId,
                zoneID: zoneID,
                database: database,
                underlyingError: error
            )
        } catch {
            log.error("FamilyWorkspace share save failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceSharingError.shareFailed(error)
        }
    }

    /// PURE decision only — no CloudKit I/O, so it is directly unit
    /// testable against plain `CKError.Code` values (themselves a plain
    /// enum, safe to construct in XCTest with no entitlement).
    /// `nonisolated` (PR #63 Codemagic follow-up): this helper touches no
    /// coordinator instance state (`transport`, `log`) and performs no
    /// CloudKit I/O — it would otherwise inherit `@MainActor` isolation
    /// from the enclosing type merely by being declared inside it, which
    /// is not warranted here and is exactly what made the synchronous,
    /// nonisolated unit tests below fail to compile under Swift 6 ("Call
    /// to main actor-isolated static method ... in a synchronous
    /// nonisolated context"). Marking it `nonisolated` is the correct,
    /// minimal fix — not a broadening of actor isolation, since nothing
    /// about this specific function's body needs MainActor at all. Kept
    /// deliberately conservative/broad rather than trying to pinpoint the
    /// exact single code CloudKit reports for this specific batch shape
    /// (which this repo's own tooling cannot verify without a real
    /// compiler+server round trip — see this file's own XCTEST-SAFETY
    /// note): `.serverRecordChanged` is the direct per-record conflict
    /// code; `.partialFailure`/`.batchRequestFailed` are the documented
    /// codes CloudKit uses for the OVERALL operation and for sibling
    /// records respectively when an atomic batch fails because one
    /// record in it (here, the stale `rootRecord`) lost a write race.
    /// Recognizing all three as "worth refetching and converging on" is
    /// safe even if broader than strictly necessary: refetching the
    /// deterministic root record and checking its `share` reference is
    /// itself side-effect-free, so a false-positive match here costs one
    /// extra fetch, never a duplicate share or a masked real failure —
    /// `convergeOnExistingShareAfterCreationConflict` still surfaces the
    /// original error explicitly if the refetched root has no share.
    nonisolated static func isRecoverableShareCreationConflict(code: CKError.Code) -> Bool {
        switch code {
        case .serverRecordChanged, .partialFailure, .batchRequestFailed:
            true
        default:
            false
        }
    }

    /// Refetches the deterministic root record — the one thing every
    /// concurrent `ensure` call agrees on regardless of which one "won"
    /// — and follows its `share` reference if the winner has since
    /// populated one. Only ever called after a save that this coordinator
    /// itself judged to be a recoverable creation-race shape; still does
    /// not retry unboundedly: if the refetch itself fails, or the
    /// authoritative root record still has no share, the ORIGINAL
    /// underlying error is surfaced rather than looping or inventing a
    /// share.
    private func convergeOnExistingShareAfterCreationConflict(
        workspaceId: UUID,
        zoneID: CKRecordZone.ID,
        database: CKDatabase,
        underlyingError: CKError
    ) async throws -> CKShare {
        let recordID = FamilyWorkspaceCloudRecordMapping.recordID(forWorkspace: workspaceId, zoneID: zoneID)

        // `fetchExistingRootRecord` itself already returns `CKRecord?`
        // (nil = legitimately not found) while THROWING on a genuine
        // fetch failure — deliberately not `try?` here, which would
        // collapse those two different outcomes into the same `nil` and
        // silently discard a genuine failure. Either outcome converges
        // on the same result below: surface the ORIGINAL share-save
        // conflict, not a fresh error about the refetch itself, since
        // that conflict is the actual problem a caller needs to see.
        let refetchedRoot: CKRecord?
        do {
            refetchedRoot = try await fetchExistingRootRecord(recordID: recordID, database: database)
        } catch {
            log.error("FamilyWorkspace share creation conflict: refetching the authoritative root record failed; surfacing the original conflict.")
            throw FamilyWorkspaceSharingError.shareFailed(underlyingError)
        }
        guard let refetchedRoot, let shareReference = refetchedRoot.share else {
            // Either the root genuinely vanished (should not happen — we
            // just successfully fetched/created it earlier in this same
            // call), or whatever conflicted with our save was not
            // another writer's share creation. Either way, there is
            // nothing to converge on — surface the real failure rather
            // than retrying indefinitely.
            log.error("FamilyWorkspace share creation conflict did not resolve to an existing share on refetch.")
            throw FamilyWorkspaceSharingError.shareFailed(underlyingError)
        }
        return try await fetchExistingShare(recordID: shareReference.recordID, database: database)
    }

    private func fetchExistingShare(recordID: CKRecord.ID, database: CKDatabase) async throws -> CKShare {
        do {
            guard let share = try await database.record(for: recordID) as? CKShare else {
                throw FamilyWorkspaceSharingError.existingShareReferenceWasNotAShare
            }
            return share
        } catch let error as FamilyWorkspaceSharingError {
            throw error
        } catch {
            log.error("FamilyWorkspace existing share fetch failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceSharingError.shareFailed(error)
        }
    }

    /// Athlete Connection Foundation B2.6: ensures the invitation-intent
    /// child record (see `AthleteConnectionInvitationCloudRecordMapping`'s
    /// own doc comment) exists in the SAME zone as `root`, parented to
    /// `root`'s own root record so it is included in the share's
    /// hierarchy, carrying the CURRENT "Connect Athlete App" action's
    /// intended participant/athlete. Idempotent the same way
    /// `ensureRootRecord` is: fetch-first, reusing the existing record
    /// (preserving its change tag) if one already exists rather than
    /// constructing fresh and risking a `.serverRecordChanged` conflict
    /// — deliberately WITHOUT `ensureShare`'s own concurrent-writer
    /// conflict-recovery complexity, since only this Parent's own device
    /// ever writes this record (no concurrent-writer scenario to
    /// reconcile for Internal Alpha's single-Parent-device usage).
    /// Repeated calls for a DIFFERENT athlete converge on UPDATING this
    /// SAME record — see that type's own doc comment for why this
    /// bounded slice does not support multiple simultaneously pending
    /// invitations to different athletes on the same share.
    public func ensureInvitationIntent(
        for root: FamilyWorkspaceSharingRoot,
        intendedParticipantId: UUID,
        intendedAthleteId: UUID
    ) async throws {
        let database = transport.database(for: .private)
        let payload = AthleteConnectionInvitationCloudRecordPayload(
            workspaceId: root.workspaceId,
            intendedParticipantId: intendedParticipantId,
            intendedAthleteId: intendedAthleteId
        )
        let recordID = AthleteConnectionInvitationCloudRecordMapping.recordID(forWorkspace: root.workspaceId, zoneID: root.zoneID)

        let record: CKRecord
        do {
            // `database.record(for:)` THROWS (`.unknownItem`) rather
            // than returning `nil` when not found — matching
            // `fetchExistingRootRecord`'s own established handling of
            // exactly this API shape.
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = AthleteConnectionInvitationCloudRecordMapping.makeRecord(for: payload, zoneID: root.zoneID, parentRecordID: root.rootRecordID)
        } catch {
            log.error("AthleteConnectionInvitation record fetch failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceSharingError.invitationIntentFailed(error)
        }

        // Re-apply the payload even when reusing a fetched record — an
        // existing record may carry a PREVIOUS invitation's intent
        // (a different athlete), which this call is explicitly meant to
        // replace.
        AthleteConnectionInvitationCloudRecordMapping.apply(payload, to: record)

        do {
            _ = try await database.save(record)
        } catch {
            log.error("AthleteConnectionInvitation record save failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceSharingError.invitationIntentFailed(error)
        }
    }
}

/// The minimum this slice's caller needs to move forward with a later
/// B2.2/B3 slice — deliberately not richer. Not `Sendable`: mirrors every
/// other B1/B2 CloudKit-adjacent type's own reasoning (see
/// `CloudKitTransport`) — this is only ever produced and consumed within
/// `FamilyWorkspaceOwnerShareCoordinator`'s own `@MainActor` isolation, so
/// it never needs to cross an actor boundary, and no Apple CloudKit type
/// it holds is asserted Sendable here.
public struct FamilyWorkspaceSharingRoot {
    public let workspaceId: UUID
    public let zoneID: CKRecordZone.ID
    public let rootRecordID: CKRecord.ID
    public let share: CKShare
}

/// Explicit, differentiated failure semantics — never collapsed to `nil`
/// or a generic Bool, per this slice's own "Failure Semantics"
/// requirement. Not `Sendable`: wraps an existential `Error`, which is
/// not itself guaranteed Sendable; every throw/catch site is within
/// `FamilyWorkspaceOwnerShareCoordinator`'s own `@MainActor` isolation,
/// so this never needs to cross an actor boundary either.
public enum FamilyWorkspaceSharingError: Error {
    /// CloudKit itself is not usable right now (no/restricted account,
    /// etc.) — surfaced via the existing B1 `CloudKitAvailability` path
    /// rather than a fresh account-status concept.
    case accountUnavailable(CloudKitAvailability)
    case zoneCreationFailed(Error)
    case rootRecordFailed(Error)
    case shareFailed(Error)
    /// The root record's own `share` reference pointed at a record that
    /// did not decode as a `CKShare` — should not happen given this
    /// coordinator is the only writer of that reference, but surfaced
    /// explicitly rather than force-cast/crash.
    case existingShareReferenceWasNotAShare
    /// `modifyRecords` succeeded as a batch but reported no per-record
    /// result for the share we asked it to save — should not happen per
    /// CloudKit's own documented contract, but surfaced explicitly rather
    /// than silently assuming success.
    case shareSaveResultMissing
    /// Athlete Connection Foundation B2.6: fetching or saving the
    /// invitation-intent record (`AthleteConnectionInvitationCloudRecordMapping`)
    /// failed — the share/root record themselves may already exist and
    /// be unaffected; this specifically means the CURRENT "Connect
    /// Athlete App" action's intended-participant record could not be
    /// written.
    case invitationIntentFailed(Error)
}
