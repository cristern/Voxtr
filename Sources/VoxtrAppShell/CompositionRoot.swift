import Foundation
import SwiftData
import VoxtrCore
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrCoreReferenceData
import VoxtrNotificationsDomain
import VoxtrCalendarPlanningDomain

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
    /// The whole multi-version history it pointed into was then
    /// collapsed to `AppCurrentSchema` — one live version, no
    /// historical "legacy type" scaffolding. VX-023 (Sleep V1) review
    /// follow-up: `AppCurrentSchema` is now FROZEN (15 entities, "1.0.0")
    /// and this default targeted `AppSchemaV2` ("2.0.0", 17 entities —
    /// adds `DailyStatus`/`AthleteSettings`) — see
    /// `AppSchemaVersioning.swift`'s own doc comment for the full
    /// investigation and why a live-passthrough `AppCurrentSchema` was
    /// not actually safe for a model-type addition. Design Foundation
    /// V0.1 (Athlete Color canonical preference round): `AppSchemaV2` is
    /// now itself FROZEN and this default targeted `AppSchemaV3`
    /// ("3.0.0", same 17 entities — adds
    /// `AthleteSettings.preferredColor: AthleteColor?`). Sport / Activity
    /// Identity domain foundation round: `AppSchemaV3` is now itself
    /// FROZEN and this default targeted `AppSchemaV4` ("4.0.0", 18
    /// entities — activates `Sport.self`). Notifications V1 Activity
    /// Reminder Foundation: `AppSchemaV4` was then FROZEN and this
    /// default targeted `AppSchemaV5` ("5.0.0", 19 entities — activates
    /// `ActivityReminder.self`). Activity Reminder What/When: `AppSchemaV5`
    /// was then FROZEN and this default targeted `AppSchemaV6` ("6.0.0",
    /// same 19 entities — adds `ActivityReminder.reminderText: String?`).
    /// Calendar Planning Source V1: `AppSchemaV6` was then FROZEN and
    /// this default targeted `AppSchemaV7` ("7.0.0", 20 entities —
    /// activates `CalendarPlanningMapping.self`). Family-Owned Calendar
    /// Sources V1: `AppSchemaV7` was then FROZEN and this default
    /// targeted `AppSchemaV8` ("8.0.0", 22 entities — activates
    /// `ExternalPlanningSource.self`/`CalendarImportDecision.self`). PR
    /// #48 follow-up (durable Suggested Ignore evidence): `AppSchemaV8`
    /// is now itself FROZEN and this default targets `AppSchemaV9`
    /// ("9.0.0", same 22 entities — adds
    /// `CalendarImportDecision.ignoredEventTitle: String?`), the current
    /// genuine version.
    /// This parameter must be updated at every future schema version
    /// bump; see that same file's own "HOW TO ADD A NEW VERSION"
    /// instructions — missing this exact step is the documented root
    /// cause of the V1-V6 history above.
    public static func build(
        persistence: PersistenceProviding = SwiftDataPersistenceController(
            versionedSchema: AppSchemaV9.self,
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

        // Sport / Activity Identity domain foundation, Part 1/2:
        // `VoxtrCoreReferenceData` owns Sport truth and is not part of
        // the `VoxtrModule`/`ModuleRegistry` system (that system is
        // scoped to `*Domain` targets only — see `ModuleRegistry.swift`),
        // so `SportRepository` is constructed and registered directly
        // here, same as any other cross-cutting Core dependency. Seeding
        // is idempotent (matched by `canonicalKey`) and safe to call on
        // every launch, so it always runs unconditionally rather than
        // being gated behind a first-run check.
        let sportRepository = SportRepository(modelContext: modelContainer.mainContext)
        try sportRepository.seedCanonicalSportsIfNeeded()
        container.register(SportRepository.self) { sportRepository }

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

        // Recurring reopen stale-Athlete-Home fix (architecture round):
        // the ONE shared invalidation fan-out for this app run, built
        // before trainingReflectionCoordinationService below so it can
        // be handed to it directly. See AthleteActivityChangeBroadcaster's
        // own doc comment for the full contract.
        let activityChangeBroadcaster = AthleteActivityChangeBroadcaster()
        container.register(AthleteActivityChangeBroadcaster.self) { activityChangeBroadcaster }

        // VX-022 (Session Form): the one place TrainingService and
        // ReflectionService are used together to log an activity with
        // its optional Session Form value — same placement rationale as
        // trainingPlanningCoordinationService immediately above.
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: container.resolve(TrainingService.self),
            reflectionService: container.resolve(ReflectionService.self),
            activityChangeBroadcaster: activityChangeBroadcaster,
            modelContext: modelContainer.mainContext
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

        // VX-023 (Sleep V1): a separate, semantically distinct fan-out
        // from activityChangeBroadcaster above — Sleep is not an
        // activity-lifecycle mutation. See AthleteSleepChangeBroadcaster's
        // own doc comment.
        let sleepChangeBroadcaster = AthleteSleepChangeBroadcaster()
        container.register(AthleteSleepChangeBroadcaster.self) { sleepChangeBroadcaster }

        // VX-023: the one place AthleteRepository (Sleep tracking
        // preference) and ReflectionService (canonical DailyStatus) are
        // used together — same placement rationale as
        // trainingReflectionCoordinationService above.
        let sleepCoordinationService = SleepCoordinationService(
            reflectionService: container.resolve(ReflectionService.self),
            athleteRepository: container.resolve(AthleteRepository.self),
            sleepChangeBroadcaster: sleepChangeBroadcaster
        )
        container.register(SleepCoordinationService.self) { sleepCoordinationService }

        // Statistics V1 UI round: same placement rationale as every
        // other cross-domain coordinator above — Statistics composes
        // TrainingService, ReflectionService, PlanningService, and (Weekly
        // Reflection Context round) WeeklyReflectionService (all already
        // resolved) and owns no persisted state of its own, so it is
        // constructed and registered here rather than inside either
        // domain package. See `StatisticsService`'s own doc comment.
        let statisticsService = StatisticsService(
            trainingService: container.resolve(TrainingService.self),
            reflectionService: container.resolve(ReflectionService.self),
            planningService: container.resolve(PlanningService.self),
            weeklyReflectionService: container.resolve(WeeklyReflectionService.self)
        )
        container.register(StatisticsService.self) { statisticsService }

        // Notifications V1 Activity Reminder Foundation: the one place
        // ActivityReminderService (Notifications) and PlanningService are
        // used together — same placement rationale as
        // trainingPlanningCoordinationService above. Subscribes to the
        // Planning/Training business events this V1 lifecycle needs
        // AFTER both domain modules' own `configure` has already
        // registered their services above, and BEFORE `build()` returns,
        // so the subscription is guaranteed active before any UI can
        // trigger a mutation.
        let notificationsPlanningCoordinationService = NotificationsPlanningCoordinationService(
            activityReminderService: container.resolve(ActivityReminderService.self),
            planningService: container.resolve(PlanningService.self)
        )
        container.register(NotificationsPlanningCoordinationService.self) { notificationsPlanningCoordinationService }
        notificationsPlanningCoordinationService.subscribeToEvents(eventBus)

        // Family-Owned Calendar Sources V1: the one place
        // ExternalPlanningSourceRepository/CalendarImportDecisionRepository
        // (Calendar Planning), the legacy CalendarPlanningMappingRepository
        // (read-only, for `migrateLegacySourcesIfNeeded(forWorkspace:)`), PlanningService,
        // TrainingService, and AthleteRepository are used together — same
        // placement rationale as every other cross-domain coordinator
        // above. No EventBus subscription (no Planning/Training event
        // needs a Calendar Planning reaction); reconciliation is invoked
        // explicitly from ParentApp lifecycle/configuration points, never
        // automatically here.
        let calendarPlanningCoordinationService = CalendarPlanningCoordinationService(
            sourceRepository: container.resolve(ExternalPlanningSourceRepository.self),
            importDecisionRepository: container.resolve(CalendarImportDecisionRepository.self),
            legacyMappingRepository: container.resolve(CalendarPlanningMappingRepository.self),
            calendarEventProvider: EventKitCalendarEventProvider(),
            planningService: container.resolve(PlanningService.self),
            trainingService: container.resolve(TrainingService.self),
            athleteRepository: container.resolve(AthleteRepository.self)
        )
        container.register(CalendarPlanningCoordinationService.self) { calendarPlanningCoordinationService }

        let log = VoxtrLog.logger(.appShell)
        log.info("Composition root built with \(ModuleRegistry.allModules().count) modules, schema of \(AppSchema.modelTypes.count) model types.")

        eventBus.publish(AppDidFinishLaunchingEvent())

        return CompositionRoot(
            container: container,
            eventBus: eventBus,
            modelContainer: modelContainer,
            restorationState: restorationState
        )
    }
}
