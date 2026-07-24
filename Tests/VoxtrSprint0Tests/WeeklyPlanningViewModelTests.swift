import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrPlanningDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/service construction — every test builds its own inline.

@Suite("WeeklyPlanningViewModel (S2.4)", .serialized)
struct WeeklyPlanningViewModelTests {

    private static let fixedWeekStart = LocalDate(year: 2026, month: 1, day: 5)

    @Test("Loading with no existing plan creates a draft with no activities")
    @MainActor
    func loadCreatesDraftWhenNoneExists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service,
            athleteId: AthleteId(),
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )

        viewModel.loadOrCreateWeekPlan()

        #expect(viewModel.weekPlan != nil)
        #expect(viewModel.isCommitted == false)
        #expect(viewModel.activities.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Adding an activity persists it and clears the form")
    @MainActor
    func addActivityPersistsAndClearsForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service,
            athleteId: AthleteId(),
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.newActivityTitle = "  Endurance run  "

        viewModel.addActivity()

        #expect(viewModel.activities.count == 1)
        #expect(viewModel.activities.first?.title == "Endurance run")
        #expect(viewModel.newActivityTitle.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Adding an activity with an empty title surfaces an error and does not persist")
    @MainActor
    func addActivityWithEmptyTitleSurfacesError() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service,
            athleteId: AthleteId(),
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.newActivityTitle = ""

        viewModel.addActivity()

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.activities.isEmpty)
    }

    @Test("Editing an activity updates its title")
    @MainActor
    func editActivityUpdatesTitle() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service,
            athleteId: AthleteId(),
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.newActivityTitle = "Endurance run"
        viewModel.addActivity()
        let activity = try #require(viewModel.activities.first)

        viewModel.editActivity(
            activity,
            title: "Mobility session",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            activityType: .recovery
        )

        #expect(viewModel.activities.first?.title == "Mobility session")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Deleting an activity while draft removes it")
    @MainActor
    func deleteActivityWhileDraftRemovesIt() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service,
            athleteId: AthleteId(),
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.newActivityTitle = "Endurance run"
        viewModel.addActivity()
        let activity = try #require(viewModel.activities.first)

        viewModel.deleteActivity(activity)

        #expect(viewModel.activities.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Deleting an activity after commit is rejected, surfaced as an error, and does not remove it")
    @MainActor
    func deleteActivityAfterCommitRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service,
            athleteId: AthleteId(),
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.newActivityTitle = "Endurance run"
        viewModel.addActivity()
        let activity = try #require(viewModel.activities.first)
        viewModel.commit()

        viewModel.deleteActivity(activity)

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.activities.count == 1)
    }

    @Test("Committing transitions the status label and disallows further edits")
    @MainActor
    func commitTransitionsStatus() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service,
            athleteId: AthleteId(),
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()

        viewModel.commit()

        #expect(viewModel.isCommitted)
        #expect(viewModel.weekPlan?.status == .committed)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Editing an activity after commit is rejected without crashing, and the activity is unchanged")
    @MainActor
    func editActivityAfterCommitRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service,
            athleteId: AthleteId(),
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.newActivityTitle = "Endurance run"
        viewModel.addActivity()
        let activity = try #require(viewModel.activities.first)
        viewModel.commit()

        viewModel.editActivity(
            activity,
            title: "Should not apply",
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            activityType: .recovery
        )

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.activities.first?.title == "Endurance run")
    }
}
