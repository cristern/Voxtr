import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
@Suite("Sprint 1.2A: Custom duration + Recurring Location", .serialized)
struct Sprint12ATests {

    @Test("A preset duration value persists correctly through a normal PlannedActivity")
    @MainActor
    func presetDurationRemainsCorrect() throws {
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
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 90
        )

        let reloaded = try planningRepository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        #expect(reloaded.first { $0.plannedActivityId == created.plannedActivityId }?.plannedDurationMinutes == 90)
    }

    /// Item 5: create recurring activity with Location → fetch
    /// definition → Location preserved.
    @Test("Recurring activity Location is preserved through create and fetch")
    @MainActor
    func recurringLocationPreservedThroughCreateAndFetch() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()

        let created = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football Training", activityType: .teamTraining,
            weekdays: [.tuesday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Nadderud",
            effectiveStartDate: LocalDate(year: 2026, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2027, month: 1, day: 1)
        )

        let fetched = try planningRepository.fetchRecurringPlannedActivity(byId: created.recurringPlannedActivityId)
        #expect(fetched?.location == "Nadderud")
    }

    /// Item 6: edit recurring Location → definition updated.
    @Test("Editing a recurring activity's Location updates the definition")
    @MainActor
    func editingRecurringLocationUpdatesDefinition() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()

        let created = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football Training", activityType: .teamTraining,
            weekdays: [.tuesday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Nadderud",
            effectiveStartDate: LocalDate(year: 2026, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2027, month: 1, day: 1)
        )

        let edited = try planningService.editRecurringPlannedActivity(
            created.recurringPlannedActivityId, title: "Football Training", activityType: .teamTraining,
            weekdays: [.tuesday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Colosseum Stadium",
            effectiveStartDate: LocalDate(year: 2026, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2027, month: 1, day: 1)
        )

        #expect(edited.location == "Colosseum Stadium")
        let refetched = try planningRepository.fetchRecurringPlannedActivity(byId: created.recurringPlannedActivityId)
        #expect(refetched?.location == "Colosseum Stadium")
    }

    /// Item 7: derive recurring occurrence → correct Location
    /// preserved. Item 10: athlete identity remains correct alongside
    /// Location.
    @Test("Derived recurring occurrence preserves Location and athlete identity")
    @MainActor
    func derivedOccurrencePreservesLocationAndAthleteIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let today = TrainingPlanningCoordinationService.today()

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football Training", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Nadderud",
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let matching = try #require(suggestions.first { $0.occurrenceDate == today })
        #expect(matching.location == "Nadderud")
        #expect(matching.athleteId == athleteId)
    }

    /// Item 8: materialize/accept recurring occurrence → resulting
    /// PlannedActivity has correct Location.
    @Test("Accepting a recurring occurrence transfers Location to the resulting PlannedActivity")
    @MainActor
    func acceptingOccurrenceTransfersLocation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let today = TrainingPlanningCoordinationService.today()

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football Training", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Nadderud",
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let matching = try #require(suggestions.first { $0.occurrenceDate == today })
        let materialized = try planningService.acceptSuggestion(matching, forWeekPlan: weekPlan.weekPlanId)

        #expect(materialized.location == "Nadderud")
        #expect(materialized.athleteId == athleteId.rawValue)
    }

    /// Item 9: Family Schedule unmaterialized recurring occurrence
    /// exposes correct Location — without materializing anything to
    /// obtain it.
    @Test("Family Schedule's unmaterialized recurring row exposes Location without materializing")
    @MainActor
    func familyScheduleRecurringRowExposesLocation() throws {
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

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Swim Practice", activityType: .individualTraining,
            weekdays: [occurrenceDate.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Aquatic Center",
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        let scheduleViewModel = FamilyScheduleViewModel(
            provideActiveAthletes: { [oliver] },
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        scheduleViewModel.loadSchedule()

        let group = try #require(scheduleViewModel.dayGroups.first { $0.date == occurrenceDate })
        let row = try #require(group.rows.first)
        guard case .recurringSuggestion(_, let rowAthleteId, _, let suggestion) = row else {
            Issue.record("Expected a .recurringSuggestion row")
            return
        }
        #expect(suggestion.location == "Aquatic Center")
        #expect(rowAthleteId == oliver.athleteId)

        // No PlannedActivity was created merely by loading the schedule.
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: inFiveDays)
        let weekPlan = try planningRepository.fetchWeekPlan(forAthlete: oliver.athleteId, weekStart: weekStart)
        #expect(weekPlan == nil)
    }
}
