import Foundation
import VoxtrCore

/// Development domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns DevelopmentGoal,
/// DevelopmentFocus, DevelopmentInsight (Section 11), and a derived,
/// non-persisted WeeklySummaryProjection value type (Section 11.4).
public struct DevelopmentModule: VoxtrModule {
    public static let domainID = "development"

    public init() {}
}
