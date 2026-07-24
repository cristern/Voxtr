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

/// One of a small number of files inside `VoxtrAppShell` allowed to
/// import every domain module — this is where cross-domain composition
/// legitimately lives (see also `CompositionRoot.swift` and
/// `FamilyOnboardingCoordinator.swift` as of S1.2). The rule is "only
/// inside `VoxtrAppShell`," not "only in this one file": if a domain
/// module package itself ever needs to import a sibling domain module,
/// that's the violation to watch for.
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
