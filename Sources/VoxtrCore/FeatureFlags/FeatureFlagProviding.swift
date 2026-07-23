import Foundation

/// Abstraction over "is this capability turned on right now". Sprint 0
/// ships a local (UserDefaults-backed) implementation only. A future
/// remote-config-backed implementation can conform to this same protocol
/// without any domain module code changing — that's the entire point of
/// depending on the protocol rather than a concrete provider.
public protocol FeatureFlagProviding: Sendable {
    func isEnabled(_ flag: FeatureFlag) -> Bool
}

/// Sprint 0 defines no product feature flags (no product features exist
/// yet). This case exists only to prove the mechanism, per the Sprint 0
/// spec's "feature flags" deliverable — real flags get added by whichever
/// sprint introduces the feature they gate.
public enum FeatureFlag: String, CaseIterable, Sendable {
    case sprint0DiagnosticsEnabled
}

/// ENGINEERING TRADE-OFF: UserDefaults was chosen for Sprint 0 because it
/// requires no additional infrastructure and is trivially testable. If a
/// remote-config service is adopted later (e.g. for staged rollouts), add
/// a second `FeatureFlagProviding` conformance — do not modify this one.
public final class LocalFeatureFlagProvider: FeatureFlagProviding {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        defaults.bool(forKey: "featureFlag.\(flag.rawValue)")
    }

    public func setEnabled(_ enabled: Bool, for flag: FeatureFlag) {
        defaults.set(enabled, forKey: "featureFlag.\(flag.rawValue)")
    }
}
