import Foundation
import SwiftData
import VoxtrCore
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Wires together every Core service and every domain module exactly
/// once. Both `AthleteApp` and `ParentApp` call `CompositionRoot.build()`
/// once at launch (via `CompositionRootLoaderView`) and use the
/// resulting `modelContainer` for the rest of the app's lifetime.
///
/// S1.2 note: this file now imports `VoxtrParentDomain` and
/// `VoxtrAthleteDomain` directly, to resolve their repositories and
/// construct `FamilyOnboardingCoordinator` — see that type's own doc
/// comment for why cross-domain composition is only legitimate inside
/// `VoxtrAppShell`. `ModuleRegistry.swift`'s older comment calling
/// itself "the single place" that does this predates S1.2 and is no
/// longer literally accurate; the real rule is "only inside
/// `VoxtrAppShell`," not "only in one specific file."
@MainActor
public final class CompositionRoot {

    public let container: DIContainer
    public let eventBus: EventBus
    public let modelContainer: ModelContainer
    /// S1.3: what was found in the store at launch — computed once here,
    /// exposed for whatever content view (S1.4+) needs to decide between
    /// onboarding and a restored family screen. See
    /// `FamilyRestorationState`'s doc comment for the three possible
    /// states.
    public let restorationState: FamilyRestorationState

    private init(
        container: DIContainer,
        eventBus: EventBus,
        modelContainer: ModelContainer,
        restorationState: FamilyRestorationState
    ) {
        self.container = container
        self.eventBus = eventBus
        self.modelContainer = modelContainer
        self.restorationState = restorationState
    }

    /// CRITICAL PERSISTENCE RECOVERY: this default previously targeted
    /// `AppSchemaV6` (itself a fix for an earlier bug where it targeted
    /// `AppSchemaV1`, the oldest version in the plan — see git history).
    /// The whole multi-version history it pointed into has since been
    /// collapsed to `AppCurrentSchema` — one live version, no
    /// historical "legacy type" scaffolding — see
    /// `AppSchemaVersioning.swift`'s own doc comment for the full
    /// investigation and why. This parameter must be updated at every
    /// future schema version bump; see that same file's own "HOW TO
    /// ADD A NEW VERSION" instructions.
    public static func build(
        persistence: PersistenceProviding = SwiftDataPersistenceController(
            versionedSchema: AppCurrentSchema.self,
            migrationPlan: AppSchemaMigrationPlan.self
        ),
        sync: SyncProviding = NoopSyncProvider(),
        featureFlags: FeatureFlagProviding = LocalFeatureFlagProvider()
    ) async throws -> CompositionRoot {
        let container = DIContainer()
        let eventBus = EventBus()

        container.register(SyncProviding.self) { sync }
        container.register(FeatureFlagProviding.self) { featureFlags }

        let modelContainer = try persistence.makeModelContainer()

        for module in ModuleRegistry.allModules() {
            await module.configure(container: container, eventBus: eventBus, modelContainer: modelContainer)
        }

        // S1.2: FamilyOnboardingCoordinator depends on repositories the
        // modules above just registered — built and registered after
        // the module configuration loop, not inside it, since it's not
        // owned by any single module.
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: modelContainer.mainContext,
            parentWorkspaceRepository: container.resolve(ParentWorkspaceRepository.self),
            athleteRepository: container.resolve(AthleteRepository.self),
            athleteAccessGrantRepository: container.resolve(AthleteAccessGrantRepository.self)
        )
        container.register(FamilyOnboardingCoordinator.self) { coordinator }

        // Multi-Athlete Family Foundation: same placement rationale as
        // FamilyOnboardingCoordinator immediately above — needs both
        // AthleteRepository and AthleteAccessGrantRepository, so it
        // can't live in either domain package alone.
        let athleteFamilyManagementService = AthleteFamilyManagementService(
            modelContext: modelContainer.mainContext,
            athleteRepository: container.resolve(AthleteRepository.self),
            athleteAccessGrantRepository: container.resolve(AthleteAccessGrantRepository.self)
        )
        container.register(AthleteFamilyManagementService.self) { athleteFamilyManagementService }

        // S1.3: compute what's already on disk, once, at launch.
        // Registered so it can be re-run later too (e.g. after a future
        // CloudKit sync merges in data), not just used here.
        let restorationService = FamilyRestorationService(
            parentWorkspaceRepository: container.resolve(ParentWorkspaceRepository.self),
            athleteRepository: container.resolve(AthleteRepository.self),
            athleteAccessGrantRepository: container.resolve(AthleteAccessGrantRepository.self)
        )
        container.register(FamilyRestorationService.self) { restorationService }
        let restorationState = try restorationService.restoreState()

        // S3.2: the one place both Planning and Training repositories
        // are used together — see TrainingPlanningCoordinationService's
        // own doc comment for why this can't live in either domain
        // package.
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: container.resolve(PlanningRepository.self),
            trainingRepository: container.resolve(TrainingRepository.self)
        )
        container.register(TrainingPlanningCoordinationService.self) { trainingPlanningCoordinationService }

        // VX-022 (Session Form): the one place TrainingService and
        // ReflectionService are used together to log an activity with
        // its optional Session Form value — same placement rationale as
        // trainingPlanningCoordinationService immediately above.
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: container.resolve(TrainingService.self),
            reflectionService: container.resolve(ReflectionService.self)
        )
        container.register(TrainingReflectionCoordinationService.self) { trainingReflectionCoordinationService }

        // Sprint 5.1: reuses the same repositories/coordination service
        // already resolved above — no new resolution paths needed.
        let weeklyReviewCoordinationService = WeeklyReviewCoordinationService(
            planningRepository: container.resolve(PlanningRepository.self),
            trainingRepository: container.resolve(TrainingRepository.self),
            weeklyReflectionRepository: container.resolve(WeeklyReflectionRepository.self),
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        container.register(WeeklyReviewCoordinationService.self) { weeklyReviewCoordinationService }

        // Sprint 6: reuses the coordination service resolved above and
        // the already-registered ReflectionService — no new resolution
        // paths, no direct repository access.
        let weeklyCoachingContextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: container.resolve(ReflectionService.self)
        )
        container.register(WeeklyCoachingContextService.self) { weeklyCoachingContextService }

        // Sprint 11: reuses the already-constructed weeklyCoachingContextService above.
        let coachingApplicationService = CoachingApplicationService(coachingContextService: weeklyCoachingContextService)
        container.register(CoachingApplicationService.self) { coachingApplicationService }

        let log = VoxtrLog.logger(.appShell)
        log.info("Composition root built with \(ModuleRegistry.allModules().count) modules, schema of \(AppSchema.modelTypes.count) model types.")

        await eventBus.publish(AppDidFinishLaunchingEvent())

        return CompositionRoot(
            container: container,
            eventBus: eventBus,
            modelContainer: modelContainer,
            restorationState: restorationState
        )
    }
}
