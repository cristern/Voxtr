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
@Suite("Sprint 1.1 closeout", .serialized)
struct Sprint1CloseoutTests {

    /// Item 1: reflection destination/title context resolves the
    /// correct athlete — the ViewModel carries its own
    /// athleteDisplayName, not a global/shared value.
    @Test("WeeklyReflectionFormViewModel carries the correct athlete display name")
    @MainActor
    func reflectionFormViewModelCarriesCorrectAthleteName() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let service = WeeklyReflectionService(repository: repository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()

        let viewModel = WeeklyReflectionFormViewModel(
            service: service, athleteId: athleteId, athleteDisplayName: "Emma",
            weekStart: weekStart, authorId: ActorId()
        )

        #expect(viewModel.athleteDisplayName == "Emma")
        #expect(viewModel.isEditing == false)
    }

    /// Item 2 / test 2: Family Schedule recurring row preserves
    /// AthleteId, recurring source identity, and occurrence date.
    @Test("Family Schedule recurring suggestion row preserves athlete identity, recurring source identity, and occurrence date")
    @MainActor
    func recurringSuggestionRowPreservesIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        guard let inFiveDays = Calendar.current.date(byAdding: .day, value: 5, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: inFiveDays)
        let occurrenceDate = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)

        let recurring = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Swim Practice", activityType: .individualTraining,
            weekdays: [occurrenceDate.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        let scheduleViewModel = FamilyScheduleViewModel(
            activeAthletes: [oliver],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        scheduleViewModel.loadSchedule()

        let group = try #require(scheduleViewModel.dayGroups.first { $0.date == occurrenceDate })
        let row = try #require(group.rows.first)
        guard case .recurringSuggestion(_, let athleteId, let athleteName, let suggestion) = row else {
            Issue.record("Expected a .recurringSuggestion row")
            return
        }
        #expect(athleteId == oliver.athleteId)
        #expect(athleteName == "Oliver")
        #expect(suggestion.recurringPlannedActivityId == recurring.recurringPlannedActivityId)
        #expect(suggestion.occurrenceDate == occurrenceDate)
    }

    /// Item 2, "for A": a real, materialized PlannedActivity row still
    /// resolves the canonical PlannedActivity identity — confirms the
    /// new merge in FamilyScheduleViewModel didn't disturb the existing
    /// .planned row path.
    @Test("A materialized schedule row resolves the canonical PlannedActivity identity")
    @MainActor
    func materializedRowResolvesCanonicalIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        guard let inFiveDays = Calendar.current.date(byAdding: .day, value: 5, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: inFiveDays)
        let occurrenceDate = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: inFiveDays)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStart)
        let created = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: oliver.athleteId, activityType: .teamTraining,
            title: "Football", localDate: occurrenceDate, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let scheduleViewModel = FamilyScheduleViewModel(
            activeAthletes: [oliver],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        scheduleViewModel.loadSchedule()

        let group = try #require(scheduleViewModel.dayGroups.first { $0.date == occurrenceDate })
        let row = try #require(group.rows.first)
        guard case .planned(let familyRow) = row else {
            Issue.record("Expected a .planned row")
            return
        }
        #expect(familyRow.plannedActivity.plannedActivityId == created.plannedActivityId)
    }

    /// Item 3: weekday formatting is deterministic — the underlying,
    /// testable logic (`WeeklyPlanningView.weekdayLabel(for:)`, reused
    /// by Family Schedule's own day heading) always returns the same
    /// label for the same `Weekday`.
    @Test("Weekday label formatting is deterministic")
    func weekdayLabelIsDeterministic() {
        #expect(WeeklyPlanningView.weekdayLabel(for: .monday) == WeeklyPlanningView.weekdayLabel(for: .monday))
        #expect(WeeklyPlanningView.weekdayLabel(for: .monday) != WeeklyPlanningView.weekdayLabel(for: .friday))
    }

    /// Item 5: Daily Training's duration state uses the shared
    /// component's domain representation, starting at a sensible
    /// default rather than the old validation-floor value.
    @Test("Daily Training's duration state starts at a sensible default, not the old validation-floor value")
    @MainActor
    func dailyTrainingDurationStartsAtSensibleDefault() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: TrainingService(repository: trainingRepository),
            coordinationService: coordinationService,
            athleteId: AthleteId()
        )

        #expect(viewModel.newLogDurationMinutes == 60)
    }
}
