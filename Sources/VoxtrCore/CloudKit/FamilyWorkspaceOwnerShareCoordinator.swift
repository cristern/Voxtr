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
        let share = try await ensureShare(rootRecord: rootRecord, database: database)

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
    private func ensureShare(rootRecord: CKRecord, database: CKDatabase) async throws -> CKShare {
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
        } catch {
            log.error("FamilyWorkspace share save failed: \(error.localizedDescription, privacy: .public)")
            throw FamilyWorkspaceSharingError.shareFailed(error)
        }
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
}
