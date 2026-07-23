import Foundation
import SwiftData
import VoxtrCoreContracts

/// v1.3 Section 5.2 / DDM-001. Independent of Sport; an activity may use
/// zero or more category IDs. Not nested in v1.
@Model
public final class ActivityCategory {
    @Attribute(.unique) public var id: UUID
    public var canonicalKey: String
    public var displayNameKey: String
    public var isActive: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: ActivityCategoryId = ActivityCategoryId(),
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

    public var categoryId: ActivityCategoryId { ActivityCategoryId(rawValue: id) }
}
