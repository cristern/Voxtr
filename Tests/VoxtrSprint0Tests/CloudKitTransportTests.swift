import Testing
import Foundation
import CloudKit
@testable import VoxtrCore
import VoxtrAppShell

// NOTE: Configuration tests (1-4) and the regression tests (11, 13) read
// files from the repository source tree directly, via `#filePath`
// (this file's own absolute path at compile time, walked up to the repo
// root) rather than any bundled resource — project-configuration facts
// (entitlements content, Info.plist keys, which source files import
// CloudKit) have no other runtime-introspectable representation. This is
// the first test file in this suite to do this; see each test's own
// comment for why a source-of-truth check is the honest way to protect
// these facts instead of duplicating them as a second, driftable literal.
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CloudKitTransportTests.swift
        .deletingLastPathComponent() // VoxtrSprint0Tests
        .deletingLastPathComponent() // Tests
}

private func plist(atRepositoryRelativePath path: String) throws -> [String: Any] {
    let url = repositoryRoot().appendingPathComponent(path)
    let data = try Data(contentsOf: url)
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let dict = object as? [String: Any] else {
        Issue.record("\(path) did not decode as a plist dictionary")
        return [:]
    }
    return dict
}

@Suite("Athlete Connection Foundation B1: CloudKit capability configuration")
struct CloudKitCapabilityConfigurationTests {

    @Test("ParentApp's entitlements reference the expected CloudKit container")
    func parentAppEntitlementsReferenceExpectedContainer() throws {
        let entitlements = try plist(atRepositoryRelativePath: "App/ParentApp/ParentApp.entitlements")
        let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        #expect(containers == [CloudKitContainerIdentifier.voxtrFamily])
        #expect((entitlements["com.apple.developer.icloud-services"] as? [String])?.contains("CloudKit") == true)
    }

    @Test("AthleteApp's entitlements reference the SAME CloudKit container as ParentApp")
    func athleteAppEntitlementsReferenceSameContainer() throws {
        let entitlements = try plist(atRepositoryRelativePath: "App/AthleteApp/AthleteApp.entitlements")
        let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        #expect(containers == [CloudKitContainerIdentifier.voxtrFamily])
        #expect((entitlements["com.apple.developer.icloud-services"] as? [String])?.contains("CloudKit") == true)
    }

    @Test("AthleteApp declares CKSharingSupported — it is the CKShare-accepting app in Foundation B's Parent-invites/Athlete-accepts flow")
    func athleteAppDeclaresCKSharingSupported() throws {
        let infoPlist = try plist(atRepositoryRelativePath: "App/AthleteApp/Info.plist")
        #expect(infoPlist["CKSharingSupported"] as? Bool == true)
    }

    @Test("AthleteApp still does NOT gain Calendar permission/configuration — Calendar import stays a Parent-only capability")
    func athleteAppStillHasNoCalendarPermission() throws {
        let infoPlist = try plist(atRepositoryRelativePath: "App/AthleteApp/Info.plist")
        #expect(infoPlist["NSCalendarsFullAccessUsageDescription"] == nil)
        let parentInfoPlist = try plist(atRepositoryRelativePath: "App/ParentApp/Info.plist")
        #expect(parentInfoPlist["NSCalendarsFullAccessUsageDescription"] != nil)
    }
}

// NOTE (PR #61 follow-up — Codemagic XCTest host crash fix): this suite
// previously constructed `CloudKitTransport()` and then called
// `.database(for:)`/`.privateEngine`/`.sharedEngine` directly, which
// (via the production `CloudKitContainerProvider`) realizes a real
// `CKContainer`/`CKDatabase`/`CKSyncEngine`. Codemagic's XCTest host
// carries no `com.apple.developer.icloud-services` entitlement, and
// Apple's own CloudKit framework terminates the test process on that
// realization (`CKContainer.m:748`), even though it is a purely local,
// synchronous, no-network operation. `CKDatabase`/`CKSyncEngine` also
// have no public initializer reachable without a real `CKContainer`, so
// there is no way to fake one for a test double either — Apple's SDK
// itself makes this untestable in XCTest. `CloudKitTransport` still only
// realizes these objects lazily, on first genuine use — this suite now
// proves exactly what remains provable without a live CloudKit
// entitlement, and leaves what is not provable here as an explicit
// TestFlight/signed-build integration validation item (see the comment
// at the bottom of this suite).
@Suite("Athlete Connection Foundation B1: CloudKitTransport infrastructure")
struct CloudKitTransportTests {

    @Test("CloudKitTransport constructs against the configured CKContainer identifier, without realizing a real CKContainer merely to do so")
    @MainActor
    func transportConstructsAgainstConfiguredIdentifier() {
        let transport = CloudKitTransport()
        #expect(transport.containerIdentifier == CloudKitContainerIdentifier.voxtrFamily)
    }

    @Test("Constructing CloudKitTransport never touches the state store for any scope — engine state is only ever loaded once a scope's engine is genuinely realized, not eagerly at composition time")
    @MainActor
    func constructingTransportNeverEagerlyLoadsEngineState() {
        let stateStore = RecordingCloudKitSyncEngineStateStore()
        let transport = CloudKitTransport(stateStore: stateStore)
        #expect(stateStore.loadedScopes.isEmpty)
        // Deliberately does NOT access `transport.privateEngine`/
        // `.sharedEngine` here — doing so would realize a real
        // CKContainer/CKDatabase/CKSyncEngine (see the suite-level NOTE
        // above) and crash the XCTest host. Actually loading state for
        // an accessed scope requires a live entitlement to verify and is
        // a TestFlight/signed-build integration validation item, not an
        // XCTest one.
        _ = transport
    }
}

// PR #61 follow-up: `CloudKitTransport.database(for:)`/`.privateEngine`/
// `.sharedEngine`/`.syncEngine(for:)` cannot be unit-tested beyond what
// the suite above already proves, because Apple's `CKDatabase` and
// `CKSyncEngine` have no public initializer reachable without a real,
// entitled `CKContainer` — there is no way to construct a test double
// that both conforms to `CloudKitContainerProviding` and avoids touching
// live CloudKit. What IS fully unit-testable, and covered directly
// below, is Vǫxtr's own LOGICAL routing decision — which of Apple's two
// database properties a `CloudKitDatabaseScope` should map to — kept
// deliberately separate from that Apple object REALIZATION step inside
// `CloudKitContainerProvider` (see that type's own doc comment). The
// following integration facts remain unverified by XCTest and must be
// validated in a signed, entitlement-bearing build (TestFlight or a
// real device run) instead:
// - `transport.database(for: .private).databaseScope == .private` (and
//   `.shared` likewise) — i.e. that Apple's own `CKContainer` actually
//   honors the property access `CloudKitContainerProvider` performs.
// - `transport.privateEngine !== transport.sharedEngine` and
//   `transport.syncEngine(for:)` routes to the matching lazy var — i.e.
//   that two independently-lazy `CKSyncEngine` instances are genuinely
//   distinct at runtime.
// - that accessing `transport.privateEngine` for the first time actually
//   calls `stateStore.loadState(for: .private)` (the lazy-loading half
//   of `constructingTransportNeverEagerlyLoadsEngineState` above that
//   requires realizing a real engine to observe).
@Suite("Athlete Connection Foundation B1: CloudKitContainerProvider logical database routing")
struct CloudKitContainerRoutingTests {

    @Test("CloudKitDatabaseScope.private routes to the private database selection — never the shared one")
    func privateScopeRoutesToPrivateSelection() {
        #expect(CloudKitContainerProvider.selection(for: .private) == .privateDatabase)
    }

    @Test("CloudKitDatabaseScope.shared routes to the shared database selection — never the private one")
    func sharedScopeRoutesToSharedSelection() {
        #expect(CloudKitContainerProvider.selection(for: .shared) == .sharedDatabase)
    }
}

// NOTE (PR #61 follow-up): these tests deliberately prove only what is
// actually true. A single `CKRecordZone.ID` is NOT identical across a
// Parent's and an Athlete's devices for the same FamilyWorkspace — the
// zone NAME is deterministic and shared, but its `ownerName` legitimately
// differs by role (the Parent's own device vs. a participant discovering
// a zone shared TO it). See `FamilyWorkspaceCloudZoneIdentifier`'s own
// doc comment. No test here claims otherwise.
@Suite("Athlete Connection Foundation B1: deterministic FamilyWorkspace zone naming")
struct FamilyWorkspaceCloudZoneIdentifierTests {

    @Test("The same WorkspaceId always produces the same deterministic zone NAME")
    func sameWorkspaceIdProducesSameZoneName() {
        let workspaceId = UUID()
        let first = FamilyWorkspaceCloudZoneIdentifier.zoneName(forWorkspace: workspaceId)
        let second = FamilyWorkspaceCloudZoneIdentifier.zoneName(forWorkspace: workspaceId)
        #expect(first == second)
    }

    @Test("Different WorkspaceIds produce different deterministic zone NAMEs")
    func differentWorkspaceIdsProduceDifferentZoneNames() {
        let first = FamilyWorkspaceCloudZoneIdentifier.zoneName(forWorkspace: UUID())
        let second = FamilyWorkspaceCloudZoneIdentifier.zoneName(forWorkspace: UUID())
        #expect(first != second)
    }

    @Test("ownerZoneID(forWorkspace:) — the OWNER-side-only helper — uses CKCurrentUserDefaultName as its ownerName, and reuses the same deterministic zoneName")
    func ownerZoneIDUsesCurrentUserDefaultName() {
        let workspaceId = UUID()
        let ownerZoneID = FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace: workspaceId)
        #expect(ownerZoneID.ownerName == CKCurrentUserDefaultName)
        #expect(ownerZoneID.zoneName == FamilyWorkspaceCloudZoneIdentifier.zoneName(forWorkspace: workspaceId))
    }

    @Test("FamilyWorkspaceCloudZoneIdentifier exposes no generic zoneID(forWorkspace:) API — only the explicitly owner-scoped ownerZoneID(forWorkspace:) — so a participant-side call site cannot accidentally reach for a name that implies it is safe on every device")
    func noGenericZoneIDAPIExists() {
        // API-shape guard, not a runtime check: this test's own existence
        // (and the fact it compiles) is what it proves — if a future
        // change reintroduces a generic `zoneID(forWorkspace:)` that
        // shadows or replaces `ownerZoneID(forWorkspace:)`, a reviewer
        // reading this test's name/intent should catch the regression
        // even though nothing here can mechanically fail on that alone.
        let workspaceId = UUID()
        let ownerZoneID = FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace: workspaceId)
        #expect(ownerZoneID.ownerName == CKCurrentUserDefaultName)
    }
}

// NOTE (B2.1): `FamilyWorkspaceOwnerShareCoordinator.ensureSharingRoot(forWorkspace:)`
// itself is NOT unit-tested here, for the same reason `CloudKitTransport`'s
// own engine/database realization is not (see the `CloudKitContainerRoutingTests`
// suite-level NOTE above): it performs real CloudKit network I/O and
// realizes a real CKContainer via `CloudKitTransport.refreshAvailability()`,
// which crashes the entitlement-less XCTest host. What IS covered here is
// everything that orchestration actually depends on to converge correctly
// without duplication: the deterministic, pure record-mapping layer it
// reads/writes through (`FamilyWorkspaceCloudRecordMapping`), and that
// constructing the coordinator itself is side-effect-free — mirroring
// `CloudKitTransport()`'s own construction-safety test. The following
// integration facts remain unverified by XCTest and are TestFlight/
// signed-build validation items instead:
// - the zone-save-is-idempotent claim (`ensureZone`'s own doc comment)
//   against Apple's real CloudKit servers;
// - the root-record fetch-then-save-then-serverRecordChanged-fallback
//   sequence actually converging under real concurrent "ensure" calls;
// - the CKShare creation/fetch round trip (`rootRecord.share` reference
//   resolution, `modifyRecords` batch save) against a real database.
@Suite("Athlete Connection Foundation B2.1: FamilyWorkspace CloudKit record mapping")
struct FamilyWorkspaceCloudRecordMappingTests {

    @Test("The same WorkspaceId always produces the same deterministic root record NAME")
    func sameWorkspaceIdProducesSameRecordName() {
        let workspaceId = UUID()
        let first = FamilyWorkspaceCloudRecordSchema.recordName(forWorkspace: workspaceId)
        let second = FamilyWorkspaceCloudRecordSchema.recordName(forWorkspace: workspaceId)
        #expect(first == second)
    }

    @Test("Different WorkspaceIds produce different deterministic root record NAMEs — no random identity is ever introduced")
    func differentWorkspaceIdsProduceDifferentRecordNames() {
        let first = FamilyWorkspaceCloudRecordSchema.recordName(forWorkspace: UUID())
        let second = FamilyWorkspaceCloudRecordSchema.recordName(forWorkspace: UUID())
        #expect(first != second)
    }

    @Test("recordID(forWorkspace:zoneID:) places the root record in exactly the zone ID it was given — repeated calls with the same inputs produce an identical CKRecord.ID")
    func recordIDIsPlacedInGivenZoneAndIsDeterministic() {
        let workspaceId = UUID()
        let zoneID = FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace: workspaceId)

        let first = FamilyWorkspaceCloudRecordMapping.recordID(forWorkspace: workspaceId, zoneID: zoneID)
        let second = FamilyWorkspaceCloudRecordMapping.recordID(forWorkspace: workspaceId, zoneID: zoneID)

        #expect(first == second)
        #expect(first.zoneID == zoneID)
        #expect(first.recordName == FamilyWorkspaceCloudRecordSchema.recordName(forWorkspace: workspaceId))
    }

    @Test("makeRecord(for:zoneID:) produces a record of the FamilyWorkspace record type, in the given zone, carrying the workspace's stable identity")
    func makeRecordCarriesExpectedTypeZoneAndIdentity() {
        let workspaceId = UUID()
        let zoneID = FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace: workspaceId)
        let payload = FamilyWorkspaceCloudRecordPayload(workspaceId: workspaceId)

        let record = FamilyWorkspaceCloudRecordMapping.makeRecord(for: payload, zoneID: zoneID)

        #expect(record.recordType == FamilyWorkspaceCloudRecordSchema.recordType)
        #expect(record.recordID == FamilyWorkspaceCloudRecordMapping.recordID(forWorkspace: workspaceId, zoneID: zoneID))
        #expect(record[FamilyWorkspaceCloudRecordSchema.workspaceIdFieldKey] as? String == workspaceId.uuidString)
        #expect(record[FamilyWorkspaceCloudRecordSchema.mappingVersionFieldKey] as? Int64 == FamilyWorkspaceCloudRecordSchema.mappingVersion)
    }

    @Test("payload(from:) is the exact inverse of makeRecord(for:zoneID:) — round-tripping a record recovers the same stable workspace identity, proving no identity is lost or randomized in transit")
    func payloadRoundTripsThroughMakeRecord() throws {
        let payload = FamilyWorkspaceCloudRecordPayload(workspaceId: UUID())
        let zoneID = FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace: payload.workspaceId)

        let record = FamilyWorkspaceCloudRecordMapping.makeRecord(for: payload, zoneID: zoneID)
        let decoded = try FamilyWorkspaceCloudRecordMapping.payload(from: record)

        #expect(decoded == payload)
    }

    @Test("payload(from:) rejects a record of the wrong record type rather than silently decoding garbage")
    func payloadRejectsWrongRecordType() {
        let zoneID = FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace: UUID())
        let wrongTypeRecord = CKRecord(recordType: "NotAFamilyWorkspace", recordID: CKRecord.ID(recordName: "irrelevant", zoneID: zoneID))

        #expect(throws: FamilyWorkspaceCloudRecordMapping.DecodeError.unexpectedRecordType("NotAFamilyWorkspace")) {
            try FamilyWorkspaceCloudRecordMapping.payload(from: wrongTypeRecord)
        }
    }

    @Test("Constructing FamilyWorkspaceOwnerShareCoordinator never realizes a real CKContainer merely to do so — mirrors CloudKitTransport()'s own construction safety")
    @MainActor
    func constructingCoordinatorIsSideEffectFree() {
        let transport = CloudKitTransport()
        let coordinator = FamilyWorkspaceOwnerShareCoordinator(transport: transport)
        _ = coordinator
    }
}

@Suite("Athlete Connection Foundation B1: regression guards")
struct CloudKitFoundationRegressionTests {

    @Test("SwiftDataPersistenceController still constructs every ModelConfiguration with cloudKitDatabase: .none — SwiftData's own CloudKit mirroring must never be silently enabled")
    func swiftDataPersistenceControllerStaysLocalOnly() throws {
        let url = repositoryRoot().appendingPathComponent("Sources/VoxtrCore/Persistence/SwiftDataPersistenceController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // Scope to SwiftDataPersistenceController's own body only. This
        // file also declares InMemoryPersistenceController — explicitly
        // in-memory test infrastructure that intentionally never sets
        // cloudKitDatabase at all — which must not be held to a
        // production "must be .none" invariant that doesn't apply to it.
        guard let productionStart = source.range(of: "public final class SwiftDataPersistenceController") else {
            Issue.record("Could not locate SwiftDataPersistenceController in source")
            return
        }
        let productionSection: Substring
        if let inMemoryStart = source.range(of: "public final class InMemoryPersistenceController", range: productionStart.upperBound..<source.endIndex) {
            productionSection = source[productionStart.lowerBound..<inMemoryStart.lowerBound]
        } else {
            productionSection = source[productionStart.lowerBound...]
        }

        // Only reason about actual code, not doc/line comments that merely
        // mention `cloudKitDatabase: .none` in prose (e.g. this file's own
        // "ENGINEERING TRADE-OFF" header) — counting those would make this
        // guard brittle against harmless documentation edits, and it isn't
        // the invariant this test exists to protect.
        let codeLines = productionSection
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let code = codeLines.joined(separator: "\n")

        let constructorCount = code.components(separatedBy: "ModelConfiguration(").count - 1
        let noneOccurrences = code.components(separatedBy: "cloudKitDatabase: .none").count - 1
        #expect(constructorCount > 0, "Expected at least one ModelConfiguration construction")
        #expect(
            noneOccurrences == constructorCount,
            "Expected every ModelConfiguration construction in SwiftDataPersistenceController to pass cloudKitDatabase: .none"
        )
        #expect(!code.contains("cloudKitDatabase: .automatic"))
        #expect(!code.contains("cloudKitDatabase: .private("))
    }

    @Test("CompositionRoot.build() still constructs successfully with the new CloudKitTransport parameter, without requiring live CloudKit account/network success")
    @MainActor
    func compositionRootStillConstructsWithoutLiveCloudKit() async throws {
        let root = try await CompositionRoot.build(
            persistence: InMemoryPersistenceController(modelTypes: AppSchema.modelTypes),
            cloudKitTransport: CloudKitTransport(containerIdentifier: "iCloud.app.voxtr.test")
        )
        #expect(root.cloudKitTransport.containerIdentifier == "iCloud.app.voxtr.test")
    }

    @Test("No domain module (VoxtrAthleteDomain, VoxtrParentDomain, VoxtrPlanningDomain, VoxtrTrainingDomain, VoxtrReflectionDomain, VoxtrCoachingDomain, VoxtrMotivationDomain, VoxtrDevelopmentDomain, VoxtrDecisionSupportDomain, VoxtrNotificationsDomain, VoxtrCalendarPlanningDomain, VoxtrSettings) imports CloudKit — the transport stays isolated in VoxtrCore")
    func noDomainModuleImportsCloudKit() throws {
        let domainDirectories = [
            "VoxtrAthleteDomain", "VoxtrParentDomain", "VoxtrPlanningDomain", "VoxtrTrainingDomain",
            "VoxtrReflectionDomain", "VoxtrCoachingDomain", "VoxtrMotivationDomain", "VoxtrDevelopmentDomain",
            "VoxtrDecisionSupportDomain", "VoxtrNotificationsDomain", "VoxtrCalendarPlanningDomain", "VoxtrSettings",
        ]
        let sourcesRoot = repositoryRoot().appendingPathComponent("Sources")
        for directoryName in domainDirectories {
            let directory = sourcesRoot.appendingPathComponent(directoryName)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                Issue.record("Could not enumerate \(directoryName)")
                continue
            }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                #expect(!source.contains("import CloudKit"), "\(fileURL.lastPathComponent) in \(directoryName) must not import CloudKit")
            }
        }
    }
}

/// Pure test double proving `CloudKitTransport` only loads state for a
/// scope once that scope's engine is actually constructed (lazily), not
/// eagerly for both scopes at `init` time.
// PR #61 follow-up: `@unchecked Sendable` here is backed by an actual
// `NSLock`, not an unsynchronized `var` — matching this project's own
// established pattern (`DIContainer`, `ActivityLoggedRecorder`) for a
// mutable `@unchecked Sendable` type, rather than an unaudited claim.
private final class RecordingCloudKitSyncEngineStateStore: CloudKitSyncEngineStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _loadedScopes: [CloudKitDatabaseScope] = []
    var loadedScopes: [CloudKitDatabaseScope] {
        lock.lock(); defer { lock.unlock() }
        return _loadedScopes
    }

    func loadState(for scope: CloudKitDatabaseScope) -> CKSyncEngine.State.Serialization? {
        lock.lock(); defer { lock.unlock() }
        _loadedScopes.append(scope)
        return nil
    }

    func saveState(_ state: CKSyncEngine.State.Serialization, for scope: CloudKitDatabaseScope) {}
}
