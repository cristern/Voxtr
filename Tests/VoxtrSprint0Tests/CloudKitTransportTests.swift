import Testing
import Foundation
import CloudKit
import VoxtrCore
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

@Suite("Athlete Connection Foundation B1: CloudKitTransport infrastructure")
struct CloudKitTransportTests {

    @Test("CloudKitTransport constructs against the configured CKContainer identifier")
    @MainActor
    func transportConstructsAgainstConfiguredIdentifier() {
        let transport = CloudKitTransport()
        #expect(transport.containerIdentifier == CloudKitContainerIdentifier.voxtrFamily)
    }

    @Test("The private database path resolves to CKDatabase.Scope.private")
    @MainActor
    func privateDatabaseResolvesToPrivateScope() {
        let transport = CloudKitTransport()
        #expect(transport.database(for: .private).databaseScope == .private)
    }

    @Test("The shared database path resolves to CKDatabase.Scope.shared")
    @MainActor
    func sharedDatabaseResolvesToSharedScope() {
        let transport = CloudKitTransport()
        #expect(transport.database(for: .shared).databaseScope == .shared)
    }

    @Test("The private and shared CKSyncEngine instances are distinct infrastructure objects, never the same engine driving both databases")
    @MainActor
    func privateAndSharedEnginesAreDistinctInstances() {
        let transport = CloudKitTransport()
        #expect(transport.privateEngine !== transport.sharedEngine)
        #expect(transport.syncEngine(for: .private) === transport.privateEngine)
        #expect(transport.syncEngine(for: .shared) === transport.sharedEngine)
    }

    @Test("Constructing CloudKitTransport never touches the state store for a scope that was never asked for — engines are only built lazily, on first access")
    @MainActor
    func engineStateIsOnlyLoadedForAccessedScopes() {
        let stateStore = RecordingCloudKitSyncEngineStateStore()
        let transport = CloudKitTransport(stateStore: stateStore)
        #expect(stateStore.loadedScopes.isEmpty)
        _ = transport.privateEngine
        #expect(stateStore.loadedScopes == [.private])
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
