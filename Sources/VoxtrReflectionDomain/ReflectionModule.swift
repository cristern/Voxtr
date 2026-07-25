import Foundation
import SwiftData
import VoxtrCore

/// Reflection domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns ActivityReflection,
/// DailyStatus, WeeklyReflection, MonthlyReflection, and ParentObservation
/// (Section 10), each with mandatory explicit VisibilityPolicy. Weekly
/// and monthly reflection *workflows* remain Sprint 1+ business logic —
/// only the entities are implemented here.
///
/// S4.0: registers `ReflectionRepository` and `ReflectionService`
/// (ActivityReflection/ParentObservation only — DailyStatus/
/// WeeklyReflection/MonthlyReflection are out of scope). Sprint 5.0:
/// also registers `WeeklyReflectionRepository`/`WeeklyReflectionService`
/// (WeeklyReflection only — DailyStatus/MonthlyReflection remain out of
/// scope).
public struct ReflectionModule: VoxtrModule {
    public static let domainID = "reflection"

    public init() {}

    @MainActor
    public func configure(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) async {
        let repository = ReflectionRepository(modelContext: modelContainer.mainContext)
        container.register(ReflectionRepository.self) { repository }

        let service = ReflectionService(repository: repository)
        container.register(ReflectionService.self) { service }

        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: modelContainer.mainContext)
        container.register(WeeklyReflectionRepository.self) { weeklyReflectionRepository }

        let weeklyReflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)
        container.register(WeeklyReflectionService.self) { weeklyReflectionService }
    }
}
