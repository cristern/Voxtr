import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrCalendarPlanningDomain
import VoxtrCoreReferenceData

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared cross-file helper methods for
// container/repository construction — every test builds its own inline,
// via this file's own `Fixture`/`makeFixture()` (not shared with
// `CalendarPlanningCoordinationServiceTests.swift`, even though the two
// are structurally similar).

private final class FakeCalendarEventProvider: CalendarEventProviding, @unchecked Sendable {
    var eventsByCalendar: [String: [ExternalCalendarEvent]] = [:]
    var unavailableCalendars: Set<String> = []
    var authStatus: CalendarAuthorizationStatus = .authorized

    func authorizationStatus(completion: @escaping @MainActor @Sendable (CalendarAuthorizationStatus) -> Void) {
        let status = authStatus
        Task { @MainActor in completion(status) }
    }

    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        Task { @MainActor in completion(true) }
    }

    func availableCalendars() throws -> [AvailableCalendar] { [] }

    func events(inCalendar calendarIdentifier: String, from: Date, to: Date) throws -> [ExternalCalendarEvent] {
        if unavailableCalendars.contains(calendarIdentifier) {
            throw CalendarEventProviderError.calendarUnavailable
        }
        return eventsByCalendar[calendarIdentifier] ?? []
    }
}

private struct FixedDateProvider: DateProvider {
    let now: Date
}

@Suite("CalendarImportReviewViewModel (Calendar Import Review V1.1)", .serialized)
struct CalendarImportReviewViewModelTests {

    private static let referenceDate = Date(timeIntervalSince1970: 1_767_312_000)
    private static let timeZoneId = TimeZoneId(rawValue: "Europe/Oslo")

    private struct Fixture {
        let planningService: PlanningService
        let trainingService: TrainingService
        let athleteRepository: AthleteRepository
        let sportRepository: SportRepository
        let importDecisionRepository: CalendarImportDecisionRepository
        let calendarProvider: FakeCalendarEventProvider
        let coordinationService: CalendarPlanningCoordinationService
        let workspaceId: WorkspaceId
        let athleteId: AthleteId
        let source: ExternalPlanningSource
    }

    private func makeFixture(referenceDate: Date = referenceDate) throws -> Fixture {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let sourceRepository = ExternalPlanningSourceRepository(modelContext: container.mainContext)
        let importDecisionRepository = CalendarImportDecisionRepository(modelContext: container.mainContext)
        let legacyMappingRepository = CalendarPlanningMappingRepository(modelContext: container.mainContext)
        let sportRepository = SportRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let calendarProvider = FakeCalendarEventProvider()
        let coordinationService = CalendarPlanningCoordinationService(
            sourceRepository: sourceRepository,
            importDecisionRepository: importDecisionRepository,
            legacyMappingRepository: legacyMappingRepository,
            calendarEventProvider: calendarProvider,
            planningService: planningService,
            trainingService: trainingService,
            athleteRepository: athleteRepository,
            dateProvider: FixedDateProvider(now: referenceDate)
        )
        let workspaceId = WorkspaceId()
        let athlete = try athleteRepository.createAthlete(
            workspaceId: workspaceId,
            givenName: "Runner",
            birthDate: LocalDate(year: 2012, month: 3, day: 1),
            timeZoneId: Self.timeZoneId,
            developmentStage: .parentLed
        )
        let source = try coordinationService.createSource(
            forWorkspace: workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        return Fixture(
            planningService: planningService,
            trainingService: trainingService,
            athleteRepository: athleteRepository,
            sportRepository: sportRepository,
            importDecisionRepository: importDecisionRepository,
            calendarProvider: calendarProvider,
            coordinationService: coordinationService,
            workspaceId: workspaceId,
            athleteId: athlete.athleteId,
            source: source
        )
    }

    @discardableResult
    private func addSecondAthlete(_ fixture: Fixture, name: String = "Sibling", workspaceId: WorkspaceId? = nil) throws -> AthleteId {
        let athlete = try fixture.athleteRepository.createAthlete(
            workspaceId: workspaceId ?? fixture.workspaceId,
            givenName: name,
            birthDate: LocalDate(year: 2014, month: 5, day: 12),
            timeZoneId: Self.timeZoneId,
            developmentStage: .parentLed
        )
        return athlete.athleteId
    }

    private func makeViewModel(_ fixture: Fixture) -> CalendarImportReviewViewModel {
        CalendarImportReviewViewModel(
            calendarPlanningCoordinationService: fixture.coordinationService,
            athleteRepository: fixture.athleteRepository,
            sportRepository: fixture.sportRepository,
            source: fixture.source,
            actorId: ActorId()
        )
    }

    private func addEvent(_ fixture: Fixture, identifier: String, title: String, hoursFromReference: Double) {
        let start = Self.referenceDate.addingTimeInterval(hoursFromReference * 3600)
        var existing = fixture.calendarProvider.eventsByCalendar["cal-familie"] ?? []
        existing.append(
            ExternalCalendarEvent(
                eventIdentifier: identifier, calendarIdentifier: "cal-familie", title: title,
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        )
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = existing
    }

    // MARK: - 1, 2, 3, 4, 5: the Ready transition is an explicit Parent action, never a side effect of picking a value

    @Test("A pending event can hold a staged Athlete/Sport/Activity Type without creating a PlannedActivity or CalendarImportDecision")
    @MainActor
    func stagingNeverCreatesPersistedTruth() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.setStagedActivityType(.teamTraining, for: item.externalEventKey)

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
    }

    @Test("Lead Review follow-up: selecting Athlete alone does NOT move a new event to Ready — only the explicit markReady action does, and only once an Athlete is staged")
    @MainActor
    func selectingAthleteAloneDoesNotAutoCollapseToReady() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        #expect(viewModel.needsReviewItems.count == 1)
        #expect(viewModel.readyToImportItems.isEmpty)

        // Item 5: markReady is a no-op without an Athlete — the row stays
        // in Needs Review.
        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.needsReviewItems.count == 1)
        #expect(viewModel.readyToImportItems.isEmpty)

        // Item 1: selecting Athlete alone never auto-collapses the row.
        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        #expect(viewModel.needsReviewItems.count == 1)
        #expect(viewModel.readyToImportItems.isEmpty)
        #expect(viewModel.stagedClassification(for: item.externalEventKey).athleteId == fixture.athleteId)

        // Item 2/3: changing Sport, then Activity Type, still never
        // auto-collapses.
        viewModel.setStagedSport(nil, for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.isEmpty)
        viewModel.setStagedActivityType(.teamTraining, for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.isEmpty)
        #expect(viewModel.needsReviewItems.count == 1)

        // Item 4: only the explicit markReady action moves it to Ready
        // to Import, now that an Athlete is staged.
        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.needsReviewItems.isEmpty)
        #expect(viewModel.readyToImportItems.count == 1)
        #expect(viewModel.readyToImportCount == 1)
        #expect(viewModel.stagedClassification(for: item.externalEventKey).activityType == .teamTraining)
    }

    @Test("An event with only a partial staged classification (no Athlete chosen) is never included in bulk import")
    @MainActor
    func incompleteStagedClassificationExcludedFromBulkImport() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        // Sport/Activity Type touched, but never an Athlete.
        viewModel.setStagedSport(nil, for: item.externalEventKey)
        viewModel.setStagedActivityType(.teamTraining, for: item.externalEventKey)
        viewModel.markReady(for: item.externalEventKey) // no-op: no Athlete yet

        viewModel.bulkImportReadyItems()

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(viewModel.reviewQueue.count == 1)
        #expect(viewModel.needsReviewItems.count == 1)
    }

    @Test("Item 9: a staged event with an Athlete but never explicitly marked Ready is excluded from bulk import")
    @MainActor
    func stagedButUnconfirmedItemExcludedFromBulkImport() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        // Deliberately never calls markReady.

        viewModel.bulkImportReadyItems()

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(viewModel.reviewQueue.count == 1)
        #expect(viewModel.needsReviewItems.count == 1)
        #expect(viewModel.stagedClassification(for: item.externalEventKey).athleteId == fixture.athleteId)
    }

    // MARK: - 4, 5, 6: bulk import

    @Test("Multiple Ready events can be bulk imported in one Parent action, each creating exactly one PlannedActivity and one imported CalendarImportDecision")
    @MainActor
    func multipleReadyEventsAreBulkImportedTogether() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Oliver's Practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Sibling's Practice", hoursFromReference: 2)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        #expect(viewModel.reviewQueue.count == 2)

        for item in viewModel.reviewQueue {
            let athleteId = item.event.title == "Oliver's Practice" ? fixture.athleteId : secondAthleteId
            viewModel.setStagedAthlete(athleteId, for: item.externalEventKey)
            viewModel.markReady(for: item.externalEventKey)
        }
        #expect(viewModel.readyToImportCount == 2)

        viewModel.bulkImportReadyItems()

        let activities = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activities.count == 2)
        let decisions = try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId)
        #expect(decisions.filter { $0.status == .imported }.count == 2)
    }

    @Test("Successfully bulk-imported events disappear from the review queue, while remaining still-pending events stay")
    @MainActor
    func successfulBulkImportsDisappearWhilePendingRemain() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Ready Event", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Still Pending Event", hoursFromReference: 2)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let readyItem = try #require(viewModel.reviewQueue.first { $0.event.title == "Ready Event" })
        viewModel.setStagedAthlete(fixture.athleteId, for: readyItem.externalEventKey)
        viewModel.markReady(for: readyItem.externalEventKey)

        viewModel.bulkImportReadyItems()

        #expect(viewModel.reviewQueue.count == 1)
        #expect(viewModel.reviewQueue.first?.event.title == "Still Pending Event")
        #expect(viewModel.needsReviewItems.count == 1)
        #expect(viewModel.readyToImportItems.isEmpty)
    }

    // MARK: - 7: partial batch failure

    @Test("A partial batch failure leaves the failed item staged and editable, and retrying the batch never duplicates the already-successful import")
    @MainActor
    func partialBatchFailureLeavesFailedItemEditableWithoutDuplicating() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Will Succeed", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Will Conflict", hoursFromReference: 2)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let succeedItem = try #require(viewModel.reviewQueue.first { $0.event.title == "Will Succeed" })
        let conflictItem = try #require(viewModel.reviewQueue.first { $0.event.title == "Will Conflict" })

        // Pre-seed a legacy PlannedActivity for the SECOND event, owned by
        // a DIFFERENT athlete than the Parent is about to stage — this
        // forces classifyAndImport's own existingActivityConflict on that
        // one item only.
        let today = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: secondAthleteId, weekStart: today)
        _ = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: secondAthleteId, activityType: .individualTraining,
            title: "Will Conflict", localDate: today, timeZoneId: Self.timeZoneId,
            externalSourceId: conflictItem.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )

        viewModel.setStagedAthlete(fixture.athleteId, for: succeedItem.externalEventKey)
        viewModel.markReady(for: succeedItem.externalEventKey)
        viewModel.setStagedAthlete(fixture.athleteId, for: conflictItem.externalEventKey)
        viewModel.markReady(for: conflictItem.externalEventKey)
        #expect(viewModel.readyToImportCount == 2)

        viewModel.bulkImportReadyItems()

        #expect(viewModel.errorMessage != nil)
        // The succeeded event is gone from the queue; the conflicting one
        // remains, staged, and back in the editable Needs Review group.
        #expect(viewModel.reviewQueue.count == 1)
        #expect(viewModel.reviewQueue.first?.externalEventKey == conflictItem.externalEventKey)
        #expect(viewModel.needsReviewItems.count == 1)
        let stagedAfterFailure = viewModel.stagedClassification(for: conflictItem.externalEventKey)
        #expect(stagedAfterFailure.athleteId == fixture.athleteId)
        #expect(stagedAfterFailure.isConfirmedReady == false)

        let activitiesAfterFirstAttempt = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activitiesAfterFirstAttempt.count == 2) // the succeeded import + the pre-seeded legacy activity

        // Parent explicitly re-confirms Ready for the SAME (still-
        // conflicting) staged athlete and retries the batch. Must not
        // duplicate the already-successful import, and must not create a
        // second activity for the still-conflicting one.
        viewModel.markReady(for: conflictItem.externalEventKey)
        #expect(viewModel.readyToImportCount == 1)
        viewModel.bulkImportReadyItems()

        #expect(viewModel.errorMessage != nil)
        let activitiesAfterRetry = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activitiesAfterRetry.count == 2)
        #expect(viewModel.reviewQueue.first?.externalEventKey == conflictItem.externalEventKey)
    }

    // MARK: - 6, 7: Edit restores editable state without persisting, and does not re-collapse until Ready is explicitly reconfirmed

    @Test("Tapping Edit on a Ready item restores its editable classification state without persisting anything, and changing a value afterward does not re-collapse it until Ready is explicitly confirmed again")
    @MainActor
    func editOnReadyItemRestoresEditableStateWithoutPersisting() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.count == 1)

        viewModel.beginEditing(for: item.externalEventKey)

        #expect(viewModel.needsReviewItems.count == 1)
        #expect(viewModel.readyToImportItems.isEmpty)
        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        // Values are preserved, not cleared.
        #expect(staged.athleteId == fixture.athleteId)
        #expect(staged.isConfirmedReady == false)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)

        // Item 7: changing a value after Edit must NOT re-collapse the
        // row on its own — it stays in Needs Review until the Parent
        // explicitly confirms Ready again.
        viewModel.setStagedActivityType(.recovery, for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.isEmpty)
        #expect(viewModel.needsReviewItems.count == 1)

        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.count == 1)
        #expect(viewModel.stagedClassification(for: item.externalEventKey).activityType == .recovery)
    }

    // MARK: - 10, 11: remembered prefill may initialize as Ready, but is still presentation-only

    @Test("Item 10/11: a remembered exact-title prefill MAY initialize as Ready, but it never creates a PlannedActivity by itself — only an explicit bulk import does")
    @MainActor
    func rememberedPrefillMayInitializeAsReadyButNeverImportsAlone() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.setStagedAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        firstViewModel.setStagedActivityType(.teamTraining, for: firstItem.externalEventKey)
        firstViewModel.markReady(for: firstItem.externalEventKey)
        firstViewModel.bulkImportReadyItems()
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 1)

        // A NEW, later occurrence of the exact same normalized title —
        // unlike a brand-new/unremembered event, this ONE MAY arrive
        // already Parent-confirmed Ready (item 10), since the safe exact
        // remembered classification already agrees on every prior
        // explicit import.
        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        let staged = secondViewModel.stagedClassification(for: secondItem.externalEventKey)
        #expect(staged.athleteId == fixture.athleteId)
        #expect(staged.activityType == .teamTraining)
        #expect(staged.isConfirmedReady == true)
        #expect(secondViewModel.readyToImportItems.count == 1)
        // Item 11: still NOT imported — merely presentation assistance
        // until the Parent's own explicit bulk import.
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 1)
    }

    @Test("Item 12: the Parent can Edit/override a remembered Ready item, then must explicitly mark it Ready again before the override is what gets bulk-imported")
    @MainActor
    func parentCanOverrideRememberedPrefillBeforeBulkImport() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.setStagedAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        firstViewModel.markReady(for: firstItem.externalEventKey)
        firstViewModel.bulkImportReadyItems()

        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        #expect(secondViewModel.stagedClassification(for: secondItem.externalEventKey).athleteId == fixture.athleteId)
        #expect(secondViewModel.readyToImportItems.count == 1)

        // Parent taps Edit to inspect/override the remembered value —
        // this un-confirms it, so it is no longer in the Ready set even
        // though its values are unchanged so far.
        secondViewModel.beginEditing(for: secondItem.externalEventKey)
        #expect(secondViewModel.readyToImportItems.isEmpty)
        #expect(secondViewModel.needsReviewItems.count == 1)

        // Parent explicitly overrides to the sibling instead. Per item 7,
        // this does NOT auto-collapse it back to Ready on its own.
        secondViewModel.setStagedAthlete(secondAthleteId, for: secondItem.externalEventKey)
        #expect(secondViewModel.readyToImportItems.isEmpty)

        // A bulk import at this point (before explicit reconfirmation)
        // must skip this still-unconfirmed item entirely.
        secondViewModel.bulkImportReadyItems()
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
            .first { $0.externalSourceId == secondItem.externalEventKey } == nil)

        // Only once the Parent explicitly marks it Ready again does bulk
        // import act on the override.
        secondViewModel.markReady(for: secondItem.externalEventKey)
        #expect(secondViewModel.readyToImportItems.count == 1)
        secondViewModel.bulkImportReadyItems()

        let secondActivity = try #require(
            try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
                .first { $0.externalSourceId == secondItem.externalEventKey }
        )
        #expect(secondActivity.athleteId == secondAthleteId.rawValue)
    }

    // MARK: - 15: ignored events never resurface

    @Test("An ignored event remains ignored — it never appears as Ready or pending again, even after a fresh load()")
    @MainActor
    func ignoredEventNeverResurfacesAsReadyOrPending() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)

        viewModel.ignore(item)

        #expect(viewModel.reviewQueue.isEmpty)
        #expect(viewModel.needsReviewItems.isEmpty)
        #expect(viewModel.readyToImportItems.isEmpty)

        viewModel.load()
        #expect(viewModel.reviewQueue.isEmpty)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
    }

    // MARK: - Runtime fix, item 1: Ignore never mutates until the confirmation-driven ignore(_:) call

    @Test("Item 1: nothing is persisted for a pending event until ignore(_:) is explicitly called — staging it, or merely having it selectable, never mutates anything")
    @MainActor
    func ignoreDoesNotMutateUntilExplicitlyCalled() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        // Merely being present, staged, or displayed never mutates —
        // only an explicit ignore(_:) call (itself only ever reached
        // through the View's own confirmation dialog) does.
        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
        #expect(viewModel.needsReviewItems.count == 1)

        viewModel.ignore(item)

        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).count == 1)
    }

    // MARK: - Runtime fix, items 3, 4: ignored events are excluded from Needs Review and appear in the Ignored section (current provider horizon)

    @Test("Item 3/4: an ignored event is excluded from needsReviewItems/readyToImportItems and instead appears in ignoredItems")
    @MainActor
    func ignoredEventExcludedFromReviewAndAppearsInIgnoredItems() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        #expect(viewModel.ignoredItems.isEmpty)

        viewModel.ignore(item)

        #expect(viewModel.needsReviewItems.isEmpty)
        #expect(viewModel.readyToImportItems.isEmpty)
        #expect(viewModel.ignoredItems.count == 1)
        #expect(viewModel.ignoredItems.first?.externalEventKey == item.externalEventKey)
    }

    // MARK: - Runtime fix, items 6, 7, 8: Review again restores exactly the ignored event, without creating Planning truth

    @Test("Item 6/7/8: restore(_:) removes the event from ignoredItems, creates no PlannedActivity, and the event naturally reappears in needsReviewItems")
    @MainActor
    func restoreReturnsIgnoredEventToNeedsReview() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        viewModel.ignore(item)
        #expect(viewModel.ignoredItems.count == 1)

        viewModel.restore(item)

        #expect(viewModel.ignoredItems.isEmpty)
        #expect(viewModel.needsReviewItems.count == 1)
        #expect(viewModel.needsReviewItems.first?.externalEventKey == item.externalEventKey)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
    }

    // MARK: - 16: disabled/disconnected source blocks bulk import of stale staged events

    @Test("A source disabled after events were staged Ready cannot bulk import them — the stale staged batch is rejected at the canonical boundary")
    @MainActor
    func disabledSourceCannotBulkImportStaleStagedEvents() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.readyToImportCount == 1)

        try fixture.coordinationService.setSourceEnabled(fixture.source.externalPlanningSourceId, isEnabled: false)

        viewModel.bulkImportReadyItems()

        #expect(viewModel.errorMessage != nil)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
        // A disabled source produces no review queue at all.
        #expect(viewModel.reviewQueue.isEmpty)
    }
}

private extension Date {
    func startOfWeekLocalDate(timeZoneId: TimeZoneId) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneId.timeZone ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: self)
        let localDate = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        return localDate.startOfWeek
    }
}
