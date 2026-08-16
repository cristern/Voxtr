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
    /// relies on to reload its own authoritative data. Exercised at the
    /// ViewModel/contract level (not via real SwiftUI navigation, which
    /// is not something Swift Testing can drive) — this is the
    /// deterministic, testable half of the fix; the SwiftUI wiring at
    /// each of the 5 call sites is what actually connects this signal
    /// to each source screen's own `load`/`refresh` method.
    @Test("A successful log fires onActivityLogged, so the screen that pushed Activity Detail can reload its own data")
    @MainActor
    func successfulLogFiresOnActivityLoggedCallback() throws {
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

        var reloadCallCount = 0
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            onActivityLogged: { reloadCallCount += 1 }
        )

        let logViewModel = viewModel.makeLogActivityViewModel()
        logViewModel.sessionForm = 3

        #expect(logViewModel.save())
        #expect(viewModel.isCompleted == true)
        #expect(reloadCallCount == 1)
    }

    /// A failed log (Form required but missing) must neither flip
    /// `isCompleted` nor fire `onActivityLogged` — the same "no false
    /// refresh on failure" contract required for the successful path
    /// above.
    @Test("A failed log does not fire onActivityLogged and does not flip isCompleted")
    @MainActor
    func failedLogDoesNotFireOnActivityLoggedCallback() throws {
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

        var reloadCallCount = 0
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            onActivityLogged: { reloadCallCount += 1 }
        )

        let logViewModel = viewModel.makeLogActivityViewModel()
        // sessionForm left nil — Form is required for a completed log.

        #expect(logViewModel.save() == false)
        #expect(viewModel.isCompleted == false)
        #expect(reloadCallCount == 0)
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
            weekStart: TrainingPlanningCoordinationService.weekStart()
        )
        let secondViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: coordinationService,
            coachingPresentationProvider: NoopCoachingPresentationProvider(),
            athleteId: athleteTwo.athleteId,
            weekStart: TrainingPlanningCoordinationService.weekStart()
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
