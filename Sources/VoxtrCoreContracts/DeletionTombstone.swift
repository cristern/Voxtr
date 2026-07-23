import Foundation

/// v1.3 Section 15.1. Owner domain: "Owning-domain infrastructure" — each
/// domain that needs soft-deletion persists its own tombstone records
/// using this shape; this type defines the shape once so every domain's
/// tombstone has identical fields.
public struct DeletionTombstone: Codable, Sendable {
    public let id: UUID
    public let entityId: UUID
    public let entityType: String
    public let workspaceId: WorkspaceId?
    public let deletedBy: ActorId
    public let deletedAt: Date
    public let purgeAfter: Date
    public let schemaVersion: Int

    public init(
        id: UUID = UUID(),
        entityId: UUID,
        entityType: String,
        workspaceId: WorkspaceId? = nil,
        deletedBy: ActorId,
        deletedAt: Date = .now,
        purgeAfter: Date,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.entityId = entityId
        self.entityType = entityType
        self.workspaceId = workspaceId
        self.deletedBy = deletedBy
        self.deletedAt = deletedAt
        self.purgeAfter = purgeAfter
        self.schemaVersion = schemaVersion
    }

    /// v1.3 Section 15.1: "purgeAfter... Default 30 days after deletion."
    public static func now(entityId: UUID, entityType: String, workspaceId: WorkspaceId? = nil, deletedBy: ActorId, calendar: Calendar = .current) -> DeletionTombstone {
        let deletedAt = Date.now
        let purgeAfter = calendar.date(byAdding: .day, value: 30, to: deletedAt) ?? deletedAt
        return DeletionTombstone(entityId: entityId, entityType: entityType, workspaceId: workspaceId, deletedBy: deletedBy, deletedAt: deletedAt, purgeAfter: purgeAfter)
    }
}
