import Foundation
import SwiftData
import VoxtrCoreContracts

/// v1.3 Section 5.1 / DDM-001. Cross-domain sport taxonomy. Feature
/// modules store `SportId` only (Section 5.1: "Feature modules store
/// SportId only") — never this type.
@Model
public final class Sport {
    @Attribute(.unique) public var id: UUID
    public var canonicalKey: String
    public var displayNameKey: String
    public var isActive: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: SportId = SportId(),
        canonicalKey: String,
        displayNameKey: String,
        isActive: Bool = true,
        sortOrder: Int,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id.rawValue
        self.canonicalKey = canonicalKey
        self.displayNameKey = displayNameKey
        self.isActive = isActive
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var sportId: SportId { SportId(rawValue: id) }
}
