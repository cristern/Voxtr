import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrNotificationsDomain
import VoxtrCalendarPlanningDomain
import VoxtrAthleteDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Activity Edit -> Split Activity: covers the ViewModel/UI-facing layer
// specifically — eligibility (`canSplit`), the local split draft
// (`beginSplit`/`addSplitChild`/`removeSplitChild`), and
// `splitActivity()`'s wiring into `CalendarPlanningCoordinationService
// .splitExistingPlannedActivity`. Domain-level split behavior (field
// inheritance, validation reuse, rollback, midnight/week-boundary
// carry) is covered directly in `PlanningServiceTests.swift`'s own
// "Activity Edit -> Split Activity" section; source-backed decomposition
// provenance conversion (Lead Review Blocker 1) is covered in
// `CalendarPlanningCoordinationServiceTests.swift`'s own
// "Activity Edit -> Split Activity" section — neither duplicated here.
//
// Following `ActivityDetailReminderUITests`'s own already-accepted
// deviation from the S1.1 "no shared helpers" lesson: small inline
// fixture-assembly helpers are fine here since they only assemble
// already-constructed services, never share mutable state across tests.

/// A no-op `ActivityReminderScheduling` double — Split never touches
/// reminders, so nothing here needs to record/verify calls, unlike
/// `ActivityDetailReminderUITests`'s own recording fake.
private final class NoOpActivityReminderScheduler: ActivityReminderScheduling, @unchecked Sendable {
    func scheduleReminder(id: ActivityReminderId, fireDate: Date, content: ActivityReminderContent) {}
    func cancelReminder(id: ActivityReminderId) {}
    func authorizationStatus(completion: @escaping @MainActor @Sendable (ActivityReminderAuthorizationStatus) -> Void) {
        MainActor.assumeIsolated { completion(.authorized) }
    }
    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        MainActor.assumeIsolated { completion(true) }
    }
}

/// A bare no-op `CalendarEventProviding` — these ViewModel-layer tests
/// never exercise Calendar Import itself, only whether `splitActivity()`
/// correctly routes through the coordinator that owns it.
private struct NoOpCalendarEventProvider: CalendarEventProviding {
    func authorizationStatus(completion: @escaping @MainActor @Sendable (CalendarAuthorizationStatus) -> Void) {
        MainActor.assumeIsolated { completion(.authorized) }
    }
    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        MainActor.assumeIsolated { completion(true) }
    }
    func availableCalendars() throws -> [AvailableCalendar] { [] }
    func events(inCalendar calendarIdentifier: String, from: Date, to: Date) throws -> [ExternalCalendarEvent] { [] }
}

private struct FixedDateProvider: DateProvider {
    let now: Date
}

@Suite("ActivityDetailViewModel Split Activity (Activity Edit -> Split Activity)", .serialized)
struct ActivityDetailSplitActivityTests {

    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @MainActor
    private func makeFixture(container: ModelContainer) -> (
        planningService: PlanningService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        calendarPlanningCoordinationService: CalendarPlanningCoordinationService
    ) {
        let eventBus = EventBus()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext), eventBus: eventBus)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext), eventBus: eventBus)
        let trainingReflectionCoordinationService = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let activityReminderService = ActivityReminderService(
            repository: ActivityReminderRepository(modelContext: container.mainContext),
            scheduler: NoOpActivityReminderScheduler()
        )
        let notificationsPlanningCoordinationService = NotificationsPlanningCoordinationService(
            activityReminderService: activityReminderService,
            planningService: planningService,
            dateProvider: FixedDateProvider(now: Date(timeIntervalSince1970: 1_767_225_600))
        )
        notificationsPlanningCoordinationService.subscribeToEvents(eventBus)
        // Lead Review follow-up (PR #82): splitActivity() now routes
        // through this coordinator, not PlanningService directly.
        let calendarPlanningCoordinationService = CalendarPlanningCoordinationService(
            sourceRepository: ExternalPlanningSourceRepository(modelContext: container.mainContext),
            importDecisionRepository: CalendarImportDecisionRepository(modelContext: container.mainContext),
            legacyMappingRepository: CalendarPlanningMappingRepository(modelContext: container.mainContext),
            decomposedActivityLinkRepository: DecomposedActivityLinkRepository(modelContext: container.mainContext),
            decompositionEvidenceRepository: DecompositionEvidenceRepository(modelContext: container.mainContext),
            calendarEventProvider: NoOpCalendarEventProvider(),
            planningService: planningService,
            trainingService: trainingService,
            athleteRepository: AthleteRepository(modelContext: container.mainContext)
        )
        return (planningService, trainingReflectionCoordinationService, notificationsPlanningCoordinationService, calendarPlanningCoordinationService)
    }

    @MainActor
    private func makeActivity(planningService: PlanningService, athleteId: AthleteId) throws -> (weekPlan: WeekPlan, activity: PlannedActivity) {
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Hockey block", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 17, minute: 0), plannedDurationMinutes: 90
        )
        return (weekPlan, activity)
    }

    @MainActor
    private func makeViewModel(
        fixture: (
            planningService: PlanningService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
            calendarPlanningCoordinationService: CalendarPlanningCoordinationService
        ),
        athleteId: AthleteId,
        weekPlan: WeekPlan,
        activity: PlannedActivity,
        isCompleted: Bool = false,
        loggedActivity: LoggedActivity? = nil,
        onActivityLogged: @escaping () -> Void = {}
    ) -> ActivityDetailViewModel {
        ActivityDetailViewModel(
            activity: activity, isCompleted: isCompleted, loggedActivity: loggedActivity,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: fixture.planningService,
            trainingReflectionCoordinationService: fixture.trainingReflectionCoordinationService,
            notificationsPlanningCoordinationService: fixture.notificationsPlanningCoordinationService,
            calendarPlanningCoordinationService: fixture.calendarPlanningCoordinationService,
            onActivityLogged: onActivityLogged
        )
    }

    @Test("Split eligibility (canSplit) is true for a draft-week, not-yet-logged activity")
    @MainActor
    func canSplitTrueForEligibleActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        #expect(viewModel.canSplit == true)
    }

    @Test("Split is not eligible once a LoggedActivity exists, and splitActivity() refuses to run even if called directly")
    @MainActor
    func canSplitFalseAndSplitActivityRefusesOnceLogged() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let logResult = try fixture.trainingReflectionCoordinationService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, sportId: nil, categoryIds: [],
            activityType: .individualTraining, title: activity.title, startedAt: Date(), durationMinutes: 90,
            status: .completed, authorId: ActorId(), sessionForm: nil
        )
        let viewModel = makeViewModel(
            fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity,
            isCompleted: true, loggedActivity: logResult.loggedActivity
        )

        #expect(viewModel.canSplit == false)

        // Simulates a stale/reused draft reaching splitActivity() some
        // other way than through the (hidden) "Split Activity" button —
        // the application-boundary guard this task requires, not only
        // the button's own conditional visibility. This is the
        // ViewModel-level guard; the coordinator ALSO re-checks Training
        // eligibility itself (see CalendarPlanningCoordinationServiceTests
        // for that backstop covered directly).
        viewModel.splitChildren = [
            SplitChildDraft(activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 60),
            SplitChildDraft(activityType: .strength, startOffsetMinutes: 60, durationMinutes: 30)
        ]
        let succeeded = viewModel.splitActivity()

        #expect(succeeded == false)
        #expect(viewModel.errorMessage == PlanningStrings.splitNotEligible)
        #expect(try fixture.planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).count == 1)
    }

    @Test("VX-040: prefillEditForm() loads the persisted Activity Type unchanged — an individualTraining activity stays individualTraining")
    @MainActor
    func prefillEditFormLoadsPersistedIndividualTrainingUnchanged() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        // makeActivity() persists .individualTraining explicitly.
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.prefillEditForm()

        #expect(viewModel.editActivityType == .individualTraining)
    }

    @Test("VX-040: prefillEditForm() loads the persisted Activity Type unchanged — a teamTraining activity stays teamTraining, never reset to the new-draft default")
    @MainActor
    func prefillEditFormLoadsPersistedTeamTrainingUnchanged() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Team practice", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 17, minute: 0), plannedDurationMinutes: 90
        )
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.prefillEditForm()

        #expect(viewModel.editActivityType == .teamTraining)
    }

    @Test("beginSplit() seeds exactly one Calm-by-Default child (offset 0, duration 30) from the CURRENTLY PERSISTED activity, never from an unsaved Edit draft, and never the entire original duration")
    @MainActor
    func beginSplitReadsPersistedActivityNotUnsavedEditDraft() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        // An in-progress, UNSAVED Edit Planned Activity draft change —
        // must have no bearing on the split draft below.
        viewModel.editDurationMinutes = 15
        viewModel.editHasDuration = true

        viewModel.beginSplit()

        #expect(viewModel.splitChildren.count == 1)
        #expect(viewModel.splitChildren[0].activityType == .individualTraining)
        #expect(viewModel.splitChildren[0].startOffsetMinutes == 0)
        // The Calm-by-Default flat 30, never 15 (the unsaved edit draft)
        // and never 90 (the original's full duration).
        #expect(viewModel.splitChildren[0].durationMinutes == 30)
    }

    @Test("addSplitChild() derives each new child from the original's own remaining envelope, and never proposes past it")
    @MainActor
    func addSplitChildDerivesFromOriginalEnvelope() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        // plannedDurationMinutes: 90 — the "envelope" addSplitChild()
        // derives against.
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        viewModel.beginSplit()
        #expect(viewModel.splitChildren.count == 1)

        viewModel.addSplitChild()
        #expect(viewModel.splitChildren.count == 2)
        // VX-040: a new (non-first) split child defaults to .teamTraining.
        #expect(viewModel.splitChildren[1].activityType == .teamTraining)
        #expect(viewModel.splitChildren[1].startOffsetMinutes == 30)
        // Remainder up to the original's own 90-minute total — never
        // more, matching "never silently expand the total planned time."
        #expect(viewModel.splitChildren[1].durationMinutes == 60)

        // The running total (0-90) already reaches the original's own
        // envelope — a further tap is a NO-OP, exactly mirroring
        // CalendarImportReviewViewModel.nextSequentialSplitChild's own
        // "never auto-propose outside the envelope" guard.
        viewModel.addSplitChild()
        #expect(viewModel.splitChildren.count == 2)
    }

    @Test("removeSplitChild() mutates only the local split draft")
    @MainActor
    func removeSplitChildMutatesOnlyDraft() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        viewModel.beginSplit()
        viewModel.addSplitChild()
        #expect(viewModel.splitChildren.count == 2)

        let secondId = viewModel.splitChildren[1].id
        viewModel.removeSplitChild(secondId)

        #expect(viewModel.splitChildren.count == 1)
        #expect(!viewModel.splitChildren.contains { $0.id == secondId })
        #expect(try fixture.planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).count == 1)
    }

    @Test("splitActivity() with fewer than two children is rejected and canConfirmSplit reflects that")
    @MainActor
    func splitActivityRequiresTwoChildren() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        viewModel.beginSplit()
        #expect(viewModel.splitChildren.count == 1)
        #expect(viewModel.canConfirmSplit == false)

        let succeeded = viewModel.splitActivity()

        #expect(succeeded == false)
        #expect(viewModel.errorMessage == PlanningStrings.splitRequiresTwoChildren)
    }

    @Test("A successful split updates the ViewModel's activity, sets didSplitSuccessfully, and fires onActivityLogged")
    @MainActor
    func successfulSplitUpdatesViewModelAndFiresCallback() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        var loggedCount = 0
        let viewModel = makeViewModel(
            fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity,
            onActivityLogged: { loggedCount += 1 }
        )
        viewModel.beginSplit()
        viewModel.addSplitChild()
        #expect(viewModel.splitChildren.count == 2)
        #expect(viewModel.didSplitSuccessfully == false)

        let succeeded = viewModel.splitActivity()

        #expect(succeeded == true)
        #expect(viewModel.didSplitSuccessfully == true)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.activity.plannedActivityId == activity.plannedActivityId)
        // The first child's own (Calm-by-Default) duration — 30, not the
        // original's full 90.
        #expect(viewModel.activity.plannedDurationMinutes == 30)
        #expect(loggedCount == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).count == 2)
    }

    @Test("No regression: saveEdit() still works normally on a ViewModel that also carries split draft state")
    @MainActor
    func saveEditStillWorksAlongsideSplitState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        viewModel.beginSplit()
        viewModel.addSplitChild()

        viewModel.editTitle = "Renamed block"
        let succeeded = viewModel.saveEdit()

        #expect(succeeded == true)
        #expect(viewModel.activity.title == "Renamed block")
        // The untouched split draft never leaked into the ordinary edit.
        #expect(try fixture.planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId).count == 1)
    }

    @Test("PR #82 Lead Review follow-up 2 (short original durations): beginSplit() derives a bounded starting duration from a SHORT original, leaving room for a valid two-child draft without expanding the envelope")
    @MainActor
    func beginSplitBoundedDurationForShortOriginal() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Short block", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 17, minute: 0), plannedDurationMinutes: 30
        )
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.beginSplit()
        // min(30, max(1, 30 / 2)) == 15 — never the flat 30 that would
        // have consumed the ENTIRE 30-minute envelope, making a second
        // child impossible.
        #expect(viewModel.splitChildren.count == 1)
        #expect(viewModel.splitChildren[0].durationMinutes == 15)

        viewModel.addSplitChild()
        #expect(viewModel.splitChildren.count == 2)
        #expect(viewModel.splitChildren[1].startOffsetMinutes == 15)
        #expect(viewModel.splitChildren[1].durationMinutes == 15)
        #expect(viewModel.canConfirmSplit == true)
    }

    @Test("PR #82 Lead Review follow-up 2 (short original durations): a 1-minute original settles calmly with no room for a second child, and canAddSplitChild says so explicitly")
    @MainActor
    func beginSplitOnOneMinuteOriginalLeavesNoRoomForSecondChild() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Tiny block", localDate: LocalDate(year: 2026, month: 1, day: 6), timeZoneId: Self.oslo,
            startLocalTime: LocalTime(hour: 17, minute: 0), plannedDurationMinutes: 1
        )
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)

        viewModel.beginSplit()
        #expect(viewModel.splitChildren.count == 1)
        #expect(viewModel.splitChildren[0].durationMinutes == 1)
        #expect(viewModel.canAddSplitChild == false)

        viewModel.addSplitChild()
        // Calm no-op — never silently expands past the original's own
        // 1-minute envelope.
        #expect(viewModel.splitChildren.count == 1)
    }

    @Test("PR #82 Lead Review follow-up 2 (first-child offset UX): removeSplitChild() resets whichever row becomes first back to offset 0, so children[0].startOffsetMinutes == 0 always holds")
    @MainActor
    func removeSplitChildResetsNewFirstChildOffset() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let fixture = makeFixture(container: container)
        let athleteId = AthleteId()
        let (weekPlan, activity) = try makeActivity(planningService: fixture.planningService, athleteId: athleteId)
        let viewModel = makeViewModel(fixture: fixture, athleteId: athleteId, weekPlan: weekPlan, activity: activity)
        viewModel.beginSplit()
        viewModel.addSplitChild()
        #expect(viewModel.splitChildren.map(\.startOffsetMinutes) == [0, 30])

        let firstId = viewModel.splitChildren[0].id
        viewModel.removeSplitChild(firstId)

        #expect(viewModel.splitChildren.count == 1)
        // The row that was previously SECOND (offset 30) is now first,
        // and its offset has been normalized to 0 — never left at a
        // stale nonzero value the service would reject, and never relied
        // on the service's own validation as normal UX.
        #expect(viewModel.splitChildren[0].startOffsetMinutes == 0)
    }
}
