import Foundation
import VoxtrCore

/// Reflection domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns ActivityReflection,
/// DailyStatus, WeeklyReflection, MonthlyReflection, and ParentObservation
/// (Section 10), each with mandatory explicit VisibilityPolicy. Weekly
/// and monthly reflection *workflows* remain Sprint 1+ business logic —
/// only the entities are implemented here.
public struct ReflectionModule: VoxtrModule {
    public static let domainID = "reflection"

    public init() {}
}
