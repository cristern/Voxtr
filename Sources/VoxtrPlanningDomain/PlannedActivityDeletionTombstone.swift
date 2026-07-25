import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// A2 (Architecture Decisions v1): the Planning domain's own persisted
/// tombstone record for a deleted `PlannedActivity`.
///
/// `DeletionTombstone` (in `VoxtrCoreContracts`) is a plain `Codable`
/// value type, not a `@Model` — by its own doc comment, it defines the
/// shared SHAPE once, and "each domain that needs soft-deletion persists
/// its own tombstone records using this shape." This is that persisted
/// record for Planning. Field-for-field identical to `DeletionTombstone`
/// — nothing about the shape is redesigned here, only made persistable.
///
/// Retention: `purgeAfter` is computed by `DeletionTombstone.now(...)`
/// (v1.3 Section 15.1's documented "default 30 days after deletion"
/// rule) BEFORE this record is constructed — this type stores that
/// value, it does not compute its own retention policy.
///
/// Purge execution (actually deleting tombstones once `purgeAfter` has
/// passed) is explicitly out of scope for A2 — this only creates and
/// stores tombstones.
@Model
public final class PlannedActivityDeletionTombstone {
    @Attribute(.unique) public var id: UUID
    public var entityId: UUID
    public var entityType: String
    public var workspaceId: UUID?
    public var deletedBy: UUID
    public var deletedAt: Date
    public var purgeAfter: Date
    public var schemaVersion: Int

    /// Constructed FROM an already-computed `DeletionTombstone` value
    /// (typically via `DeletionTombstone.now(...)`) rather than
    /// recomputing any of its fields — this type is purely the
    /// persisted form of that value, not an independent source of
    /// truth for retention policy.
    public init(from tombstone: DeletionTombstone) {
        self.id = tombstone.id
        self.entityId = tombstone.entityId
        self.entityType = tombstone.entityType
        self.workspaceId = tombstone.workspaceId?.rawValue
        self.deletedBy = tombstone.deletedBy.rawValue
        self.deletedAt = tombstone.deletedAt
        self.purgeAfter = tombstone.purgeAfter
        self.schemaVersion = tombstone.schemaVersion
    }
}
