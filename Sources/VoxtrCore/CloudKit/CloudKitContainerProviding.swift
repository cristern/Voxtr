import CloudKit
import Foundation

/// Athlete Connection Foundation B1 (PR #61 follow-up — Codemagic XCTest
/// host crash fix): the seam that separates Vǫxtr's own LOGICAL routing
/// decision (`CloudKitDatabaseScope`) from Apple's CloudKit object
/// REALIZATION (`CKContainer`/`CKDatabase`/`CKAccountStatus`).
///
/// WHY THIS EXISTS: Codemagic's XCTest host carries no
/// `com.apple.developer.icloud-services` entitlement (only the
/// ParentApp/AthleteApp targets do). Merely constructing a real
/// `CKContainer`, or reading `.privateCloudDatabase`/
/// `.sharedCloudDatabase` on one, triggers Apple's own "Significant
/// issue" check (`CKContainer.m:748`) and terminates the test process —
/// with no network call involved. `CloudKitTransport`'s own previous doc
/// comment claimed constructing these objects was side-effect-free and
/// therefore safe to do unconditionally at composition-root time; that
/// claim is corrected here, since Codemagic proved it false. Production
/// app targets carry the entitlement and are unaffected; XCTest does
/// not, so `CloudKitTransport` must never realize a real `CKContainer`
/// as a side effect of being constructed or unit-tested — it goes
/// through this protocol instead, so a test-only implementation can
/// stand in without ever touching real CloudKit runtime state.
///
/// PR #61 follow-up (Codemagic Swift 6 actor-isolation fix): this
/// protocol is `@MainActor` because its one real caller,
/// `CloudKitTransport`, is itself `@MainActor` and this seam exists
/// purely to serve that type — B1 has no requirement for CloudKit
/// realization from any other actor. Making the protocol (and its
/// production conformance) MainActor-isolated, rather than leaving it
/// `nonisolated` and marking the concrete provider `@unchecked Sendable`,
/// means `CloudKitTransport.refreshAvailability()`'s `await
/// containerProvider.accountStatus()` never "sends" a non-Sendable
/// reference across an actor boundary in the first place — caller and
/// callee share the same isolation domain throughout, which is what
/// Swift 6 actually requires here, not an unchecked escape hatch.
@MainActor
protocol CloudKitContainerProviding {
    func database(for scope: CloudKitDatabaseScope) -> CKDatabase
    func accountStatus() async throws -> CKAccountStatus
}

/// The one production implementation. `CKContainer` itself is realized
/// LAZILY, on first actual use (`database(for:)`/`accountStatus()`) —
/// constructing `CloudKitContainerProvider` itself only stores a
/// container identifier string, so it is always safe regardless of
/// entitlement.
@MainActor
final class CloudKitContainerProvider: CloudKitContainerProviding {

    private let containerIdentifier: String
    private lazy var container = CKContainer(identifier: containerIdentifier)

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    /// LOGICAL routing only — which of Apple's two database properties a
    /// `CloudKitDatabaseScope` maps to. Kept as its own step, deliberately
    /// free of any real `CKDatabase`/`CKContainer` type, rather than
    /// inlined directly into `database(for:)`'s switch — so this specific
    /// mapping decision (Vǫxtr's own routing choice) can be unit-tested
    /// on its own, without the APPLE OBJECT REALIZATION step below it
    /// (`container.privateCloudDatabase`/`.sharedCloudDatabase`) ever
    /// running. See `CloudKitContainerRoutingTests` in
    /// `CloudKitTransportTests.swift`.
    ///
    /// `nonisolated` deliberately: this switch touches no CloudKit
    /// runtime state and no property of `self` (`containerIdentifier`/
    /// `container`) — it is pure, so it does not need to inherit
    /// `CloudKitContainerProvider`'s `@MainActor` isolation, and keeping
    /// it `nonisolated` lets the routing unit tests call it synchronously
    /// without themselves needing to run on `@MainActor`.
    nonisolated static func selection(for scope: CloudKitDatabaseScope) -> CloudKitDatabaseSelection {
        switch scope {
        case .private: .privateDatabase
        case .shared: .sharedDatabase
        }
    }

    func database(for scope: CloudKitDatabaseScope) -> CKDatabase {
        switch Self.selection(for: scope) {
        case .privateDatabase: container.privateCloudDatabase
        case .sharedDatabase: container.sharedCloudDatabase
        }
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }
}

/// Which of Apple's two database properties a `CloudKitDatabaseScope`
/// resolves to — the LOGICAL half of `CloudKitContainerProvider.database(for:)`,
/// deliberately kept free of any real `CKDatabase`/`CKContainer` type so
/// it can be exercised by a plain unit test with no CloudKit entitlement.
/// `Sendable`: a plain, payload-free enum — trivially safe to cross any
/// actor boundary, and returned by the `nonisolated` `selection(for:)`
/// above.
enum CloudKitDatabaseSelection: Equatable, Sendable {
    case privateDatabase
    case sharedDatabase
}
