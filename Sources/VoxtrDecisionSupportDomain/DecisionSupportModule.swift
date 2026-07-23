import Foundation
import VoxtrCore

/// DecisionSupport domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns Recommendation,
/// RecommendationEvidence, and RecommendationResponse (Section 12).
/// Recommendations are never source of truth (Section 12.1) and require
/// at least one evidence record before presentation.
public struct DecisionSupportModule: VoxtrModule {
    public static let domainID = "decisionSupport"

    public init() {}
}
