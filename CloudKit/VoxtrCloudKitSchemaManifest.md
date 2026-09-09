# Vǫxtr CloudKit Schema Manifest

Operational reference for `VoxtrCloudKitSchema.ckdb`. Not a design
document — see `Docs/AthleteConnectionFoundationB-Discovery.md` and
`Docs/AthleteConnectionFoundationB-Closeout.md` for architecture rationale
and runtime closeout. This file states what exists and how to deploy it.

## Container

`iCloud.app.voxtr.shared`

## Current deployment/runtime status

The Vǫxtr custom schema below has been imported into CloudKit Development
and deployed to Production.

Runtime validation established two separate prerequisites for Parent-side
Athlete Connection share creation:

1. the final signed ParentApp must actually carry the CloudKit/container
   entitlements authorised by its provisioning profile; and
2. CloudKit's own sharing support schema must exist in the target
   environment in addition to Vǫxtr's custom record types.

The first issue was fixed in Parent Release signing before this schema
closeout. After the custom Vǫxtr schema was deployed, Parent TestFlight
progressed from `sharing-root-save · invalidArguments` to
`share-save · invalidArguments`. CloudKit Production logs for that second
failure showed `BAD_REQUEST`, `USER_ERROR`, `returnedRecordTypes:
"_pcs_data"` while saving the share.

A one-time ParentApp build targeting CloudKit Development then performed a
real `CKShare` save. CloudKit generated its own `cloudkit.share` system
record type in Development. After **Deploy Schema Changes...** promoted
that generated sharing schema to Production, the normal TestFlight
ParentApp successfully progressed through the share-creation path.

This is a Vǫxtr runtime-verified operational fact. It should not be treated
as permission to model CloudKit system schema in the repository.

## CloudKit-managed sharing schema

`cloudkit.share` and `_pcs_data` are CloudKit-managed sharing/system
concepts. They are **not** part of Vǫtr's application schema and must not
be added manually to `VoxtrCloudKitSchema.ckdb` or to the Swift mapping
field manifests below.

If a fresh CloudKit container/environment later exhibits the same
`share-save · invalidArguments` / `BAD_REQUEST` / `_pcs_data` signature and
`cloudkit.share` is absent from Development, the verified recovery path is:

1. run a correctly signed physical-device build against CloudKit
   **Development**;
2. perform one real `CKShare` save;
3. confirm CloudKit generated `cloudkit.share` under Development → Schema →
   Record Types;
4. use **Deploy Schema Changes...** to promote the resulting Development
   schema to Production; and
5. retry the normal Production/TestFlight build.

The temporary Codemagic workflow used for the one-time Vǫxtr bootstrap was
kept out of `develop`; PR #79 was closed unmerged after successful runtime
validation. Recreate such tooling only if this bootstrap is genuinely
needed again.

## Custom zone naming (not part of the imported schema — created by app code)

CloudKit schema does not declare zones; Vǫxtr creates the zone
programmatically. Documented here for completeness:

- Zone name: `voxtr.family.<FamilyWorkspace.id>` (deterministic per
  workspace) — `FamilyWorkspaceCloudZoneIdentifier.zoneName(forWorkspace:)`.
- The Parent's device owns this zone in its own private database
  (`CKRecordZone.ID(zoneName:, ownerName: CKCurrentUserDefaultName)`).
- Both custom record types below live in this SAME zone. Neither the
  zone nor either record type is ever written to the public database.

## Record types

### `FamilyWorkspace`

The sharing root for a family's workspace. One per `FamilyWorkspace`,
addressed by a deterministic record name derived from `workspaceId`.

| Field | CloudKit type | Swift source | Required | Read back |
|---|---|---|---|---|
| `workspaceId` | `STRING` | `UUID.uuidString` | yes | yes (`payload(from:)`) |
| `mappingVersion` | `INT64` | `Int64` constant (`1`) | yes | no — written for forward compatibility, not currently read by any code path |

Maps to: `FamilyWorkspaceCloudRecordMapping.makeRecord(for:zoneID:)` /
`.payload(from:)`.

### `AthleteConnectionInvitation`

One immutable record per invitation (never reused/overwritten across
invitations — see that mapping file's own doc comment for why). Root of
its own dedicated `CKShare`, independent of `FamilyWorkspace`'s share.

| Field | CloudKit type | Swift source | Required | Read back |
|---|---|---|---|---|
| `workspaceId` | `STRING` | `UUID.uuidString` | yes | yes |
| `intendedParticipantId` | `STRING` | `UUID.uuidString` | yes | yes |
| `intendedAthleteId` | `STRING` | `UUID.uuidString` | yes | yes |
| `parentId` | `STRING` | `UUID.uuidString` | yes | yes |
| `parentGivenName` | `STRING` | `String` | yes | yes |
| `workspaceDisplayName` | `STRING` | `String` | yes | yes |
| `ownerParticipantId` | `STRING` | `UUID.uuidString` | yes | yes |
| `athleteGivenName` | `STRING` | `String` | yes | yes |
| `athleteBirthDateISO` | `STRING` | `LocalDate.isoString` — an ISO date **string**, never a CloudKit `TIMESTAMP` | yes | yes |
| `athleteTimeZoneId` | `STRING` | `TimeZone` identifier rawValue | yes | yes |
| `athleteDevelopmentStage` | `STRING` | `DevelopmentStage.rawValue` | yes | yes |
| `mappingVersion` | `INT64` | `Int64` constant (`2`) | yes | no — same as `FamilyWorkspace.mappingVersion` |

Maps to: `AthleteConnectionInvitationCloudRecordMapping.makeRecord(invitationId:payload:zoneID:)`
/ `.apply(_:to:)` / `.payload(from:)`.

Every UUID-typed field is stored as its `.uuidString`, never as a
CloudKit `REFERENCE` — these are plain discriminator/hydration values
read back into local Vǫxtr identifiers, not CloudKit-native record
relationships.

## Indexes

**None required today.** Every current CloudKit access is one of:

- a direct fetch by `CKRecord.ID` (`CKDatabase.record(for:)`),
- a `CKShare` root/reference traversal (`CKRecord.share`, `CKShare.Metadata.hierarchicalRootRecordID`),
- a `CKSyncEngine` continuity-state event (no record type is mapped to a
  sync-engine change batch yet — `nextRecordZoneChangeBatch` always
  returns `nil`).

No `CKQuery`/`NSPredicate`-based lookup exists anywhere in the
repository. Do not add `QUERYABLE`/`SORTABLE`/`SEARCHABLE` to any field
until a real query requires it.

## Deployment sequence

`Import Schema...` and `Deploy Schema Changes...` are two separate,
top-level CloudKit Console actions — `Import Schema...` is not reached
through `Deploy Schema Changes...`.

### Vǫxtr custom schema

1. Open CloudKit Console.
2. Select container `iCloud.app.voxtr.shared`.
3. Select **Development**.
4. Choose **Import Schema...**.
5. Import `VoxtrCloudKitSchema.ckdb`.
6. Review **Schema → Record Types** and confirm:
   - `FamilyWorkspace`
   - `AthleteConnectionInvitation`
   - the exact fields/types listed above, with no unexpected application
     fields, grants, or indexes.
7. Choose **Deploy Schema Changes...**.
8. Deploy the reviewed Development schema to Production. Production is
   otherwise locked, per normal CloudKit environment lifecycle.

### CloudKit sharing system schema, only when missing

9. If a real share save still fails with the verified
   `share-save · invalidArguments` / `BAD_REQUEST` / `_pcs_data` signature,
   inspect Development → Schema → Record Types for `cloudkit.share`.
10. If `cloudkit.share` is absent, use a correctly signed physical-device
    Development build and perform one real `CKShare` save.
11. Confirm CloudKit generated `cloudkit.share` in Development.
12. Choose **Deploy Schema Changes...** again and promote the resulting
    Development schema to Production.
13. Return to the normal TestFlight ParentApp and retry **Connect Athlete
    App**. No application code change is required merely to promote schema.

## Keeping this file in sync

If a mapped field is renamed, added, or removed in
`FamilyWorkspaceCloudRecordMapping.swift` or
`AthleteConnectionInvitationCloudRecordMapping.swift`, update this table
and `VoxtrCloudKitSchema.ckdb` together, then re-run the schema-drift
tests in `CloudKitTransportTests.swift`
(`FamilyWorkspaceCloudRecordMappingTests`/
`AthleteConnectionInvitationCloudRecordMappingTests` — the tests named
`...RecordFieldsMatchSchemaManifest`) — they fail if the Swift mapping's
actual `CKRecord` field set no longer matches the field lists above.

Do not add CloudKit-managed system fields/types such as `cloudkit.share`
or `_pcs_data` to those drift tests or to the repository schema artifact.
