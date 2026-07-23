import Foundation

/// Abstraction over "is remote sync available and healthy right now".
/// Sprint 0 ships only a no-op implementation — this is the "CloudKit
/// abstraction / sync scaffolding" deliverable, not a working sync.
///
/// GAP, DOCUMENTED RATHER THAN INVENTED: a real `CloudKitSyncProvider`
/// needs (a) approved domain entities to build record types for, and (b)
/// a resolved zone-sharing model (single shared zone vs. split
/// Performance/Sensitive zones — flagged as a Critical item in the
/// Architecture Review and still unresolved by any of the six governing
/// documents). Building a real CloudKit provider now would mean inventing
/// both of those, which the Engineering Guide's "never invent business
/// rules" rule and this Sprint 0's own "excluded: business logic" scope
/// both rule out. This protocol is the seam that implementation will
/// plug into once those two decisions are made.
public protocol SyncProviding: Sendable {
    var isAvailable: Bool { get async }
    func requestSync() async throws
}

public struct NoopSyncProvider: SyncProviding {
    public init() {}

    public var isAvailable: Bool {
        get async { false }
    }

    public func requestSync() async throws {
        // Intentionally does nothing. Sprint 0 scaffolding only.
    }
}
