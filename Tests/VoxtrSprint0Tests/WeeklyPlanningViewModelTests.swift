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

    @MainActor
    private final class RecordingActivityChangeSubscriber: AthleteActivityChangeSubscriber {
        private(set) var callCount = 0
        func athleteActivityDidChange() { callCount += 1 }
    }

    @Test("Editing through Planning preserves PlannedActivity identity and invalidates only the affected athlete")
    @MainActor
    func editInvalidatesAffectedAthleteAndPreservesIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteA = AthleteId()
        let athleteB = AthleteId()
        let plan = try service.getOrCreateWeekPlan(athleteId: athleteA, weekStart: Self.fixedWeekStart)
        let original = try service.addPlannedActivity(
            toWeekPlan: plan.weekPlanId, athleteId: athleteA, activityType: .individualTraining,
            title: "Original", localDate: Self.fixedWeekStart, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let broadcaster = AthleteActivityChangeBroadcaster()
        let subscriberA = RecordingActivityChangeSubscriber()
        let subscriberB = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteA, subscriberA)
        broadcaster.subscribe(athleteId: athleteB, subscriberB)
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteA, committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart, activityChangeBroadcaster: broadcaster
        )
        viewModel.loadOrCreateWeekPlan()

        viewModel.editActivity(
            original, title: "Updated", localDate: Self.fixedWeekStart.adding(days: 1),
            activityType: .teamTraining
        )

        let fetched = try repository.fetchPlannedActivity(byId: original.plannedActivityId)
        let refetched = try #require(fetched)
        #expect(refetched.plannedActivityId == original.plannedActivityId)
        #expect(refetched.title == Optional("Updated"))
        #expect(refetched.localDate == Self.fixedWeekStart.adding(days: 1))
        #expect(subscriberA.callCount == 1)
        #expect(subscriberB.callCount == 0)
    }

    @Test("Deleting through Planning removes canonical truth and invalidates only the affected athlete")
    @MainActor
    func deleteInvalidatesAffectedAthleteWithoutReplacementRow() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteA = AthleteId()
        let athleteB = AthleteId()
        let plan = try service.getOrCreateWeekPlan(athleteId: athleteA, weekStart: Self.fixedWeekStart)
        let original = try service.addPlannedActivity(
            toWeekPlan: plan.weekPlanId, athleteId: athleteA, activityType: .individualTraining,
            title: "Delete me", localDate: Self.fixedWeekStart, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let broadcaster = AthleteActivityChangeBroadcaster()
        let subscriberA = RecordingActivityChangeSubscriber()
        let subscriberB = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteA, subscriberA)
        broadcaster.subscribe(athleteId: athleteB, subscriberB)
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteA, committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart, activityChangeBroadcaster: broadcaster
        )
        viewModel.loadOrCreateWeekPlan()

        viewModel.deleteActivity(original)

        #expect(try repository.fetchPlannedActivity(byId: original.plannedActivityId) == nil)
        #expect(try repository.fetchPlannedActivities(forWeekPlan: plan.weekPlanId).isEmpty)
        #expect(viewModel.activities.isEmpty)
        #expect(subscriberA.callCount == 1)
        #expect(subscriberB.callCount == 0)
    }

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

    @Test("Planning form saves a Sport-only identity and clears Sport back to nil")
    @MainActor
    func addSportOnlyActivityPersistsSportAndClearsForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let viewModel = WeeklyPlanningViewModel(
            service: PlanningService(repository: repository),
            athleteId: AthleteId(),
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        let sportId = SportId()
        viewModel.loadOrCreateWeekPlan()
        viewModel.newActivityTitle = "   "
        viewModel.newActivitySportId = sportId
        viewModel.newActivityType = .teamTraining

        viewModel.addActivity()

        #expect(viewModel.activities.count == 1)
        #expect(viewModel.activities.first?.title == nil)
        #expect(viewModel.activities.first?.sportId == sportId.rawValue)
        #expect(viewModel.activities.first?.activityType == .teamTraining)
        #expect(viewModel.newActivitySportId == nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Planning edit clears Sport without replacing stable PlannedActivity identity")
    @MainActor
    func editActivityClearsSportAndPreservesStableIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let viewModel = WeeklyPlanningViewModel(
            service: PlanningService(repository: repository),
            athleteId: AthleteId(),
            committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.newActivityTitle = "Named session"
        viewModel.newActivitySportId = SportId()
        viewModel.addActivity()
        let original = try #require(viewModel.activities.first)

        viewModel.editActivity(
            original,
            title: "Renamed session",
            localDate: original.localDate,
            activityType: .individualTraining,
            sportId: nil
        )

        let fetched = try repository.fetchPlannedActivity(byId: original.plannedActivityId)
        let edited = try #require(fetched)
        #expect(edited.plannedActivityId == original.plannedActivityId)
        #expect(edited.title == "Renamed session")
        #expect(edited.sportId == nil)
    }

    @Test("Planned/Logged Activity lifecycle consistency cleanup: adding an activity with 'Has duration' on persists the entered planned duration and resets the form")
    @MainActor
    func addActivityWithDurationPersistsPlannedDuration() throws {
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
        viewModel.newActivityHasDuration = true
        viewModel.newActivityDurationMinutes = 45

        viewModel.addActivity()

        #expect(viewModel.activities.first?.plannedDurationMinutes == 45)
        // Resets to the toggle's own default off-state, not the
        // previously entered value carried over into the next add.
        #expect(viewModel.newActivityHasDuration == false)
        #expect(viewModel.newActivityDurationMinutes == 60)
    }

    @Test("Planned/Logged Activity lifecycle consistency cleanup: adding an activity with 'Has duration' left off leaves plannedDurationMinutes nil — never fabricated")
    @MainActor
    func addActivityWithoutDurationLeavesPlannedDurationNil() throws {
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

        #expect(viewModel.activities.first?.plannedDurationMinutes == nil)
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

    // MARK: - Post-mutation navigation and stale-state consistency audit (Issue B)

    @Test("A successful add increments successfulAddActivityTrigger, so the view can signal it back to the top of the list")
    @MainActor
    func addActivitySuccessIncrementsSuccessfulAddActivityTrigger() throws {
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
        #expect(viewModel.successfulAddActivityTrigger == 0)

        viewModel.newActivityTitle = "Endurance run"
        viewModel.addActivity()
        #expect(viewModel.successfulAddActivityTrigger == 1)

        // A second successful add in the same session must increment
        // again — a Bool would only ever transition once, which is why
        // this mirrors DailyTrainingViewModel.successfulLogTrigger's own
        // counter shape rather than a Bool.
        viewModel.newActivityTitle = "Mobility session"
        viewModel.addActivity()
        #expect(viewModel.successfulAddActivityTrigger == 2)
    }

    @Test("A failed add does not increment successfulAddActivityTrigger")
    @MainActor
    func addActivityFailureDoesNotIncrementSuccessfulAddActivityTrigger() throws {
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
        #expect(viewModel.successfulAddActivityTrigger == 0)
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

    @Test("Activities loaded into the ViewModel are ordered deterministically, regardless of insertion order")
    @MainActor
    func activitiesOrderedDeterministically() throws {
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

        viewModel.newActivityTitle = "Thursday"
        viewModel.newActivityDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 8)) ?? .now
        viewModel.addActivity()
        viewModel.newActivityTitle = "Monday"
        viewModel.newActivityDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now
        viewModel.addActivity()

        #expect(viewModel.activities.map(\.title) == ["Monday", "Thursday"])
    }

    @Test("Loading twice never creates a duplicate WeekPlan")
    @MainActor
    func loadingTwiceNeverDuplicates() throws {
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
        let firstId = viewModel.weekPlan?.id
        viewModel.loadOrCreateWeekPlan()

        #expect(viewModel.weekPlan?.id == firstId)
        #expect(try container.mainContext.fetch(FetchDescriptor<WeekPlan>()).count == 1)
    }

    @Test("statusLabel reads Committed after committing")
    @MainActor
    func statusLabelReflectsCommittedState() throws {
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

        #expect(viewModel.statusLabel == "Committed")
    }

    @Test("Documents current, deliberate behavior: adding an activity after commit is NOT restricted (only edit/delete are)")
    @MainActor
    func addingAfterCommitIsCurrentlyAllowed() throws {
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

        viewModel.newActivityTitle = "Added after commit"
        viewModel.addActivity()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.activities.contains { $0.title == "Added after commit" })
    }

    // MARK: - Reversibility principle: Reopen Planning

    @Test("canReopenPlanning is true for a committed CURRENT week, true for a committed FUTURE week, and false for a committed HISTORICAL week")
    @MainActor
    func canReopenPlanningReflectsWeekRecency() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()

        let currentWeekViewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(),
            weekStart: WeeklyPlanningViewModel.currentWeekStart()
        )
        currentWeekViewModel.loadOrCreateWeekPlan()
        currentWeekViewModel.commit()
        #expect(currentWeekViewModel.canReopenPlanning == true)

        let futureWeekViewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(),
            weekStart: WeeklyPlanningViewModel.currentWeekStart().adding(days: 7)
        )
        futureWeekViewModel.loadOrCreateWeekPlan()
        futureWeekViewModel.commit()
        #expect(futureWeekViewModel.canReopenPlanning == true)

        // Self.fixedWeekStart (2026-01-05) is a historical week relative
        // to any real "today" this suite could plausibly run on.
        let historicalWeekViewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        historicalWeekViewModel.loadOrCreateWeekPlan()
        historicalWeekViewModel.commit()
        #expect(historicalWeekViewModel.canReopenPlanning == false)

        // A draft week (regardless of recency) is never reopenable —
        // there is nothing to reopen.
        #expect(currentWeekViewModel.isCommitted)
        let draftAgain = WeeklyPlanningViewModel(
            service: service, athleteId: AthleteId(), committedByActorId: ActorId(),
            weekStart: WeeklyPlanningViewModel.currentWeekStart()
        )
        draftAgain.loadOrCreateWeekPlan()
        #expect(draftAgain.canReopenPlanning == false)
    }

    @Test("reopenPlanning returns a committed week to draft immediately, in place — no navigation or reload required — and preserves every activity")
    @MainActor
    func reopenPlanningRestoresDraftStateInPlace() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(),
            weekStart: WeeklyPlanningViewModel.currentWeekStart()
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.newActivityTitle = "Endurance run"
        viewModel.addActivity()
        let originalActivityId = viewModel.activities.first?.plannedActivityId
        viewModel.commit()
        #expect(viewModel.isCommitted == true)

        viewModel.reopenPlanning()

        // Immediately reflected on the SAME viewModel instance — no
        // separate reload/onAppear needed for this assertion to hold.
        #expect(viewModel.isCommitted == false)
        #expect(viewModel.statusLabel == "Draft")
        #expect(viewModel.errorMessage == nil)
        // The exact same activity, still present, same identity.
        #expect(viewModel.activities.count == 1)
        #expect(viewModel.activities.first?.plannedActivityId == originalActivityId)
        #expect(viewModel.activities.first?.title == "Endurance run")
    }

    @Test("A reopened week's plan can be committed again through the normal canonical flow")
    @MainActor
    func reopenedPlanCanBeRecommitted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: AthleteId(), committedByActorId: ActorId(),
            weekStart: WeeklyPlanningViewModel.currentWeekStart()
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.commit()
        viewModel.reopenPlanning()

        viewModel.commit()

        #expect(viewModel.isCommitted == true)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("canReopenPlanning hides Reopen Planning for a committed historical week, AND reopenPlanning() itself is rejected by the domain if called anyway")
    @MainActor
    func canReopenPlanningReflectsDomainEnforcedHistoricalRejection() throws {
        // Review follow-up: the historical-week restriction is no
        // longer a ViewModel/UI-only convenience — WeekPlan.reopen
        // itself now rejects a historical week via
        // WeekPlanConflictError.historicalWeekNotReopenable (see
        // PlanningServiceTests.reopenRejectedForHistoricalWeekAtDomainBoundary
        // for the direct domain-level proof). This test proves the
        // SAME rejection surfaces correctly through
        // WeeklyPlanningViewModel.reopenPlanning() even when called
        // despite canReopenPlanning already reading false — canReopenPlanning
        // remains useful presentation gating (so the button is never
        // shown), but is no longer the only thing standing between a
        // historical week and being reopened.
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: AthleteId(), committedByActorId: ActorId(),
            weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.commit()
        #expect(viewModel.canReopenPlanning == false)

        // Called anyway, bypassing the UI gate entirely.
        viewModel.reopenPlanning()

        #expect(viewModel.isCommitted == true)
        #expect(viewModel.errorMessage != nil)
    }
}

// MARK: - Recurring Planned Activities

@Suite("WeeklyPlanningViewModel — Recurring Planned Activities", .serialized)
struct WeeklyPlanningViewModelRecurringActivityTests {

    private static let fixedWeekStart = LocalDate(year: 2026, month: 1, day: 5) // a Monday
    private static let rangeStart = LocalDate(year: 2026, month: 1, day: 1)
    private static let rangeEnd = LocalDate(year: 2026, month: 1, day: 31)

    @Test("Recurring suggestions load alongside the WeekPlan")
    @MainActor
    func suggestionsLoadWithWeekPlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )

        viewModel.loadOrCreateWeekPlan()

        #expect(viewModel.recurringSuggestions.count == 1)
        #expect(viewModel.recurringSuggestions.first?.title == "Football")
    }

    @Test("Accepting a suggestion removes it from recurringSuggestions and adds a matching activity")
    @MainActor
    func acceptSuggestionRemovesItAndAddsActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        let suggestion = try #require(viewModel.recurringSuggestions.first)

        viewModel.acceptSuggestion(suggestion)

        #expect(viewModel.recurringSuggestions.isEmpty)
        #expect(viewModel.activities.contains { $0.title == "Football" })
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Dismissing a suggestion removes only that suggestion, leaving others untouched")
    @MainActor
    func dismissRemovesOnlyThatSuggestion() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Swimming", activityType: .individualTraining, weekdays: [.wednesday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        #expect(viewModel.recurringSuggestions.count == 2)
        let toDismiss = try #require(viewModel.recurringSuggestions.first { $0.title == "Football" })

        viewModel.dismissSuggestion(toDismiss)

        #expect(viewModel.recurringSuggestions.count == 1)
        #expect(viewModel.recurringSuggestions.first?.title == "Swimming")
    }

    @Test("Dismissal is session-only: a fresh ViewModel loading from persistence still shows the dismissed occurrence")
    @MainActor
    func dismissalIsSessionOnly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let firstViewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        firstViewModel.loadOrCreateWeekPlan()
        let suggestion = try #require(firstViewModel.recurringSuggestions.first)
        firstViewModel.dismissSuggestion(suggestion)
        #expect(firstViewModel.recurringSuggestions.isEmpty)

        // A brand-new ViewModel instance — "reloading from persistence"
        // — has no memory of the dismissal, since it was never stored.
        let secondViewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        secondViewModel.loadOrCreateWeekPlan()

        #expect(secondViewModel.recurringSuggestions.count == 1)
        #expect(secondViewModel.recurringSuggestions.first?.title == "Football")
    }

    @Test("An accepted occurrence remains absent after a fresh ViewModel reloads from persistence")
    @MainActor
    func acceptedOccurrenceRemainsAbsentAfterReload() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let firstViewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        firstViewModel.loadOrCreateWeekPlan()
        let suggestion = try #require(firstViewModel.recurringSuggestions.first)
        firstViewModel.acceptSuggestion(suggestion)

        let secondViewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        secondViewModel.loadOrCreateWeekPlan()

        #expect(secondViewModel.recurringSuggestions.isEmpty)
        #expect(secondViewModel.activities.contains { $0.title == "Football" })
    }

    @Test("Committed WeekPlans cannot accept recurring suggestions — the attempt surfaces an error and creates nothing")
    @MainActor
    func committedWeekPlansCannotAcceptSuggestions() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        let suggestion = try #require(viewModel.recurringSuggestions.first)
        viewModel.commit()

        viewModel.acceptSuggestion(suggestion)

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.activities.isEmpty)
    }

    @Test("Existing manual add/edit/delete/commit behavior is unchanged by the presence of recurring suggestions")
    @MainActor
    func existingManualBehaviorUnchanged() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()

        viewModel.newActivityTitle = "Manual entry"
        viewModel.addActivity()
        let manualActivity = try #require(viewModel.activities.first { $0.title == "Manual entry" })

        viewModel.editActivity(manualActivity, title: "Manual entry (edited)", localDate: Self.fixedWeekStart, activityType: .recovery)
        #expect(viewModel.activities.first { $0.id == manualActivity.id }?.title == "Manual entry (edited)")

        viewModel.deleteActivity(manualActivity)
        #expect(!viewModel.activities.contains { $0.id == manualActivity.id })

        viewModel.commit()
        #expect(viewModel.isCommitted)
        #expect(viewModel.errorMessage == nil)
    }

    // MARK: Management flow

    @Test("loadRecurringActivities populates the management list, scoped to the athlete")
    @MainActor
    func loadRecurringActivitiesPopulatesList() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        _ = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )

        viewModel.loadRecurringActivities()

        #expect(viewModel.recurringPlannedActivities.count == 1)
        #expect(viewModel.recurringPlannedActivities.first?.title == "Football")
    }

    @Test("createRecurringActivity persists a new definition from the form fields and resets the form")
    @MainActor
    func createRecurringActivityPersistsFromForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.recurringFormTitle = "Football"
        viewModel.recurringFormActivityType = .teamTraining
        viewModel.recurringFormWeekdays = [.monday]
        viewModel.recurringFormStartDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1)) ?? .now
        viewModel.recurringFormEndDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 31)) ?? .now

        viewModel.createRecurringActivity()

        #expect(viewModel.recurringPlannedActivities.contains { $0.title == "Football" })
        #expect(viewModel.recurringFormTitle.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Recurring form saves a Sport-only identity")
    @MainActor
    func createRecurringActivityWithSportOnlyIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let viewModel = WeeklyPlanningViewModel(
            service: PlanningService(repository: repository), athleteId: AthleteId(),
            committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        let sportId = SportId()
        viewModel.recurringFormTitle = " \n "
        viewModel.recurringFormSportId = sportId
        viewModel.recurringFormActivityType = .conditioning
        viewModel.recurringFormWeekdays = [.monday]
        viewModel.recurringFormStartDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1)) ?? .now
        viewModel.recurringFormEndDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 31)) ?? .now

        let succeeded = viewModel.createRecurringActivity()

        #expect(succeeded)
        #expect(viewModel.recurringPlannedActivities.first?.title == nil)
        #expect(viewModel.recurringPlannedActivities.first?.sportId == sportId.rawValue)
        #expect(viewModel.recurringPlannedActivities.first?.activityType == .conditioning)
    }

    @Test("Creating a recurring activity while the current week's WeekPlan is loaded refreshes its suggestions")
    @MainActor
    func creatingRecurringActivityRefreshesCurrentWeekSuggestions() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        #expect(viewModel.recurringSuggestions.isEmpty)

        viewModel.recurringFormTitle = "Football"
        viewModel.recurringFormWeekdays = [.monday]
        viewModel.recurringFormStartDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1)) ?? .now
        viewModel.recurringFormEndDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 31)) ?? .now
        viewModel.createRecurringActivity()

        #expect(viewModel.recurringSuggestions.contains { $0.title == "Football" })
    }

    @Test("editRecurringActivity updates an existing definition")
    @MainActor
    func editRecurringActivityUpdatesDefinition() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let created = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.beginEditingRecurringActivity(created)
        viewModel.recurringFormTitle = "Football (updated)"

        viewModel.editRecurringActivity(created)

        #expect(viewModel.recurringPlannedActivities.contains { $0.title == "Football (updated)" })
        #expect(viewModel.errorMessage == nil)
    }

    @Test("toggleRecurringActivityEnabled flips the enabled state")
    @MainActor
    func toggleRecurringActivityEnabledFlipsState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let created = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.loadRecurringActivities()
        #expect(viewModel.recurringPlannedActivities.first?.isEnabled == true)

        viewModel.toggleRecurringActivityEnabled(created)

        #expect(viewModel.recurringPlannedActivities.first?.isEnabled == false)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("beginEditingRecurringActivity populates the form fields from the existing definition")
    @MainActor
    func beginEditingPopulatesFormFields() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let created = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            startLocalTime: LocalTime(hour: 17, minute: 30), plannedDurationMinutes: 150,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), effectiveStartDate: Self.rangeStart, effectiveEndDate: Self.rangeEnd
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )

        viewModel.beginEditingRecurringActivity(created)

        #expect(viewModel.recurringFormTitle == "Football")
        #expect(viewModel.recurringFormWeekdays == [.monday])
        #expect(viewModel.recurringFormHasStartTime == true)
        #expect(viewModel.recurringFormHasDuration == true)
        #expect(viewModel.recurringFormDurationMinutes == 150)
    }

    // MARK: Create/edit report success/failure (correctness revision)

    @Test("A successful creation reports success (true)")
    @MainActor
    func successfulCreationReportsSuccess() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.recurringFormTitle = "Football"
        viewModel.recurringFormWeekdays = [.monday]
        viewModel.recurringFormStartDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1)) ?? .now
        viewModel.recurringFormEndDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 31)) ?? .now

        let succeeded = viewModel.createRecurringActivity()

        #expect(succeeded == true)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A failed creation reports failure (false) and preserves the entered form values")
    @MainActor
    func failedCreationReportsFailureAndPreservesFormValues() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        // Empty title — genuinely invalid, rejected by PlanningService's
        // own validation, a real reachable failure rather than a forced
        // one.
        viewModel.recurringFormTitle = ""
        viewModel.recurringFormWeekdays = [.wednesday]
        viewModel.recurringFormStartDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1)) ?? .now
        viewModel.recurringFormEndDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 31)) ?? .now

        let succeeded = viewModel.createRecurringActivity()

        #expect(succeeded == false)
        #expect(viewModel.errorMessage != nil)
        // Entered values remain available — the form was not reset.
        #expect(viewModel.recurringFormTitle == "")
        #expect(viewModel.recurringFormWeekdays == [.wednesday])
    }

    @Test("A successful edit reports success (true)")
    @MainActor
    func successfulEditReportsSuccess() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let created = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: Self.fixedWeekStart, effectiveEndDate: Self.fixedWeekStart.adding(days: 60)
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.beginEditingRecurringActivity(created)
        viewModel.recurringFormTitle = "Football (updated)"

        let succeeded = viewModel.editRecurringActivity(created)

        #expect(succeeded == true)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A failed edit reports failure (false) and preserves the entered form values")
    @MainActor
    func failedEditReportsFailureAndPreservesFormValues() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let created = try service.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football", activityType: .teamTraining, weekdays: [.monday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: Self.fixedWeekStart, effectiveEndDate: Self.fixedWeekStart.adding(days: 60)
        )
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.beginEditingRecurringActivity(created)
        // Empty title — genuinely invalid.
        viewModel.recurringFormTitle = ""
        viewModel.recurringFormWeekdays = [.friday]

        let succeeded = viewModel.editRecurringActivity(created)

        #expect(succeeded == false)
        #expect(viewModel.errorMessage != nil)
        // Entered values remain available — the form was not reset.
        #expect(viewModel.recurringFormTitle == "")
        #expect(viewModel.recurringFormWeekdays == [.friday])
    }

    // MARK: - Issue 2 (Parent Time Navigation package): switchToWeek coverage

    @Test("switchToWeek actually uses the new week for subsequent planning operations")
    @MainActor
    func switchToWeekIsUsedForPlanningOperations() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()

        let nextWeekStart = Self.fixedWeekStart.adding(days: 7)
        viewModel.switchToWeek(nextWeekStart)
        viewModel.newActivityTitle = "Added after switch"
        viewModel.addActivity()

        // The activity landed in the NEW week's plan, not the original.
        let newWeekPlan = try repository.fetchWeekPlan(forAthlete: athleteId, weekStart: nextWeekStart)
        let originalWeekPlan = try repository.fetchWeekPlan(forAthlete: athleteId, weekStart: Self.fixedWeekStart)
        #expect(newWeekPlan != nil)
        let newWeekActivities = try repository.fetchPlannedActivities(forWeekPlan: newWeekPlan!.weekPlanId)
        let originalWeekActivities = try repository.fetchPlannedActivities(forWeekPlan: originalWeekPlan!.weekPlanId)
        #expect(newWeekActivities.contains { $0.title == "Added after switch" })
        #expect(!originalWeekActivities.contains { $0.title == "Added after switch" })
    }

    @Test("switchToWeek selects/creates the correct WeekPlan for the destination week")
    @MainActor
    func switchToWeekSelectsCorrectWeekPlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let previousWeekStart = Self.fixedWeekStart.adding(days: -7)
        let existingPreviousWeekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: previousWeekStart)

        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()

        viewModel.switchToWeek(previousWeekStart)

        #expect(viewModel.weekPlan?.weekPlanId == existingPreviousWeekPlan.weekPlanId)
        #expect(viewModel.weekStart == previousWeekStart)
    }

    @Test("switchToWeek does not leave the previous week's activities visible under the new week")
    @MainActor
    func switchToWeekClearsStaleActivities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: athleteId, committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()
        viewModel.newActivityTitle = "Week one activity"
        viewModel.addActivity()
        #expect(viewModel.activities.contains { $0.title == "Week one activity" })

        let emptyNextWeekStart = Self.fixedWeekStart.adding(days: 7)
        viewModel.switchToWeek(emptyNextWeekStart)

        // The new (empty) week must never show the previous week's
        // activity — no stale carry-over.
        #expect(!viewModel.activities.contains { $0.title == "Week one activity" })
    }

    @Test("switchToWeek preserves canonical Monday-Sunday week identity for the destination week")
    @MainActor
    func switchToWeekPreservesMondaySundaySemantics() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let viewModel = WeeklyPlanningViewModel(
            service: service, athleteId: AthleteId(), committedByActorId: ActorId(), weekStart: Self.fixedWeekStart
        )
        viewModel.loadOrCreateWeekPlan()

        let nextWeekStart = Self.fixedWeekStart.adding(days: 7)
        viewModel.switchToWeek(nextWeekStart)

        #expect(viewModel.weekStart.weekday == .monday)
        #expect(viewModel.weekStart == nextWeekStart.startOfWeek)
    }
}
