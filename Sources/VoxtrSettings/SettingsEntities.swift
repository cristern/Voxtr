import Foundation
import SwiftData
import VoxtrCoreContracts

// MARK: - AppPreference (v1.3 Section 14.1)

@Model
public final class AppPreference {
    @Attribute(.unique) public var id: UUID
    public var accountId: String
    public var key: String
    public var value: String
    public var scope: String // account or device
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        accountId: AccountId,
        key: String,
        value: String,
        scope: String,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.accountId = accountId.rawValue
        self.key = key
        self.value = value
        self.scope = scope
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - FeatureFlagOverride (v1.3 Section 14.2)

@Model
public final class FeatureFlagOverride {
    @Attribute(.unique) public var id: UUID
    public var flagKey: String
    public var enabled: Bool
    public var environment: String // debug, testflight, production
    public var expiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        flagKey: String,
        enabled: Bool,
        environment: String,
        expiresAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.flagKey = flagKey
        self.enabled = enabled
        self.environment = environment
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    /// v1.3 Section 14.2: "Expired override is ignored."
    public func isActive(at date: Date = .now) -> Bool {
        guard let expiresAt else { return true }
        return date < expiresAt
    }
}

// MARK: - PrivacyPreference (v1.3 Section 14.3)

@Model
public final class PrivacyPreference {
    @Attribute(.unique) public var id: UUID
    public var accountId: String
    public var athleteId: UUID?
    public var analyticsOptIn: Bool
    public var diagnosticsOptIn: Bool
    public var defaultReflectionVisibility: VisibilityPolicy?
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        accountId: AccountId,
        athleteId: AthleteId? = nil,
        analyticsOptIn: Bool,
        diagnosticsOptIn: Bool,
        defaultReflectionVisibility: VisibilityPolicy? = nil,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.accountId = accountId.rawValue
        self.athleteId = athleteId?.rawValue
        self.analyticsOptIn = analyticsOptIn
        self.diagnosticsOptIn = diagnosticsOptIn
        self.defaultReflectionVisibility = defaultReflectionVisibility
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}
