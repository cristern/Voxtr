import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("WeeklyReflectionRepository and WeeklyReflectionService (Sprint 5.0)", .serialized)
struct WeeklyReflectionServiceTests {

    @Test("A valid weekly reflection can be recorded")
    @MainActor
    func validWeeklyReflectionCanBeRecorded() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let service = WeeklyReflectionService(repository: repository)
        let athleteId = AthleteId()

        let reflection = try service.recordWeeklyReflection(
            athleteId: athleteId,
            weekStart: LocalDate(year: 2026, month: 1, day: 5),
            authorId: ActorId(),
            overallSatisfaction: 4,
            whatWorked: "Consistent mornings",
            visibility: .privateToAthlete
        )

        #expect(reflection.overallSatisfaction == 4)
        #expect(try container.mainContext.fetch(FetchDescriptor<WeeklyReflection>()).count == 1)
    }

    @Test("A recorded reflection can be retrieved by athlete and week")
    @MainActor
    func recordedReflectionCanBeRetrievedByAthleteAndWeek() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let service = WeeklyReflectionService(repository: repository)
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 1, day: 5)
        _ = try service.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(), visibility: .privateToAthlete
        )

        let found = try service.fetchWeeklyReflection(forAthlete: athleteId, weekStart: weekStart)
        let notFound = try service.fetchWeeklyReflection(
            forAthlete: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 12)
        )

        #expect(found != nil)
        #expect(notFound == nil)
    }

    @Test("Recording a second reflection for the same athlete and week is rejected without corrupting existing data")
    @MainActor
    func duplicateRecordingRejectedWithoutCorruption() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let service = WeeklyReflectionService(repository: repository)
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 1, day: 5)
        let original = try service.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(),
            overallSatisfaction: 4, visibility: .privateToAthlete
        )

        #expect(throws: WeeklyReflectionServiceError.weeklyReflectionAlreadyExists) {
            try service.recordWeeklyReflection(
                athleteId: athleteId, weekStart: weekStart, authorId: ActorId(),
                overallSatisfaction: 2, visibility: .privateToAthlete
            )
        }

        let stillThere = try service.fetchWeeklyReflection(forAthlete: athleteId, weekStart: weekStart)
        #expect(try container.mainContext.fetch(FetchDescriptor<WeeklyReflection>()).count == 1)
        #expect(stillThere?.id == original.id)
        #expect(stillThere?.overallSatisfaction == 4)
    }

    @Test("Reflections belonging to another athlete are never returned")
    @MainActor
    func reflectionsScopedToOwningAthleteOnly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let service = WeeklyReflectionService(repository: repository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 1, day: 5)
        _ = try service.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(), visibility: .privateToAthlete
        )
        _ = try service.recordWeeklyReflection(
            athleteId: otherAthleteId, weekStart: weekStart, authorId: ActorId(), visibility: .privateToAthlete
        )

        let ownFetch = try service.fetchWeeklyReflection(forAthlete: athleteId, weekStart: weekStart)
        let history = try service.fetchWeeklyReflections(forAthlete: athleteId)

        #expect(ownFetch?.athleteId == athleteId.rawValue)
        #expect(history.count == 1)
        #expect(history.allSatisfy { $0.athleteId == athleteId.rawValue })
    }

    @Test("Multiple weeks are returned in deterministic chronological order")
    @MainActor
    func multipleWeeksReturnedInDeterministicOrder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let service = WeeklyReflectionService(repository: repository)
        let athleteId = AthleteId()

        // Inserted out of chronological order deliberately.
        _ = try service.recordWeeklyReflection(
            athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 19),
            authorId: ActorId(), whatWorked: "Third week", visibility: .privateToAthlete
        )
        _ = try service.recordWeeklyReflection(
            athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5),
            authorId: ActorId(), whatWorked: "First week", visibility: .privateToAthlete
        )
        _ = try service.recordWeeklyReflection(
            athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 12),
            authorId: ActorId(), whatWorked: "Second week", visibility: .privateToAthlete
        )

        let first = try service.fetchWeeklyReflections(forAthlete: athleteId)
        let second = try service.fetchWeeklyReflections(forAthlete: athleteId)

        #expect(first.map(\.whatWorked) == ["First week", "Second week", "Third week"])
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("A recorded reflection survives the ModelContainer being discarded and recreated")
    @MainActor
    func reflectionSurvivesContainerRecreation() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("sprint5-weekly-reflection-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: AppCurrentSchema.self)
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 1, day: 5)

        let firstConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let firstContainer = try ModelContainer(
            for: schema, migrationPlan: AppSchemaMigrationPlan.self, configurations: [firstConfiguration]
        )
        let firstRepository = WeeklyReflectionRepository(modelContext: firstContainer.mainContext)
        let firstService = WeeklyReflectionService(repository: firstRepository)
        let recorded = try firstService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(),
            overallSatisfaction: 5, visibility: .privateToAthlete
        )

        let secondConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let secondContainer = try ModelContainer(
            for: schema, migrationPlan: AppSchemaMigrationPlan.self, configurations: [secondConfiguration]
        )
        let secondRepository = WeeklyReflectionRepository(modelContext: secondContainer.mainContext)

        let restored = try secondRepository.fetchWeeklyReflection(forAthlete: athleteId, weekStart: weekStart)

        #expect(restored?.id == recorded.id)
        #expect(restored?.overallSatisfaction == 5)
        #expect(restored?.weekStart == weekStart)
    }

    @Test("Out-of-range numeric fields are rejected through a controlled error, not a precondition crash")
    @MainActor
    func outOfRangeNumericFieldsRejectedViaError() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let service = WeeklyReflectionService(repository: repository)

        #expect(throws: WeeklyReflectionServiceError.self) {
            try service.recordWeeklyReflection(
                athleteId: AthleteId(), weekStart: LocalDate(year: 2026, month: 1, day: 5),
                authorId: ActorId(), overallSatisfaction: 99, visibility: .privateToAthlete
            )
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<WeeklyReflection>()).count == 0)
    }

    @Test("An overlong free-text field is rejected through a controlled error, not a precondition crash")
    @MainActor
    func overlongFreeTextRejectedViaError() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let service = WeeklyReflectionService(repository: repository)
        let tooLong = String(repeating: "a", count: 1001)

        #expect(throws: WeeklyReflectionServiceError.self) {
            try service.recordWeeklyReflection(
                athleteId: AthleteId(), weekStart: LocalDate(year: 2026, month: 1, day: 5),
                authorId: ActorId(), learning: tooLong, visibility: .privateToAthlete
            )
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<WeeklyReflection>()).count == 0)
    }

    // MARK: - Issue 2 (Parent Time Navigation package): Reflection backfill / switchToWeek coverage

    /// A `CoachingPresentationProviding` that always succeeds with an
    /// empty presentation — `WeeklyReviewViewModel`'s coaching pipeline
    /// is not what these tests exercise, so it's kept minimal, not
    /// re-derived per test.
    private struct EmptyCoachingPresentationProvider: CoachingPresentationProviding {
        func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
            CoachingPresentation(athleteId: athleteId, weekStart: weekStart, sections: [])
        }
    }

    @Test("A missing previous-week reflection can be created for that selected historical week, and retains that week's identity")
    @MainActor
    func backfillCreatesReflectionForSelectedHistoricalWeek() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let reflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let athleteId = AthleteId()
        let currentWeekStart = LocalDate(year: 2026, month: 1, day: 12)
        let previousWeekStart = currentWeekStart.adding(days: -7)

        let viewModel = WeeklyReviewViewModel(
            coordinationService: coordinator,
            coachingPresentationProvider: EmptyCoachingPresentationProvider(),
            athleteId: athleteId,
            weekStart: currentWeekStart
        )
        viewModel.load()

        // Criterion 1: previous week can be selected.
        viewModel.switchToWeek(previousWeekStart, calendar: Calendar(identifier: .gregorian))
        #expect(viewModel.weekStart == previousWeekStart)

        // Criterion 2/3: the missing previous-week reflection is
        // created for THAT selected week, and retains its identity.
        _ = try reflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: viewModel.weekStart, authorId: ActorId(),
            nextWeekConsideration: "Focus on recovery", visibility: .sharedWithGuardians
        )
        let persisted = try weeklyReflectionRepository.fetchWeeklyReflection(forAthlete: athleteId, weekStart: previousWeekStart)
        #expect(persisted?.weekStart == previousWeekStart)
        #expect(persisted?.nextWeekConsideration == "Focus on recovery")
    }

    @Test("A future week cannot be selected as the active Reflection week")
    @MainActor
    func futureWeekCannotBeSelected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let athleteId = AthleteId()
        let currentWeekStart = LocalDate(year: 2026, month: 1, day: 12)
        let futureWeekStart = currentWeekStart.adding(days: 7)

        let viewModel = WeeklyReviewViewModel(
            coordinationService: coordinator,
            coachingPresentationProvider: EmptyCoachingPresentationProvider(),
            athleteId: athleteId,
            weekStart: currentWeekStart
        )
        viewModel.load()

        // Injects a fixed reference instant (a date within
        // currentWeekStart's own week) directly into switchToWeek —
        // genuinely deterministic, never dependent on the actual
        // wall-clock date this test happens to run on.
        var referenceComponents = DateComponents()
        referenceComponents.year = currentWeekStart.year; referenceComponents.month = currentWeekStart.month; referenceComponents.day = currentWeekStart.day
        let referenceInstant = Calendar(identifier: .gregorian).date(from: referenceComponents) ?? .now
        viewModel.switchToWeek(futureWeekStart, referenceDate: referenceInstant, calendar: Calendar(identifier: .gregorian))

        // Rejected — weekStart remains the current week, never the
        // future one.
        #expect(viewModel.weekStart == currentWeekStart)
    }

    @Test("Switching Reflection weeks does not leave stale data from the previous week visible under the new week")
    @MainActor
    func switchingWeeksClearsStaleReflectionData() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let reflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let athleteId = AthleteId()
        let currentWeekStart = LocalDate(year: 2026, month: 1, day: 12)
        let previousWeekStart = currentWeekStart.adding(days: -7)
        _ = try reflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: previousWeekStart, authorId: ActorId(),
            overallSatisfaction: 5, visibility: .sharedWithGuardians
        )
        // Current week has NO reflection at all.

        let viewModel = WeeklyReviewViewModel(
            coordinationService: coordinator,
            coachingPresentationProvider: EmptyCoachingPresentationProvider(),
            athleteId: athleteId,
            weekStart: previousWeekStart
        )
        viewModel.load()
        guard case .loaded(let previousResult) = viewModel.loadState else {
            Issue.record("Expected .loaded"); return
        }
        #expect(previousResult.weeklyReflection?.overallSatisfaction == 5)

        viewModel.switchToWeek(currentWeekStart, calendar: Calendar(identifier: .gregorian))

        // The new week's own (nil) reflection must be reflected — never
        // the previous week's satisfaction score carried over stale.
        guard case .loaded(let currentResult) = viewModel.loadState else {
            Issue.record("Expected .loaded after switch"); return
        }
        #expect(currentResult.weeklyReflection == nil)
    }

    @Test("Privacy behavior is unaffected by week switching — a privateToAthlete reflection stays private for any selected week")
    @MainActor
    func privacyIntactAcrossWeekSwitching() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let coordinator = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let reflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let athleteId = AthleteId()
        let currentWeekStart = LocalDate(year: 2026, month: 1, day: 12)
        let previousWeekStart = currentWeekStart.adding(days: -7)
        _ = try reflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: previousWeekStart, authorId: ActorId(),
            nextWeekConsideration: "Private note", visibility: .privateToAthlete
        )

        let viewModel = WeeklyReviewViewModel(
            coordinationService: coordinator,
            coachingPresentationProvider: EmptyCoachingPresentationProvider(),
            athleteId: athleteId,
            weekStart: currentWeekStart
        )
        viewModel.load()
        viewModel.switchToWeek(previousWeekStart, calendar: Calendar(identifier: .gregorian))

        // The underlying WeeklyReviewResult still carries the
        // reflection entity itself (WeeklyReviewCoordinationService
        // assembles canonical data, unfiltered) — visibility
        // enforcement for Home's Focus surface is a separate,
        // existing, unchanged gate (FamilyHomeViewModel), not
        // something this switch touches or bypasses.
        guard case .loaded(let result) = viewModel.loadState else {
            Issue.record("Expected .loaded"); return
        }
        #expect(result.weeklyReflection?.visibility == .privateToAthlete)
    }
}
