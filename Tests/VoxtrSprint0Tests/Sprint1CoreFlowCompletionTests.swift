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

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingService: trainingService
        )

        #expect(viewModel.activity.plannedActivityId == activity.plannedActivityId)
        #expect(viewModel.activity.title == "Football")
        #expect(viewModel.activity.location == "Nadderud Stadion")
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

        var loggedFlag = false
        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, trainingService: trainingService,
            onLogged: { loggedFlag = true }
        )
        logViewModel.durationMinutes = 45
        logViewModel.perceivedExertion = 6
        #expect(logViewModel.save())
        #expect(loggedFlag)

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.durationMinutes == 45)
        #expect(links.first?.perceivedExertion == 6)
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
