import Foundation
import VoxtrCore

/// Settings domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns AppPreference,
/// FeatureFlagOverride, and PrivacyPreference (Section 14). Business
/// state must not be stored as an AppPreference (Section 14.1) — this
/// remains a preferences store, not a place for domain data to leak into.
public struct SettingsModule: VoxtrModule {
    public static let domainID = "settings"

    public init() {}
}
