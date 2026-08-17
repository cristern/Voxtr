import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
@Suite("Sprint 1 Core Flow Completion", .serialized)
struct Sprint1CoreFlowCompletionTests {

    /// Item 7: with three athletes, resolving by explicit AthleteId
    /// never silently returns athlete #1 — the actual regression this
    /// whole package is guarding against.
    @Test("With three athletes, navigation identity resolves the correct athlete — never silently falls back to athlete #1")
    @MainActor
    func threeAthletesNeverResolveToFirst() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let workspaceId = WorkspaceId()

        let oliver = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let athleteTwo = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "AthleteTwo",
            birthDate: LocalDate(year: 2013, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let athleteThree = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "AthleteThree",
            birthDate: LocalDate(year: 2014, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        let fetched = try athleteRepository.fetchAthletes(forWorkspace: workspaceId)

        // Resolving athlete #2 and #3 by their own explicit AthleteId
        // (the same pattern FamilyHomeDestination.athlete(_:) resolution
        // uses) must return exactly that athlete, never athlete #1.
        let resolvedTwo = fetched.first(where: { $0.athleteId == athleteTwo.athleteId })
        let resolvedThree = fetched.first(where: { $0.athleteId == athleteThree.athleteId })
        #expect(resolvedTwo?.givenName == "AthleteTwo")
        #expect(resolvedThree?.givenName == "AthleteThree")
        #expect(resolvedTwo?.athleteId != oliver.athleteId)
        #expect(resolvedThree?.athleteId != oliver.athleteId)
    }

    /// Item 7: a planned activity opened via ActivityDetailViewModel
    /// carries its own PlannedActivity/athlete identity — resolving
    /// "the wrong activity" or "the wrong athlete" would be exactly the
    /// failure mode Items 3/6 fix.
    @Test("Planned activity destination identity — ActivityDetailViewModel is built for the exact activity and athlete it represents")
    @MainActor
    func plannedActivityDestinationPreservesIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Football", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Nadderud Stadion"
        )

        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            )
        )

        #expect(viewModel.activity.plannedActivityId == activity.plannedActivityId)
        #expect(viewModel.activity.title == "Football")
        #expect(viewModel.activity.location == "Nadderud Stadion")
    }

    // MARK: - Post-mutation navigation and stale-state consistency audit (Issue A)

    /// Issue A's exact contract: a successful log through
    /// `ActivityDetailViewModel.makeLogActivityViewModel()` must not
    /// only flip `isCompleted` locally — it must also fire the explicit
    /// `onActivityLogged` signal the screen that pushed Activity Detail
    /// relies on to reload its own authoritative data, THEN dismiss
    /// itself exactly once via `onDismiss` — never the other order,
    /// never twice. `callOrder` (not two separate counters) proves both
    /// the count AND the ordering in one assertion: the returning host
    /// must reread canonical state before this screen disappears, and
    /// `isCompleted` — `private(set)`, mutated in exactly one place in
    /// this whole codebase (the same `onLogged` closure both `onActivityLogged`
    /// and `onDismiss` fire from) — has no other transition that could
    /// cause a second, independent dismiss trigger; `ActivityDetailView`
    /// no longer keeps a separate `.onChange(of: isCompleted)` observer
    /// for exactly that reason. Exercised at the ViewModel/contract
    /// level (not via real SwiftUI navigation, which is not something
    /// Swift Testing can drive) — this is the deterministic, testable
    /// half of the fix; the SwiftUI wiring at each of the 5 call sites
    /// is what actually connects `onActivityLogged` to each source
    /// screen's own `load`/`refresh` method, and `onDismiss` to
    /// `ActivityDetailView`'s own `@Environment(\.dismiss)`.
    @Test("A successful log fires onActivityLogged then dismisses exactly once, in that order")
    @MainActor
    func successfulLogFiresOnActivityLoggedThenDismissesExactlyOnce() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        var callOrder: [String] = []
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            onActivityLogged: { callOrder.append("reload") }
        )

        let logViewModel = viewModel.makeLogActivityViewModel(onDismiss: { callOrder.append("dismiss") })
        // Planned/Logged Activity lifecycle consistency cleanup: actual
        // duration is required for a completed log; `activity` itself
        // has no planned duration, so it must be entered explicitly.
        logViewModel.durationMinutes = 45
        logViewModel.sessionForm = 3

        #expect(logViewModel.save())
        #expect(viewModel.isCompleted == true)
        #expect(callOrder == ["reload", "dismiss"])
    }

    /// A failed log (Form required but missing) must neither flip
    /// `isCompleted`, nor fire `onActivityLogged`, nor dismiss — the
    /// same "no false refresh/navigation on failure" contract required
    /// for the successful path above, now covering the dismiss half
    /// too.
    @Test("A failed log fires neither onActivityLogged nor dismiss, and does not flip isCompleted")
    @MainActor
    func failedLogFiresNeitherOnActivityLoggedNorDismiss() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        var callOrder: [String] = []
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            onActivityLogged: { callOrder.append("reload") }
        )

        let logViewModel = viewModel.makeLogActivityViewModel(onDismiss: { callOrder.append("dismiss") })
        // sessionForm left nil — Form is required for a completed log.

        #expect(logViewModel.save() == false)
        #expect(viewModel.isCompleted == false)
        #expect(callOrder.isEmpty)
    }

    // MARK: - Post-mutation consistency closeout: One Truth for Activity Detail completion

    /// The exact defect this closeout fixes: `ActivityDetailViewLoader`
    /// used to trust a caller-provided `isCompleted` snapshot outright,
    /// even after separately fetching the canonical `LoggedActivity`
    /// relationship for RPE/Form. `WeeklyPlanningView` passed a
    /// hardcoded `false` unconditionally — so opening Activity Detail
    /// for an activity ALREADY logged elsewhere would show it as
    /// "Ready to log" again. This test mirrors the loader's corrected
    /// derivation directly (`detail?.loggedActivity != nil`, the exact
    /// rule `TrainingPlanningCoordinationService.plannedActivitiesWithCompletion`
    /// already uses everywhere else — `!links.isEmpty` over the same
    /// `fetchLoggedActivities(forPlannedActivity:)` relationship): a
    /// stale/wrong caller flag of `false` must never suppress genuine
    /// canonical completion.
    @Test("Canonical fetched LoggedActivity determines completion — supersedes a stale caller-provided false (fixes Weekly Planning's hardcoded false)")
    @MainActor
    func canonicalLoggedActivityDeterminesCompletionDespiteStaleCallerFlag() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
            title: activity.title, startedAt: .now, perceivedExertion: 6, authorId: ActorId(), sessionForm: 4
        )

        // Mirrors ActivityDetailViewLoader.onAppear's own derivation
        // exactly — never a hardcoded/stale caller boolean.
        let detail = try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId)
        let derivedIsCompleted = detail?.loggedActivity != nil

        #expect(derivedIsCompleted == true)

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: derivedIsCompleted,
            loggedActivity: detail?.loggedActivity, activityReflection: detail?.reflection,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )

        #expect(viewModel.isCompleted == true)
        // RPE/Form loading is unaffected by this fix — still resolved
        // from the same canonical fetch, alongside completion.
        #expect(viewModel.perceivedExertion == 6)
        #expect(viewModel.formValue == 4)
        // Exact relationship preserved — not inferred from title/date.
        #expect(viewModel.activity.plannedActivityId == activity.plannedActivityId)
        #expect(detail?.loggedActivity.plannedActivityId == activity.plannedActivityId.rawValue)
    }

    /// The mirror case: a caller flag of `true` must never fabricate
    /// completion when no canonical `LoggedActivity` actually exists —
    /// "no title/date inference, no duplicate state authority" applies
    /// in both directions.
    @Test("No canonical LoggedActivity means Activity Detail never falsely claims completion, even if a caller flag said true")
    @MainActor
    func noCanonicalLoggedActivityMeansNotCompletedDespiteStaleCallerFlag() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        // Never logged — no LoggedActivity exists for this PlannedActivity.

        let detail = try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId)
        let derivedIsCompleted = detail?.loggedActivity != nil

        #expect(derivedIsCompleted == false)

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: derivedIsCompleted,
            loggedActivity: detail?.loggedActivity, activityReflection: detail?.reflection,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )

        #expect(viewModel.isCompleted == false)
        #expect(viewModel.perceivedExertion == nil)
        #expect(viewModel.formValue == nil)
    }

    // MARK: - VX-022 closeout: Activity Detail RPE / Form

    /// Builds an `ActivityDetailViewModel` the same way `ActivityDetailViewLoader`
    /// does — resolving `loggedActivity`/`activityReflection` externally
    /// via `TrainingReflectionCoordinationService.loggedActivityDetail(forPlannedActivity:)`
    /// before construction — for tests that need a fully-wired instance.
    @MainActor
    private static func makeCompletedActivityDetailViewModel(
        athleteId: AthleteId,
        planningService: PlanningService,
        weekPlan: WeekPlan,
        coordinator: TrainingReflectionCoordinationService,
        perceivedExertion: Int?,
        sessionForm: Int?,
        sessionFormVisibility: VisibilityPolicy = .sharedWithGuardians
    ) throws -> ActivityDetailViewModel {
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
            title: "Morning run", startedAt: .now, perceivedExertion: perceivedExertion, authorId: ActorId(),
            sessionForm: sessionForm, sessionFormVisibility: sessionFormVisibility
        )
        let detail = try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId)
        return ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: detail?.loggedActivity, activityReflection: detail?.reflection,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )
    }

    @Test("Activity Detail exposes the exact stored RPE for a logged activity")
    @MainActor
    func activityDetailExposesStoredRPE() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: nil
        )

        #expect(viewModel.perceivedExertion == 7)
    }

    @Test("Activity Detail omits RPE when none was recorded")
    @MainActor
    func activityDetailOmitsNilRPE() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: nil
        )

        #expect(viewModel.perceivedExertion == nil)
    }

    @Test("Activity Detail exposes ActivityReflection.bodyFeeling as Form, linked to the exact LoggedActivity")
    @MainActor
    func activityDetailExposesFormFromExactLoggedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 4
        )

        #expect(viewModel.formValue == 4)
    }

    @Test("Activity Detail never shows another logged activity's Form value")
    @MainActor
    func activityDetailNeverShowsAnotherActivitysForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModelA = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 2
        )
        let viewModelB = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 5
        )

        #expect(viewModelA.formValue == 2)
        #expect(viewModelB.formValue == 5)
        #expect(viewModelA.activity.plannedActivityId != viewModelB.activity.plannedActivityId)
    }

    @Test("Activity Detail never shows another athlete's Form value")
    @MainActor
    func activityDetailNeverShowsAnotherAthletesForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let otherWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: otherAthleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 3
        )
        _ = try Self.makeCompletedActivityDetailViewModel(
            athleteId: otherAthleteId, planningService: planningService, weekPlan: otherWeekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 5
        )

        #expect(viewModel.formValue == 3)
    }

    @Test("Activity Detail omits Form when no reflection exists for the logged activity")
    @MainActor
    func activityDetailOmitsFormWhenNoReflectionExists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: nil
        )

        #expect(viewModel.formValue == nil)
    }

    @Test("Activity Detail omits Form when a reflection exists but bodyFeeling itself is nil")
    @MainActor
    func activityDetailOmitsFormWhenBodyFeelingNil() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(trainingService: trainingService, reflectionService: reflectionService)
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let logged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: "Morning run", startedAt: .now
        )
        // A genuine, valid ActivityReflection whose meaningful content
        // is text, not bodyFeeling — proves ReflectionService still
        // allows this (the entity is not narrowed to VX-022's use
        // case), and that Activity Detail correctly omits Form for it.
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, learningNote: "Felt strong on the last interval."
        )

        let detail = try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId)
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: detail?.loggedActivity, activityReflection: detail?.reflection,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )

        #expect(detail?.reflection != nil) // the reflection genuinely exists...
        #expect(viewModel.formValue == nil) // ...but Form is correctly omitted.
    }

    @Test("Activity Detail never exposes Form when the reflection's visibility is privateToAthlete — hidden, not treated as missing")
    @MainActor
    func activityDetailHidesPrivateToAthleteForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 4, sessionFormVisibility: .privateToAthlete
        )

        // The reflection genuinely exists with a real bodyFeeling value
        // — privacy hides it from display, it is not silently treated
        // as if the data never existed at the persistence layer.
        #expect(viewModel.formValue == nil)
    }

    @Test("Activity Detail's RPE and Form coexist correctly alongside unchanged Athlete/Activity/Date/Status fields")
    @MainActor
    func activityDetailRPEAndFormCoexistWithExistingFields() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )

        #expect(viewModel.athleteDisplayName == "Oliver")
        #expect(viewModel.activity.title == "Morning run")
        #expect(viewModel.activity.localDate == TrainingPlanningCoordinationService.today())
        #expect(viewModel.isCompleted == true)
        #expect(viewModel.perceivedExertion == 7)
        #expect(viewModel.formValue == 4)
    }

    // MARK: - Planned/Logged Activity lifecycle consistency cleanup: Edit Logged Activity (RPE + Form)

    @Test("prefillLoggedActivityEditForm loads the exact existing canonical RPE and Form values")
    @MainActor
    func prefillLoggedActivityEditFormLoadsExistingValues() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )

        viewModel.prefillLoggedActivityEditForm()

        #expect(viewModel.editLoggedPerceivedExertion == 7)
        #expect(viewModel.editLoggedSessionForm == 4)
    }

    @Test("saveLoggedActivityEdit persists a changed RPE to the canonical LoggedActivity.perceivedExertion")
    @MainActor
    func saveLoggedActivityEditPersistsChangedRPE() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: trainingRepository),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )
        viewModel.prefillLoggedActivityEditForm()
        viewModel.editLoggedPerceivedExertion = 9

        #expect(viewModel.saveLoggedActivityEdit())

        #expect(viewModel.perceivedExertion == 9)
        let stored = try #require(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).first)
        #expect(stored.perceivedExertion == 9)
    }

    @Test("saveLoggedActivityEdit persists a changed Form to the exact linked ActivityReflection.bodyFeeling")
    @MainActor
    func saveLoggedActivityEditPersistsChangedForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )
        viewModel.prefillLoggedActivityEditForm()
        viewModel.editLoggedSessionForm = 2

        #expect(viewModel.saveLoggedActivityEdit())

        #expect(viewModel.formValue == 2)
        let loggedActivityId = try #require(viewModel.loggedActivity?.loggedActivityId)
        let reflection = try #require(try reflectionService.fetchActivityReflection(forLoggedActivity: loggedActivityId))
        #expect(reflection.bodyFeeling == 2)
        // Exactly one reflection for this LoggedActivity — updated in
        // place, never a second one created.
        #expect(try reflectionService.fetchActivityReflections(forLoggedActivity: loggedActivityId).count == 1)
    }

    @Test("Edit Logged Activity never touches another athlete's LoggedActivity — athlete isolation preserved")
    @MainActor
    func editLoggedActivityEnforcesAthleteIsolation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: trainingRepository),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )
        // A view model wired to a DIFFERENT athlete but pointed at the
        // same LoggedActivity/ActivityReflection via their identity —
        // mirrors the coordinator-level isolation guard from underneath
        // the screen the user would actually interact with.
        // `activityReflection` is carried over too (not just
        // `loggedActivity`) so `prefillLoggedActivityEditForm()` sees a
        // valid, already-set Form value — this test isolates the
        // ATHLETE-ISOLATION guard specifically, not the (separately
        // tested) Form-required validation.
        let otherAthleteViewModel = ActivityDetailViewModel(
            activity: viewModel.activity, isCompleted: true, loggedActivity: viewModel.loggedActivity,
            activityReflection: viewModel.activityReflection,
            weekPlanId: weekPlan.weekPlanId, athleteId: AthleteId(), athleteDisplayName: "Someone Else",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )
        otherAthleteViewModel.prefillLoggedActivityEditForm()
        otherAthleteViewModel.editLoggedPerceivedExertion = 1

        #expect(otherAthleteViewModel.saveLoggedActivityEdit() == false)
        #expect(otherAthleteViewModel.errorMessage != nil)

        // Untouched.
        let stored = try #require(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).first)
        #expect(stored.perceivedExertion == 7)
    }

    // MARK: - Review follow-up: Form remains required on correction for Completed

    @Test("saveLoggedActivityEdit rejects clearing Form back to unset on a Completed activity — canonical data is never left in a state initial logging would have forbidden")
    @MainActor
    func saveLoggedActivityEditRejectsClearingFormOnCompleted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )
        viewModel.prefillLoggedActivityEditForm()
        // The user explicitly picks "Not set" — must be rejected, not
        // silently saved as a cleared Form on a Completed activity.
        viewModel.editLoggedSessionForm = nil

        #expect(viewModel.saveLoggedActivityEdit() == false)
        #expect(viewModel.errorMessage != nil)

        // Canonical data untouched — still the original valid Form.
        let loggedActivityId = try #require(viewModel.loggedActivity?.loggedActivityId)
        let reflection = try #require(try reflectionService.fetchActivityReflection(forLoggedActivity: loggedActivityId))
        #expect(reflection.bodyFeeling == 4)
    }

    @Test("A legacy Completed activity with no historical Form value opens with Form unset but Save is blocked until a real value is chosen — never fabricated")
    @MainActor
    func saveLoggedActivityEditRequiresFormForLegacyCompletedActivityWithNoHistoricalValue() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Legacy session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        // Logged directly through TrainingService — bypasses the
        // coordinator entirely, so genuinely no ActivityReflection
        // exists at all (mirrors a legacy record predating Form).
        let logged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: activity.title, startedAt: .now,
            durationMinutes: 40, status: .completed
        )
        let detail = try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId)

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: detail?.loggedActivity,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )

        // Opens safely with no historical value — never fabricated.
        viewModel.prefillLoggedActivityEditForm()
        #expect(viewModel.editLoggedSessionForm == nil)

        // Save without choosing one is blocked.
        #expect(viewModel.saveLoggedActivityEdit() == false)
        #expect(viewModel.errorMessage != nil)
        #expect(try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivityId) == nil)

        // Choosing a real value then succeeds.
        viewModel.editLoggedSessionForm = 3
        #expect(viewModel.saveLoggedActivityEdit())
        let reflection = try #require(try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivityId))
        #expect(reflection.bodyFeeling == 3)
    }

    @Test("saveLoggedActivityEdit does not require Form for a Missed activity")
    @MainActor
    func saveLoggedActivityEditDoesNotRequireFormForMissed() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Missed session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let logged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: activity.title, startedAt: .now,
            durationMinutes: 1, status: .missed
        )

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: logged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )
        viewModel.prefillLoggedActivityEditForm()
        viewModel.editLoggedPerceivedExertion = 5
        // Form left nil — must not block a Missed correction.

        #expect(viewModel.saveLoggedActivityEdit())
        #expect(viewModel.perceivedExertion == 5)
    }

    // MARK: - Review follow-up: actual duration correction

    @Test("canEditLoggedDuration is true for Completed and false for Missed/Cancelled")
    @MainActor
    func canEditLoggedDurationReflectsOutcome() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let completedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Completed session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let missedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Missed session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let completedLogged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: completedActivity.plannedActivityId,
            activityType: .individualTraining, title: completedActivity.title, startedAt: .now,
            durationMinutes: 40, status: .completed
        )
        let missedLogged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: missedActivity.plannedActivityId,
            activityType: .individualTraining, title: missedActivity.title, startedAt: .now,
            durationMinutes: 1, status: .missed
        )

        let completedViewModel = ActivityDetailViewModel(
            activity: completedActivity, isCompleted: true, loggedActivity: completedLogged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )
        let missedViewModel = ActivityDetailViewModel(
            activity: missedActivity, isCompleted: true, loggedActivity: missedLogged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )

        #expect(completedViewModel.canEditLoggedDuration == true)
        #expect(missedViewModel.canEditLoggedDuration == false)
    }

    @Test("saveLoggedActivityEdit persists a changed actual duration to the canonical LoggedActivity.durationMinutes — distinct from planned duration")
    @MainActor
    func saveLoggedActivityEditPersistsChangedDuration() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )
        let logged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: activity.title, startedAt: .now,
            durationMinutes: 35, status: .completed
        )

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: logged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )
        viewModel.prefillLoggedActivityEditForm()
        #expect(viewModel.editLoggedDurationMinutes == 35)
        viewModel.editLoggedDurationMinutes = 42
        viewModel.editLoggedSessionForm = 3

        #expect(viewModel.saveLoggedActivityEdit())

        let stored = try #require(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).first)
        #expect(stored.durationMinutes == 42)
        // The plan's own planned duration is a completely separate
        // value, never overwritten by a logged-duration correction.
        #expect(activity.plannedDurationMinutes == 30)
    }

    @Test("saveLoggedActivityEdit rejects an invalid (out-of-range) duration correction for a Completed activity")
    @MainActor
    func saveLoggedActivityEditRejectsInvalidDuration() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let logged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: activity.title, startedAt: .now,
            durationMinutes: 35, status: .completed
        )

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: logged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )
        viewModel.prefillLoggedActivityEditForm()
        viewModel.editLoggedDurationMinutes = 0
        viewModel.editLoggedSessionForm = 3

        #expect(viewModel.saveLoggedActivityEdit() == false)
        #expect(viewModel.errorMessage != nil)
        let stored = try #require(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).first)
        #expect(stored.durationMinutes == 35)
    }

    // MARK: - Planned/Logged Activity lifecycle consistency cleanup: Cancel

    @Test("canCancel is true before any outcome is resolved and false once the activity has an outcome")
    @MainActor
    func canCancelReflectsWhetherAnOutcomeIsResolved() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator
        )

        #expect(viewModel.canCancel == true)
        #expect(viewModel.cancelActivity())
        #expect(viewModel.canCancel == false)
    }

    @Test("cancelActivity links a LoggedActivity with status .cancelled, updates outcomeStatus, and never deletes the PlannedActivity")
    @MainActor
    func cancelActivityUpdatesOutcomeStatusWithoutDeletingThePlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        var reloadCallCount = 0
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator,
            onActivityLogged: { reloadCallCount += 1 }
        )

        #expect(viewModel.cancelActivity())

        #expect(viewModel.outcomeStatus == .cancelled)
        #expect(viewModel.isCompleted == true)
        #expect(reloadCallCount == 1)
        // Never a delete — the PlannedActivity itself is untouched and
        // still resolvable from the WeekPlan.
        #expect(viewModel.isDeleted == false)
        let stillPlanned = try planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        #expect(stillPlanned.contains { $0.plannedActivityId == activity.plannedActivityId })
    }

    @Test("Cancelling twice surfaces an error on the retry and never creates a duplicate LoggedActivity")
    @MainActor
    func cancellingTwiceSurfacesErrorOnRetry() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: trainingRepository),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator
        )

        #expect(viewModel.cancelActivity())
        #expect(viewModel.cancelActivity() == false)
        #expect(viewModel.errorMessage != nil)
        #expect(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).count == 1)
    }

    // MARK: - Reversibility principle: Reopen Activity (undo Cancel)

    @Test("canReopen is true only once cancelled, false before cancellation and false once logged normally")
    @MainActor
    func canReopenReflectsCancelledOutcomeOnly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator
        )

        #expect(viewModel.canReopen == false)
        #expect(viewModel.cancelActivity())
        #expect(viewModel.canReopen == true)
    }

    @Test("reopenActivity removes the cancelled LoggedActivity link, restores the unresolved state, and never deletes or duplicates the PlannedActivity")
    @MainActor
    func reopenActivityRestoresUnresolvedStateWithoutTouchingThePlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: trainingRepository),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        var reloadCallCount = 0
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator,
            onActivityLogged: { reloadCallCount += 1 }
        )
        #expect(viewModel.cancelActivity())
        #expect(reloadCallCount == 1)

        #expect(viewModel.reopenActivity())

        // The exact SAME PlannedActivity identity — never deleted,
        // never duplicated.
        #expect(viewModel.activity.plannedActivityId == activity.plannedActivityId)
        #expect(viewModel.outcomeStatus == nil)
        #expect(viewModel.isCompleted == false)
        #expect(viewModel.canCancel == true)
        #expect(viewModel.canReopen == false)
        // The reload signal fires again — same contract Log/Cancel
        // already establish, so a mounted host screen picks up the
        // now-unresolved state immediately.
        #expect(reloadCallCount == 2)
        #expect(try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId).isEmpty)
        let stillPlanned = try planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        #expect(stillPlanned.count == 1)
        #expect(stillPlanned.first?.plannedActivityId == activity.plannedActivityId)
    }

    @Test("A reopened activity can be logged again through the normal canonical flow")
    @MainActor
    func reopenedActivityCanBeLoggedAgain() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: trainingRepository),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator
        )
        #expect(viewModel.cancelActivity())
        #expect(viewModel.reopenActivity())

        let logViewModel = viewModel.makeLogActivityViewModel()
        logViewModel.sessionForm = 4
        #expect(logViewModel.save())

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.status == .completed)
    }

    @Test("reopenActivity is a no-op that fails cleanly on an activity that was never cancelled")
    @MainActor
    func reopenActivityFailsCleanlyWhenNotCancelled() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        // Never cancelled or logged — outcomeStatus is nil.
        let unresolvedViewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator
        )
        #expect(unresolvedViewModel.reopenActivity() == false)

        // Completed — never reopenable through this action.
        let completedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let completedLogged = try TrainingService(repository: TrainingRepository(modelContext: container.mainContext)).logActivity(
            athleteId: athleteId, plannedActivityId: completedActivity.plannedActivityId,
            activityType: .individualTraining, title: completedActivity.title, startedAt: .now,
            durationMinutes: 40, status: .completed
        )
        let completedViewModel = ActivityDetailViewModel(
            activity: completedActivity, isCompleted: true, loggedActivity: completedLogged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator
        )
        #expect(completedViewModel.canReopen == false)
        #expect(completedViewModel.reopenActivity() == false)
        #expect(completedViewModel.outcomeStatus == .completed)
    }

    /// Item 7: logging via the canonical flow preserves the
    /// PlannedActivity linkage automatically — the user never has to
    /// manually reconnect a completed activity to its plan.
    @Test("Logging preserves PlannedActivity linkage automatically")
    @MainActor
    func loggingPreservesPlannedActivityLinkage() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        var loggedFlag = false
        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: { loggedFlag = true }
        )
        logViewModel.durationMinutes = 45
        logViewModel.perceivedExertion = 6
        logViewModel.sessionForm = 4 // VX-022: required for a completed log.
        #expect(logViewModel.save())
        #expect(loggedFlag)

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.durationMinutes == 45)
        #expect(links.first?.perceivedExertion == 6)
    }

    /// VX-022 (Form / Session Form): logging a completed planned
    /// activity with a Form value stores it as
    /// `ActivityReflection.bodyFeeling`, linked to the exact
    /// `LoggedActivity` this save created by its stable typed ID —
    /// never inferred from title/date.
    @Test("Logging a completed planned activity with Form stores it as ActivityReflection.bodyFeeling, linked to the exact LoggedActivity, visible to guardians by default")
    @MainActor
    func loggingCompletedPlannedActivityWithFormStoresBodyFeeling() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let authorId = ActorId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: authorId,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        #expect(logViewModel.isCompleted) // default — this is the completed-logging path.
        // Planned/Logged Activity lifecycle consistency cleanup: actual
        // duration is required for a completed log; `activity` itself
        // has no planned duration, so it must be entered explicitly.
        logViewModel.durationMinutes = 45
        logViewModel.sessionForm = 3

        #expect(logViewModel.save())
        #expect(logViewModel.sessionFormPendingRetry == false)

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        let loggedActivity = try #require(links.first)
        let reflection = try reflectionService.fetchActivityReflection(forLoggedActivity: loggedActivity.loggedActivityId)
        #expect(reflection?.bodyFeeling == 3)
        #expect(reflection?.loggedActivityId == loggedActivity.id)
        #expect(reflection?.athleteId == athleteId.rawValue)
        // VX-022 correction: family-first MVP default, not
        // privateToAthlete.
        #expect(reflection?.visibility == .sharedWithGuardians)
    }

    /// VX-022 correction: Form is required for the V1 Log Activity flow
    /// ("Form is required for completed training/match/competition
    /// logging") — a completed log must not be reported as saved
    /// without it, and nothing (not even the LoggedActivity) should be
    /// created when it's missing.
    @Test("Logging a completed planned activity without Form is blocked entirely — nothing is created")
    @MainActor
    func loggingCompletedPlannedActivityWithoutFormIsBlocked() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        // sessionForm left nil — Form is required for a completed log.

        #expect(logViewModel.save() == false)
        #expect(logViewModel.errorMessage != nil)
        #expect(logViewModel.didLog == false)
        #expect(try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId).isEmpty)
    }

    /// VX-022 correction: Form is required for COMPLETED logging
    /// specifically — logging as NOT completed represents a session
    /// that didn't happen, so there is nothing to rate, and Form must
    /// not block that path.
    @Test("Logging a planned activity as NOT completed does not require Form")
    @MainActor
    func loggingNotCompletedPlannedActivityDoesNotRequireForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        logViewModel.isCompleted = false
        // sessionForm left nil — must not block a not-completed log.

        #expect(logViewModel.save())
        #expect(logViewModel.errorMessage == nil)

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.status == .missed)
        #expect(try reflectionService.fetchActivityReflections(forAthlete: athleteId).isEmpty)
    }

    /// Review follow-up (duration placeholder audit): the exact leak
    /// found and fixed — `durationMinutes` is prefilled from the plan's
    /// own `plannedDurationMinutes` at init, so logging as NOT completed
    /// without clearing that field must never persist the leftover
    /// planned value as if it were a real, measured "actual" duration.
    /// The stored value for a Missed log must always be the schema's
    /// documented `1`-minute placeholder — never a fabricated real
    /// number for a session that never happened.
    @Test("Logging as NOT completed always stores the 1-minute placeholder duration, never the leftover prefilled planned duration")
    @MainActor
    func loggingNotCompletedNeverLeaksThePrefilledPlannedDuration() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        // Prefilled from the plan — never touched by the user.
        #expect(logViewModel.durationMinutes == 30)
        logViewModel.isCompleted = false

        #expect(logViewModel.save())

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.status == .missed)
        // The leftover planned value (30) must never leak through as
        // the actual/logged duration.
        #expect(links.first?.durationMinutes == 1)
    }

    /// Review follow-up (final check before merge, item 2): the Outcome
    /// picker lets a parent enter a Form value while "Completed" is
    /// selected, then switch to "Missed" before saving — `sessionForm`
    /// itself is never cleared by that switch (only the View's duration
    /// picker is hidden for Missed). Without gating at `save()`, that
    /// stale value would still reach `TrainingReflectionCoordinationService.logActivity`,
    /// which records whatever non-nil Form value it is given regardless
    /// of `status`. Nothing happened to rate for a Missed session, so it
    /// must never be persisted as this log's `ActivityReflection.bodyFeeling`.
    @Test("A Form value entered while Completed was selected is never persisted when the outcome is switched to Missed before saving")
    @MainActor
    func loggingAsMissedNeverPersistsAFormValueEnteredWhileCompletedWasSelected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        // Entered while "Completed" (the default) was still selected.
        logViewModel.sessionForm = 4
        // Then the parent switches the Outcome picker to "Missed" —
        // `sessionForm` is left exactly as it was; the View never clears it.
        logViewModel.isCompleted = false

        #expect(logViewModel.save())

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        let logged = try #require(links.first)
        #expect(logged.status == .missed)
        #expect(try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivityId) == nil)
        // The local edit state is cleared too, not just what was sent —
        // guards a defensive re-invocation of save() from hitting the
        // retry branch and resurrecting the stale value afterward.
        #expect(logViewModel.sessionForm == nil)

        // Even a defensive second save() call (e.g. a double-tap before
        // the sheet dismisses) must not retroactively attach the stale
        // Form value — sessionForm is nil now, so the retry branch's own
        // `guard let sessionForm else { return true }` exits cleanly.
        #expect(logViewModel.save())
        #expect(try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivityId) == nil)
    }

    // MARK: - Planned/Logged Activity lifecycle consistency cleanup: actual duration required for Completed

    @Test("Logging a completed planned activity with no duration entered is blocked entirely — nothing is created")
    @MainActor
    func loggingCompletedPlannedActivityWithoutDurationIsBlocked() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            // plannedDurationMinutes deliberately omitted.
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        // Activity outcome consistency closeout (item D): the plan has
        // no duration, so the ViewModel's own canonical edit state must
        // genuinely be nil — never fabricated to 60. (The View-layer
        // `OptionalDurationPickerView` is what makes this visible as
        // "Not set" instead of a misleading pre-selected 60; this
        // asserts the state it reads from.)
        #expect(logViewModel.durationMinutes == nil)
        logViewModel.sessionForm = 3
        // durationMinutes left nil — nothing to prefill from, nothing entered.

        #expect(logViewModel.save() == false)
        #expect(logViewModel.errorMessage != nil)
        #expect(logViewModel.didLog == false)
        #expect(try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId).isEmpty)

        // Explicitly choosing a value (the "Set duration" tap, then
        // adjusting) allows the same save to succeed — nil is a valid,
        // recoverable editing state, not a dead end.
        logViewModel.durationMinutes = 45
        #expect(logViewModel.save())
        #expect(logViewModel.didLog == true)
        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.durationMinutes == 45)
    }

    // MARK: - TestFlight regression: OptionalDurationPickerView's nil <-> selected <-> cleared states

    /// `OptionalDurationPickerView.seedForSelecting` is the one piece of
    /// this control's logic with no `@State`/`@Binding` dependency — the
    /// rest is SwiftUI wiring not exercisable outside a host. Proves the
    /// actual contract: seeded from whatever was last cleared, if
    /// anything, so a clear-then-reselect cycle resumes where the user
    /// left off instead of silently resetting to the generic starting
    /// value every time; falls back to the app's own established 60
    /// only when nothing has ever been entered.
    @Test("OptionalDurationPickerView seeds a fresh selection from the last cleared value, falling back to 60 only when nothing was ever entered")
    func optionalDurationPickerSeedsFromLastKnownValueOrFallsBackTo60() {
        #expect(OptionalDurationPickerView.seedForSelecting(lastKnownDurationMinutes: nil) == 60)
        #expect(OptionalDurationPickerView.seedForSelecting(lastKnownDurationMinutes: 90) == 90)
    }

    /// Review follow-up (TestFlight regression): reproduces the full
    /// nil -> selected -> saved flow entirely through `LogActivityViewModel`'s
    /// own public API — the exact state transition the View's "Not set"
    /// tap performs (`durationMinutes = OptionalDurationPickerView.seedForSelecting(...)`,
    /// then further wheel adjustment) — proving a Completed log can
    /// actually save once a duration has genuinely been selected, for a
    /// plan with no planned duration at all.
    @Test("A plan with no planned duration: selecting a duration through the same seed the View uses allows a Completed log to save")
    @MainActor
    func selectingDurationFromNoPlanAllowsCompletedLogToSave() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            // plannedDurationMinutes deliberately omitted.
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        #expect(logViewModel.durationMinutes == nil)

        // The exact assignment OptionalDurationPickerView's "Not set" tap
        // performs — never a fabricated 60 baked into the ViewModel itself.
        logViewModel.durationMinutes = OptionalDurationPickerView.seedForSelecting(lastKnownDurationMinutes: nil)
        logViewModel.sessionForm = 3
        #expect(logViewModel.durationMinutes == 60)

        #expect(logViewModel.save())
        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.status == .completed)
        #expect(links.first?.durationMinutes == 60)
    }

    /// The clearing half of the same regression: a duration that was
    /// selected and then cleared back to nil (the View's "Clear
    /// duration" action) must behave exactly like a duration that was
    /// never entered — Missed can still save (duration optional), and a
    /// Completed save is blocked again until the user genuinely
    /// reselects.
    @Test("Clearing a selected duration back to nil restores the exact nil-duration contract — Missed saves, Completed is blocked again")
    @MainActor
    func clearingSelectedDurationRestoresNilDurationContract() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )

        // Completed half: select then clear, on its own activity —
        // Save must be blocked again exactly as if nothing had ever
        // been entered, never left saveable off the stale cleared value.
        let completedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            // plannedDurationMinutes deliberately omitted.
        )
        let completedViewModel = LogActivityViewModel(
            plannedActivity: completedActivity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: coordinator,
            onLogged: {}
        )
        completedViewModel.sessionForm = 3
        // Select, exactly as the View would.
        completedViewModel.durationMinutes = OptionalDurationPickerView.seedForSelecting(lastKnownDurationMinutes: nil)
        // Then clear, exactly as the View's "Clear duration" would.
        completedViewModel.durationMinutes = nil

        #expect(completedViewModel.save() == false)
        #expect(completedViewModel.errorMessage != nil)
        #expect(completedViewModel.didLog == false)
        #expect(try trainingRepository.fetchLoggedActivities(forPlannedActivity: completedActivity.plannedActivityId).isEmpty)

        // Missed half: never required a duration in the first place —
        // clearing back to nil is a no-op for this outcome.
        let missedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let missedViewModel = LogActivityViewModel(
            plannedActivity: missedActivity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: coordinator,
            onLogged: {}
        )
        missedViewModel.durationMinutes = OptionalDurationPickerView.seedForSelecting(lastKnownDurationMinutes: nil)
        missedViewModel.durationMinutes = nil
        missedViewModel.isCompleted = false

        #expect(missedViewModel.save())
        let missedLinks = try trainingRepository.fetchLoggedActivities(forPlannedActivity: missedActivity.plannedActivityId)
        #expect(missedLinks.first?.status == .missed)
        #expect(missedLinks.first?.durationMinutes == 1)
    }

    @Test("Logging prefills actual duration from the planned duration but the user's changed value is what actually saves — never re-derived from the plan")
    @MainActor
    func loggingPrefillsPlannedDurationButSavesTheChangedActualValue() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        // Prefilled from the plan — the parent hasn't touched it yet.
        #expect(logViewModel.durationMinutes == 30)

        // Reality differed — the parent corrects it before saving.
        logViewModel.durationMinutes = 50
        logViewModel.sessionForm = 3

        #expect(logViewModel.save())

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        // The saved actual duration is the corrected value, not the
        // original planned one — canonical training truth, never
        // silently re-derived from the plan.
        #expect(links.first?.durationMinutes == 50)
        #expect(activity.plannedDurationMinutes == 30)
    }

    /// Item 7: Location — save/reload round-trip, and that it remains
    /// genuinely optional (nil stays nil, never a fabricated default).
    @Test("Location persists and reloads correctly, and remains optional")
    @MainActor
    func locationPersistsAndReloads() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        let withLocation = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Football", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Nadderud Stadion"
        )
        let withoutLocation = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let reloaded = try planningRepository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        let reloadedWithLocation = reloaded.first { $0.plannedActivityId == withLocation.plannedActivityId }
        let reloadedWithoutLocation = reloaded.first { $0.plannedActivityId == withoutLocation.plannedActivityId }
        #expect(reloadedWithLocation?.location == "Nadderud Stadion")
        #expect(reloadedWithoutLocation?.location == nil)

        // Edit can also set/clear location.
        let edited = try planningService.editPlannedActivity(
            withoutLocation.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId,
            activityType: .individualTraining, title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Park"
        )
        #expect(edited.location == "Park")
    }

    /// Item 4: Athlete Home's reflection section resolves the
    /// SPECIFIC, already-known athleteId it was constructed with — not
    /// a fallback to any other athlete. WeeklyReviewViewModel is
    /// constructed with the exact athleteId HomeDashboardView holds.
    @Test("Athlete Home's reflection navigation carries the specific athlete's own AthleteId, not a fallback")
    @MainActor
    func reflectionNavigationPreservesSpecificAthleteId() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let workspaceId = WorkspaceId()
        let oliver = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let athleteTwo = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "AthleteTwo",
            birthDate: LocalDate(year: 2013, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        // HomeDashboardViewModel is constructed once per specific
        // athlete — this is what makes its own reflectionSection
        // correct: the athleteId baked into the ViewModel at
        // construction is the ONLY one it ever uses, for whichever
        // athlete's Home this happens to be.
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let firstViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: coordinationService,
            coachingPresentationProvider: NoopCoachingPresentationProvider(),
            athleteId: oliver.athleteId,
            weekStart: TrainingPlanningCoordinationService.weekStart(),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
        let secondViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: coordinationService,
            coachingPresentationProvider: NoopCoachingPresentationProvider(),
            athleteId: athleteTwo.athleteId,
            weekStart: TrainingPlanningCoordinationService.weekStart(),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )

        #expect(firstViewModel.athleteId == oliver.athleteId)
        #expect(secondViewModel.athleteId == athleteTwo.athleteId)
        #expect(firstViewModel.athleteId != secondViewModel.athleteId)
    }
}

/// A minimal no-op stand-in, since this suite only needs to confirm
/// HomeDashboardViewModel's own athleteId identity, not real coaching
/// data.
private struct NoopCoachingPresentationProvider: CoachingPresentationProviding {
    struct NotImplemented: Error {}
    func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
        throw NotImplemented()
    }
}
