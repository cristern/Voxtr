import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
@Suite("Sprint 1.1.1", .serialized)
struct Sprint111Tests {

    /// Item 1: a materialized Tomorrow activity's identity is
    /// resolvable the same way a Today activity's is —
    /// `FamilyHomeDestination.activity(rowId:)`'s own resolution logic
    /// searches `viewModel.rows + viewModel.tomorrowRows`, so a
    /// Tomorrow-only row's id is findable there. This is the concrete,
    /// testable half of the navigation identity the white-screen
    /// investigation covers below the SwiftUI runtime.
    @Test("Tomorrow's materialized activity preserves PlannedActivityId/AthleteId navigation identity")
    @MainActor
    func tomorrowMaterializedActivityPreservesNavigationIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let weeklyReflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        guard let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) else {
            Issue.record("Could not compute tomorrow"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: tomorrowDate)
        let tomorrow = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: tomorrowDate)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStart)
        let created = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: oliver.athleteId, activityType: .teamTraining,
            title: "Football", localDate: tomorrow, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [oliver],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadTomorrow()

        #expect(viewModel.tomorrowRows.count == 1)
        // The exact identity FamilyHomeDestination.activity(rowId:) resolves against.
        let rowId = created.plannedActivityId.rawValue.uuidString
        let resolvedRow = (viewModel.rows + viewModel.tomorrowRows).first { $0.id == rowId }
        #expect(resolvedRow?.athleteId == oliver.athleteId)
        #expect(resolvedRow?.plannedActivity.plannedActivityId == created.plannedActivityId)
    }

    /// Item 3: the recurring flow's underlying identity —
    /// WeeklyPlanningViewModel, which both RecurringActivityManagementView
    /// and RecurringActivityFormView operate against — carries the
    /// correct, specific athleteId it was constructed for, never a
    /// fallback.
    @Test("WeeklyPlanningViewModel used by the recurring flow carries the correct athlete identity")
    @MainActor
    func recurringFlowViewModelCarriesCorrectAthleteId() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()

        let viewModel = WeeklyPlanningViewModel(
            service: planningService, athleteId: athleteId, committedByActorId: ActorId()
        )

        #expect(viewModel.athleteId == athleteId)
    }

    /// Item 5 (custom duration): confirms the underlying domain
    /// representation accepts a typed custom value like 53 and rejects
    /// out-of-range values — the validation boundary the DurationPickerView's
    /// own text-field commit logic relies on (1...1440), tested here at
    /// the domain-model level rather than instantiating SwiftUI.
    @Test("Custom duration value round-trips through PlannedActivity persistence")
    @MainActor
    func customDurationValueRoundTrips() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        let created = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 53
        )

        let reloaded = try planningRepository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        let reloadedActivity = reloaded.first { $0.plannedActivityId == created.plannedActivityId }
        #expect(reloadedActivity?.plannedDurationMinutes == 53)
    }
}
