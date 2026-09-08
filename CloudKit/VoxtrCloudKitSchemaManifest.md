# Vǫxtr CloudKit Schema Manifest

Operational reference for `VoxtrCloudKitSchema.ckdb`. Not a design
document — see `Docs/AthleteConnectionFoundationB-Discovery.md` for
architecture rationale. This file states what exists and how to deploy
it.

## Container

`iCloud.app.voxtr.shared`

## Current diagnostic this schema fixes

TestFlight Parent builds fail Athlete Connection with:

```
AthleteInviteCloudKit stage=sharing-root-save ckCode=invalidArguments ckCodeRaw=12
```

CloudKit Console confirms Production is locked (expected) and
Development contains only the built-in `Users` record type — Vǫxtr's own
custom record types have never been deployed to either environment.
Importing `VoxtrCloudKitSchema.ckdb` into Development, then deploying to
Production, is expected to resolve this without a new app build.

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

1. **Development**: CloudKit Console → container `iCloud.app.voxtr.shared`
   → Development environment → Schema → "Deploy Schema Changes..." →
   Import Schema → select `VoxtrCloudKitSchema.ckdb`.
2. **Review**: confirm the two record types and their fields above
   appear exactly as listed, with no unexpected additional fields,
   grants, or indexes.
3. **Production**: CloudKit Console → "Deploy Schema Changes..." →
   deploy the reviewed Development schema to Production. Production
   is otherwise locked, per normal CloudKit environment lifecycle.
4. **Retry**: the existing TestFlight Parent build can retry "Connect
   Athlete App" against Production immediately after step 3 — no new
   app build is required, since nothing about the CKRecord shape
   changes, only the schema CloudKit was missing.

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
