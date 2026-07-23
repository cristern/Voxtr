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
    // `UserDefaults` is not marked `Sendable` by Apple, but it IS
    // documented as safe to access concurrently from multiple threads
    // (Apple's UserDefaults docs: "the class is thread-safe"). Swift 6's
    // strict concurrency checker can't know that from the type system
    // alone, so `nonisolated(unsafe)` tells the compiler we're making
    // that safety claim deliberately and with a stated reason — this is
    // the targeted fix for exactly this situation, rather than making
    // the whole class `@unchecked Sendable` (which would silence
    // checking on every property, not just this one).
    nonisolated(unsafe) private let defaults: UserDefaults

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
