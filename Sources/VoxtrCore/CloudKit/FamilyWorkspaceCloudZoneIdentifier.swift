import CloudKit
import Foundation

/// Athlete Connection Foundation B1: deterministic `CKRecordZone.ID` for a
/// `FamilyWorkspace`'s Family Shared Zone (Foundation B discovery,
/// DDM-006 — `FamilyWorkspace` is the CloudKit sharing root). Pure helper
/// only — this does NOT create the zone on CloudKit's servers; that is
/// explicit B2 work, once real Athlete participants exist to share with.
///
/// Deliberately takes a raw `UUID`, not a `WorkspaceId` — `VoxtrCore` has
/// zero dependency on `VoxtrCoreContracts` (see `Package.swift`; the same
/// rule `AppSchema.swift` documents for every domain module), so this
/// stays a pure, dependency-free primitive. Callers with a real
/// `WorkspaceId` pass `.rawValue`.
///
/// Deterministic and stable: the SAME `WorkspaceId` always produces the
/// SAME zone identity, on every device, with no random component and no
/// per-sync regeneration — this is what lets a `FamilyWorkspace` already
/// synced on one device be found again (never re-created) on another.
public enum FamilyWorkspaceCloudZoneIdentifier {

    /// `CKRecordZone.ID.zoneName` accepts most Unicode strings but is
    /// safest kept to a short, stable ASCII-only format — this mirrors
    /// how every stable Vǫxtr identifier already reads (`AccountId`,
    /// `WorkspaceId`, etc. all serialize a plain UUID string), not an
    /// invented CloudKit-specific convention.
    public static func zoneName(forWorkspace workspaceId: UUID) -> String {
        "voxtr.family.\(workspaceId.uuidString)"
    }

    /// `ownerName` is left as `CKCurrentUserDefaultName` — the
    /// documented placeholder meaning "the current user," resolved by
    /// CloudKit itself. Foundation B discovery's own caution against
    /// relying on `CKCurrentUserDefaultName` was about NOT using it as a
    /// substitute for a durable Vǫxtr actor/participant identity (see
    /// `CurrentSessionActor`/`WorkspaceParticipant` mapping, owned by
    /// B2/B3) — using it here, for its actual documented purpose (the
    /// zone-ownership component of a `CKRecordZone.ID`), is the correct,
    /// intended usage, not the thing that caution warns against.
    public static func zoneID(forWorkspace workspaceId: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName(forWorkspace: workspaceId), ownerName: CKCurrentUserDefaultName)
    }
}
