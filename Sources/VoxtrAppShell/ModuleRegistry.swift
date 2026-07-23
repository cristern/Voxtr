import Foundation
import VoxtrCore
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrDevelopmentDomain
import VoxtrDecisionSupportDomain
import VoxtrNotificationsDomain
import VoxtrSettings

/// The single place in the entire codebase allowed to import every
/// domain module. This is intentional and load-bearing: if a second file
/// anywhere else ever needs to import two domain modules at once, that's
/// a sign business logic is leaking outside its module, or that two
/// modules need a Core-level interface between them instead.
public enum ModuleRegistry {

    public static func allModules() -> [any VoxtrModule] {
        [
            AthleteModule(),
            ParentModule(),
            PlanningModule(),
            TrainingModule(),
            ReflectionModule(),
            DevelopmentModule(),
            DecisionSupportModule(),
            NotificationsModule(),
            SettingsModule(),
        ]
    }

    /// Sprint 0 acceptance check: every domain module must have a unique
    /// `domainID`. Exercised directly by `VoxtrSprint0Tests`.
    public static func hasUniqueDomainIDs() -> Bool {
        let ids = allModules().map { type(of: $0).domainID }
        return Set(ids).count == ids.count
    }
}
