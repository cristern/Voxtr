import CloudKit
import Foundation

/// Athlete Connection Foundation B1 (PR #61 follow-up — corrected zone
/// ownership semantics): the deterministic Vǫxtr-owned NAMING convention
/// for a `FamilyWorkspace`'s Family Shared Zone (Foundation B discovery,
/// DDM-006 — `FamilyWorkspace` is the CloudKit sharing root).
///
/// VERIFIED CLOUDKIT SEMANTICS this type must respect: a shareable custom
/// `CKRecordZone` is created by its OWNER in the owner's OWN
/// `privateCloudDatabase`. Once another user accepts the resulting
/// `CKShare`, CloudKit exposes that SAME zone to the participant through
/// the participant's `sharedCloudDatabase` — as the SAME zone, but a
/// `CKRecordZone.ID` is `(zoneName, ownerName)` together, and `ownerName`
/// on the participant's side is the OWNER's identity, never the
/// participant's own. Concretely, for the current Parent-invites/
/// Athlete-accepts flow: the Parent's device addresses its own
/// FamilyWorkspace zone with `ownerName == CKCurrentUserDefaultName`
/// (correct — the Parent IS the current user creating/owning it); the
/// Athlete's device must address the SAME zone with `ownerName` equal to
/// the PARENT's real identity, which `CKCurrentUserDefaultName` does NOT
/// resolve to on the Athlete's own device (`CKCurrentUserDefaultName`
/// always means "the CURRENT user," i.e. the Athlete there, not the
/// Parent). There is therefore no locally-computable, single
/// `CKRecordZone.ID` that is correct on every device for the same
/// `WorkspaceId` — this file previously claimed otherwise; that claim was
/// wrong for the Athlete/participant case and is corrected here.
///
/// This type does NOT create any zone on CloudKit's servers, and does NOT
/// attempt to produce a universally-correct `CKRecordZone.ID` — see the
/// two functions below for exactly what each one is (and is not) safe
/// for.
public enum FamilyWorkspaceCloudZoneIdentifier {

    /// The deterministic, Vǫxtr-owned NAME component only — stable across
    /// every device, since it depends only on `WorkspaceId`, never on
    /// which CloudKit account is asking. Safe to use anywhere a zone
    /// NAME (not a full `CKRecordZone.ID`) is needed, including to
    /// recognize/match an already-known zone once its real owner is
    /// established some other way (see `ownerZoneID(forWorkspace:)`'s own
    /// doc comment for the owner case, and B2 for the participant case).
    ///
    /// `CKRecordZone.ID.zoneName` accepts most Unicode strings but is
    /// safest kept to a short, stable ASCII-only format — this mirrors
    /// how every stable Vǫxtr identifier already reads (`AccountId`,
    /// `WorkspaceId`, etc. all serialize a plain UUID string), not an
    /// invented CloudKit-specific convention.
    public static func zoneName(forWorkspace workspaceId: UUID) -> String {
        "voxtr.family.\(workspaceId.uuidString)"
    }

    /// OWNER-SIDE ONLY. Produces the `CKRecordZone.ID` the CURRENT
    /// device's own CloudKit user should use to CREATE or address ITS
    /// OWN `FamilyWorkspace` zone in `privateCloudDatabase` — correct
    /// exactly because `CKCurrentUserDefaultName` means "the current
    /// user," and on this path the current user genuinely IS the zone's
    /// owner (the Parent, creating/owning the share).
    ///
    /// DO NOT call this to address a zone that was SHARED TO the current
    /// device by another owner (the Athlete's view of the Parent's
    /// FamilyWorkspace zone, accessed via `sharedCloudDatabase`) —
    /// `CKCurrentUserDefaultName` would then resolve to the wrong
    /// identity (the accepting Athlete, not the owning Parent), silently
    /// failing to address the real zone. B2 must instead retain/use the
    /// actual `CKRecordZone.ID` (including its true, owner-identifying
    /// `ownerName`) that CloudKit itself reports once discovered — via
    /// `CKSyncEngine`/shared-database change enumeration or `CKShare`/
    /// `CKShare.Metadata`, never reconstructed locally on AthleteApp. Do
    /// not invent the Parent's `ownerName` on the Athlete's device.
    public static func ownerZoneID(forWorkspace workspaceId: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName(forWorkspace: workspaceId), ownerName: CKCurrentUserDefaultName)
    }
}
