import CloudKit
import Foundation
import os

/// Athlete Connection Foundation B1: the ONE infrastructure boundary
/// through which Vǫxtr talks to CloudKit. Nothing outside this file (and
/// its sibling files in `Sources/VoxtrCore/CloudKit/`) touches `CKRecord`,
/// `CKDatabase`, `CKContainer`, `CKShare`, or `CKSyncEngine` directly —
/// Planning/Training/Reflection/etc. domain modules never import
/// `CloudKit` at all (verified by repo-wide audit; see the B1 delivery
/// report).
///
/// ARCHITECTURE BOUNDARIES this type deliberately preserves (Foundation B
/// discovery, restated here so a future reader does not accidentally
/// collapse them):
/// - CloudKit transport ≠ domain owner. This type moves bytes; it never
///   decides Planning/Training/Reflection business rules.
/// - SwiftData local store ≠ CloudKit mirroring. `SwiftDataPersistenceController`
///   stays `cloudKitDatabase: .none` — this type is a SEPARATE, explicit,
///   hand-written transport, not SwiftData's own (incompatible, per
///   Foundation B discovery) CloudKit mirroring feature.
/// - `CurrentSessionActor` ≠ CloudKit user identity, and
///   `WorkspaceParticipant` ≠ `CKShare.Participant`. B2/B3 own mapping
///   between them explicitly; this type does not collapse those concepts.
///
/// SCOPE OF THIS ROUND (Foundation B1): infrastructure only.
/// - No Vǫxtr business entity is mapped to a `CKRecord` yet (no
///   `recordType` for `PlannedActivity`/`LoggedActivity`/etc. exists
///   anywhere in this codebase) — B2 owns that.
/// - No `CKShare` is created, distributed, or accepted — B2/B3 own that.
/// - No `CKRecordZone` is created on CloudKit's servers yet — this type
///   only knows how to ADDRESS the two DATABASES a zone can live in
///   (`database(for:)`/`syncEngine(for:)`), and (via
///   `FamilyWorkspaceCloudZoneIdentifier`) the deterministic NAME a
///   `FamilyWorkspace` zone will use — not how to create, populate, or
///   fully identify a specific zone across devices; see that type's own
///   doc comment for exactly why a full `CKRecordZone.ID` cannot be
///   reconstructed locally on every device.
///
/// Two independent `CKSyncEngine` instances are used, per Foundation B
/// discovery's own finding: an app may run multiple `CKSyncEngine`
/// instances in one process, each targeting a different database, but a
/// single database must never be driven by more than one engine
/// instance at a time (they would race each other).
///
/// CORRECTED OWNERSHIP SEMANTICS (PR #61 follow-up — `.private`/`.shared`
/// name CloudKit DATABASE scope, never a Parent/Athlete ROLE; do not
/// encode role assumptions into `CloudKitDatabaseScope` itself):
/// - `privateEngine` targets `CKContainer.privateCloudDatabase` — the
///   CURRENT device's own private database. What actually lives there
///   depends on which role the current device is playing: a Parent
///   device creates/owns its `FamilyWorkspace` zone here (a shareable
///   custom zone is always created by its owner in the owner's OWN
///   private database — this is a real CloudKit constraint, not a Vǫxtr
///   choice); an Athlete device's own Athlete Private Zone (Foundation B
///   discovery) also lives here, on the Athlete's device.
/// - `sharedEngine` targets `CKContainer.sharedCloudDatabase` — the
///   CURRENT device's own shared database, i.e. zones SHARED TO the
///   current user by another owner. In the Parent-invites/Athlete-accepts
///   flow: once the Athlete accepts the Parent's `CKShare`, the Athlete's
///   device addresses the Parent-owned `FamilyWorkspace` zone through
///   ITS OWN `sharedEngine`/`sharedCloudDatabase` — never through
///   `privateEngine`. The Parent's device never accesses its own
///   `FamilyWorkspace` zone via `sharedCloudDatabase` at all — it already
///   owns that zone in its own private database.
@MainActor
public final class CloudKitTransport {

    public let containerIdentifier: String
    private let containerProvider: CloudKitContainerProviding
    private let stateStore: CloudKitSyncEngineStateStoring
    private let log = VoxtrLog.logger(.cloudKit)

    public private(set) lazy var privateEngine: CKSyncEngine = makeEngine(scope: .private)
    public private(set) lazy var sharedEngine: CKSyncEngine = makeEngine(scope: .shared)

    /// `containerIdentifier` defaults to the one real Vǫxtr container
    /// (`CloudKitContainerIdentifier.voxtrFamily`) — overridable only so
    /// tests can construct this type without depending on a hardcoded
    /// literal matching production exactly, per this repo's existing
    /// testability conventions.
    ///
    /// PR #61 follow-up (Codemagic XCTest host crash fix): this
    /// initializer previously constructed a real `CKContainer`
    /// immediately, on the (incorrect) assumption that doing so was a
    /// side-effect-free local operation — Codemagic proved otherwise
    /// (`CKContainer.m:748`, "your process must have a
    /// com.apple.developer.icloud-services entitlement", fired merely
    /// from construction, no network call involved). `CKContainer`
    /// realization is now routed entirely through
    /// `CloudKitContainerProviding` (see that type's own doc comment) —
    /// the default `CloudKitContainerProvider` defers actually
    /// constructing `CKContainer` until `database(for:)`/
    /// `refreshAvailability()` is genuinely called, so plain
    /// construction of `CloudKitTransport` remains safe in an
    /// entitlement-less process (e.g. XCTest) as long as nothing then
    /// asks it to realize CloudKit.
    public convenience init(
        containerIdentifier: String = CloudKitContainerIdentifier.voxtrFamily,
        stateStore: CloudKitSyncEngineStateStoring = UserDefaultsCloudKitSyncEngineStateStore()
    ) {
        self.init(
            containerIdentifier: containerIdentifier,
            stateStore: stateStore,
            containerProvider: CloudKitContainerProvider(containerIdentifier: containerIdentifier)
        )
    }

    /// Test-only injection point (internal, reached via `@testable
    /// import` — see `CloudKitTransportTests.swift`): lets a unit test
    /// supply a `CloudKitContainerProviding` double that never realizes a
    /// real `CKContainer`, instead of the production
    /// `CloudKitContainerProvider`. Not `public` — external callers
    /// (`CompositionRoot`, ParentApp/AthleteApp) only ever need the
    /// production default above. This is the DESIGNATED initializer
    /// (assigns every stored property directly); the `public` one above
    /// is a `convenience init` that delegates here.
    init(
        containerIdentifier: String,
        stateStore: CloudKitSyncEngineStateStoring,
        containerProvider: CloudKitContainerProviding
    ) {
        self.containerIdentifier = containerIdentifier
        self.stateStore = stateStore
        self.containerProvider = containerProvider
    }

    public func database(for scope: CloudKitDatabaseScope) -> CKDatabase {
        containerProvider.database(for: scope)
    }

    public func syncEngine(for scope: CloudKitDatabaseScope) -> CKSyncEngine {
        switch scope {
        case .private: privateEngine
        case .shared: sharedEngine
        }
    }

    /// Explicit, caller-invoked account-status check — deliberately NOT
    /// called automatically from `init` or from `CompositionRoot.build()`.
    /// Per the B1 task's own instruction not to trigger production
    /// synchronization/behavior changes automatically: composing this
    /// type must stay side-effect-free at app launch; a later slice (B3,
    /// when real Athlete Connection UI needs to show availability) is
    /// where this actually gets called.
    public func refreshAvailability() async -> CloudKitAvailability {
        do {
            let status = try await containerProvider.accountStatus()
            log.info("CloudKit account status resolved.")
            return CloudKitAvailability(status)
        } catch {
            // Infrastructure must not crash on account/network failure —
            // surface the honest "could not determine" state rather than
            // propagating the raw error or fabricating `.available`.
            log.error("CloudKit account status check failed: \(error.localizedDescription, privacy: .public)")
            return .couldNotDetermine
        }
    }

    private func makeEngine(scope: CloudKitDatabaseScope) -> CKSyncEngine {
        let delegate = ScopedDelegate(scope: scope, stateStore: stateStore, log: log)
        let configuration = CKSyncEngine.Configuration(
            database: containerProvider.database(for: scope),
            stateSerialization: stateStore.loadState(for: scope),
            delegate: delegate
        )
        // `delegate` must outlive the engine; `CKSyncEngine.Configuration`
        // does not retain it strongly on our behalf in every SDK
        // revision, so it is kept alive explicitly alongside the engine
        // it serves rather than relying on that assumption.
        retainedDelegates.append(delegate)
        return CKSyncEngine(configuration)
    }

    /// See `makeEngine(scope:)`'s own comment — one retained delegate
    /// per engine, for the lifetime of this `CloudKitTransport`.
    private var retainedDelegates: [ScopedDelegate] = []

    /// Athlete Connection Foundation B1: the smallest CKSyncEngineDelegate
    /// conformance that compiles, does not fabricate business behavior,
    /// and does not discard business data silently — because no business
    /// data is mapped to CKRecord yet, there is nothing for it to
    /// discard. `handleEvent` persists sync engine continuity state
    /// (the one event this slice must handle, per Apple's own guidance)
    /// and explicitly logs every other event as "not yet mapped" rather
    /// than reacting to it — B2 is where real event handling (record
    /// mapping, conflict resolution) gets added.
    /// `nextRecordZoneChangeBatch` returns `nil`: honestly, there is
    /// nothing pending to send, since no local write path creates a
    /// CKRecord change yet.
    private final class ScopedDelegate: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
        let scope: CloudKitDatabaseScope
        let stateStore: CloudKitSyncEngineStateStoring
        let log: Logger

        init(scope: CloudKitDatabaseScope, stateStore: CloudKitSyncEngineStateStoring, log: Logger) {
            self.scope = scope
            self.stateStore = stateStore
            self.log = log
        }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            switch event {
            case .stateUpdate(let stateUpdate):
                stateStore.saveState(stateUpdate.stateSerialization, for: scope)
            default:
                log.debug("CloudKitTransport (\(String(describing: self.scope), privacy: .public)) received an event not yet mapped in Foundation B1: \(String(describing: event), privacy: .public).")
            }
        }

        func nextRecordZoneChangeBatch(
            _ context: CKSyncEngine.SendChangesContext,
            syncEngine: CKSyncEngine
        ) async -> CKSyncEngine.RecordZoneChangeBatch? {
            // Foundation B1: no Vǫxtr entity is mapped to CKRecord yet, so
            // there is genuinely nothing pending to send — `nil` is the
            // honest answer, not a stub standing in for unimplemented
            // logic. B2 owns building real pending-change batches.
            nil
        }
    }
}
