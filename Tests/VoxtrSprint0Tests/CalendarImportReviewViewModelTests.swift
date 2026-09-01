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
        // remains, staged, and editable — but now (V1.3) surfaced in
        // Needs Attention rather than the plain Needs Review group, since
        // it carries a specific failure reason.
        #expect(viewModel.reviewQueue.count == 1)
        #expect(viewModel.reviewQueue.first?.externalEventKey == conflictItem.externalEventKey)
        // Required test 15/17/24: exactly one failed item is visible in
        // Needs Attention, mapped to the specific existingActivityConflict
        // reason (never a raw internal error dump).
        #expect(viewModel.needsAttentionItems.count == 1)
        #expect(viewModel.needsAttentionItems.first?.externalEventKey == conflictItem.externalEventKey)
        #expect(viewModel.needsReviewItems.isEmpty)
        #expect(viewModel.failedImportReasons[conflictItem.externalEventKey] == CalendarPlanningStrings.existingActivityConflictError)
        // Required test 18/19: staged classification is kept, un-confirmed.
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
        // Required test: re-confirming Ready moves it out of Needs
        // Attention presentation (into Ready to Import) even though the
        // stale failure marker has not been cleared yet by a new outcome.
        #expect(viewModel.needsAttentionItems.isEmpty)
        viewModel.bulkImportReadyItems()

        #expect(viewModel.errorMessage != nil)
        let activitiesAfterRetry = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activitiesAfterRetry.count == 2)
        #expect(viewModel.reviewQueue.first?.externalEventKey == conflictItem.externalEventKey)
        // Required test 22: retrying and failing again retains/updates the
        // failure state — still visible in Needs Attention.
        #expect(viewModel.needsAttentionItems.count == 1)
        #expect(viewModel.failedImportReasons[conflictItem.externalEventKey] == CalendarPlanningStrings.existingActivityConflictError)
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

    // MARK: - V1.2 Similar-Event Suggestions

    @Test("Required test 13/14: a similar (not identical) prior event PREFILLS Athlete/Sport/Activity Type but does NOT initialize isConfirmedReady, and creates no CalendarImportDecision or PlannedActivity by itself")
    @MainActor
    func similarSuggestionPrefillsButDoesNotConfirmReadyOrPersist() throws {
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

        // A SIMILAR, but NOT identical, later occurrence — a weekday
        // suffix is added, exactly the shape V1.2's own matcher accepts.
        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14 tirsdag", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        let staged = secondViewModel.stagedClassification(for: secondItem.externalEventKey)
        #expect(staged.athleteId == fixture.athleteId)
        #expect(staged.activityType == .teamTraining)
        // Required test 13: PREFILLED, but never auto-confirmed Ready —
        // weaker evidence than an exact match.
        #expect(staged.isConfirmedReady == false)
        #expect(staged.suggestionKind == .similarPreviousEvent(matchedTitle: "Hockeytrening U14"))
        #expect(secondViewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(secondViewModel.readyToImportItems.isEmpty)

        // Required test 14: still only ONE decision/activity total — the
        // suggestion itself created nothing.
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).count == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 1)
    }

    @Test("Required test 15: the Parent can override a similar suggestion's values, explicitly mark it Ready, and bulk import the override — not the suggested classification")
    @MainActor
    func parentCanOverrideSimilarSuggestionBeforeBulkImport() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.setStagedAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        firstViewModel.markReady(for: firstItem.externalEventKey)
        firstViewModel.bulkImportReadyItems()

        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14 tirsdag", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        #expect(secondViewModel.stagedClassification(for: secondItem.externalEventKey).athleteId == fixture.athleteId)
        #expect(secondViewModel.readyToImportItems.isEmpty) // still Needs Review, per item 13

        // Parent overrides the suggested Athlete to the sibling instead
        // — this also clears the suggestion label (see `updateStaged`'s
        // own doc comment) and, as always, requires an explicit Ready.
        secondViewModel.setStagedAthlete(secondAthleteId, for: secondItem.externalEventKey)
        #expect(secondViewModel.stagedClassification(for: secondItem.externalEventKey).suggestionKind == .none)
        secondViewModel.markReady(for: secondItem.externalEventKey)
        #expect(secondViewModel.readyToImportItems.count == 1)

        secondViewModel.bulkImportReadyItems()

        let secondActivity = try #require(
            try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
                .first { $0.externalSourceId == secondItem.externalEventKey }
        )
        #expect(secondActivity.athleteId == secondAthleteId.rawValue)
    }

    @Test("Required test 2: an exact remembered match takes precedence over an available similar-event suggestion for the SAME event")
    @MainActor
    func exactMatchTakesPrecedenceOverSimilarSuggestion() throws {
        let fixture = try makeFixture()
        let otherAthleteId = try addSecondAthlete(fixture)

        // Exact history: "Hockeytrening U14" -> fixture.athleteId.
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.setStagedAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        firstViewModel.markReady(for: firstItem.externalEventKey)
        firstViewModel.bulkImportReadyItems()

        // A DIFFERENT, merely-similar historical title -> a DIFFERENT
        // athlete. In isolation this would satisfy V1.2's own similarity
        // rule against "Hockeytrening U14" (every token of the shorter
        // title present in the longer one).
        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14 Lag B", hoursFromReference: 24)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        secondViewModel.setStagedAthlete(otherAthleteId, for: secondItem.externalEventKey)
        secondViewModel.markReady(for: secondItem.externalEventKey)
        secondViewModel.bulkImportReadyItems()

        // A THIRD event with the EXACT same normalized title as the
        // first import must be classified from the EXACT match
        // (fixture.athleteId), never from the merely-similar history's
        // own (different) athlete.
        addEvent(fixture, identifier: "evt-3", title: "Hockeytrening U14", hoursFromReference: 48)
        let thirdViewModel = makeViewModel(fixture)
        thirdViewModel.load()
        let thirdItem = try #require(thirdViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-3" })

        let staged = thirdViewModel.stagedClassification(for: thirdItem.externalEventKey)
        #expect(staged.athleteId == fixture.athleteId)
        #expect(staged.isConfirmedReady == true)
        #expect(staged.suggestionKind == .exactRemembered)
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

    // MARK: - Action fix: Ready/Ignore are fully independent per-event ViewModel operations
    //
    // The actual TestFlight-reported bug (Ready sometimes opening the
    // Ignore confirmation) was a SwiftUI List row hit-testing issue —
    // see CalendarImportReviewView.NeedsReviewRow's own doc comment for
    // the structural fix (`.buttonStyle(.borderless)`). That specific
    // symptom lived entirely in View-owned state (`itemPendingIgnore`
    // is `@State` private to `CalendarImportReviewView`; `isDetailsExpanded`
    // is `@State` private to `NeedsReviewRow`) and SwiftUI row tap-target
    // ownership, neither of which this repository's Swift Testing suite
    // can exercise (no SwiftUI rendering harness — see this file's own
    // top-of-file note). What CAN be verified at this layer, and is
    // verified below, is the underlying ViewModel contract each button's
    // action closure actually calls into: `markReady(for:)` and
    // `ignore(_:)` are fully independent per-event operations with no
    // shared mutable state — so even if two sibling buttons' tap targets
    // were ever misattributed again, the two actions could never corrupt
    // each other's outcome for a DIFFERENT event, and neither one has any
    // code path into the other's persisted/staged effect.
    //
    // Action fix required test 2 (Ignore request invokes only Ignore
    // confirmation state) and required test 5 (Details expansion does
    // not mutate Ready/Ignore state) are verified by direct code reading
    // rather than a test here, since both are pure View `@State` with no
    // ViewModel call at all: `onIgnoreRequested` in `NeedsReviewRow`
    // only invokes the closure that sets `itemPendingIgnore` on the
    // parent View — it never calls `markReady(for:)`, `ignore(_:)`, or
    // any other ViewModel method; and `DisclosureGroup`'s `isExpanded`
    // binds only to `NeedsReviewRow`'s own local `isDetailsExpanded`,
    // which no ViewModel method reads or writes.

    @Test("Action fix required tests 1, 3, 4, 6: markReady(for:) and ignore(_:) are fully independent per-event operations — marking one event Ready never persists a decision or touches a different event's Ignored state, and ignoring one event never touches a different event's staged Ready confirmation; picker changes alone never trigger either")
    @MainActor
    func readyAndIgnoreActionsAreFullyIndependentPerEvent() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-a", title: "Team Practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-b", title: "Swim Session", hoursFromReference: 2)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.externalEventKey.contains("evt-a") })
        let itemB = try #require(viewModel.reviewQueue.first { $0.externalEventKey.contains("evt-b") })

        // Required test 6: staging via the Athlete picker alone (the
        // same setter every Picker's Binding.set calls) never triggers
        // Ready or Ignore for either event.
        viewModel.setStagedAthlete(fixture.athleteId, for: itemA.externalEventKey)
        #expect(viewModel.readyToImportItems.isEmpty)
        #expect(viewModel.ignoredItems.isEmpty)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)

        // Required test 1: markReady(for:) invokes only the staged-
        // confirmation mutation for THAT event — no CalendarImportDecision
        // is persisted, and the Ignored section stays empty.
        viewModel.markReady(for: itemA.externalEventKey)
        #expect(viewModel.readyToImportItems.count == 1)
        #expect(viewModel.readyToImportItems.first?.externalEventKey == itemA.externalEventKey)
        #expect(viewModel.readyToImportCount == 1) // required test 7's gating condition
        #expect(viewModel.ignoredItems.isEmpty)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)

        // Required test 4: ignoring a DIFFERENT event never marks the
        // first event Ready (it already was, from the explicit action
        // above) and never un-marks it either — the two events' staged
        // state is fully isolated.
        viewModel.ignore(itemB)
        #expect(viewModel.ignoredItems.count == 1)
        #expect(viewModel.ignoredItems.first?.externalEventKey == itemB.externalEventKey)
        #expect(viewModel.readyToImportItems.count == 1)
        #expect(viewModel.readyToImportItems.first?.externalEventKey == itemA.externalEventKey)
        #expect(viewModel.stagedClassification(for: itemA.externalEventKey).isConfirmedReady == true)
        #expect(viewModel.needsReviewItems.isEmpty)
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

    // MARK: - V1.3 Suggested Ignore

    @Test("Required test 1/9/10: an exact-title match to a prior explicit Ignore becomes Suggested Ignore — never in Needs Review, never persisted, never a PlannedActivity")
    @MainActor
    func exactTitleMatchToPriorIgnoreBecomesSuggestedIgnore() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        #expect(secondViewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(secondViewModel.suggestedIgnoreMatches[secondItem.externalEventKey] == "Team Practice")
        #expect(!secondViewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(secondViewModel.stagedClassification(for: secondItem.externalEventKey).athleteId == nil)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).count == 1) // only the original Ignore
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
    }

    @Test("Required test 2: a conservative similar (not identical) title to a prior explicit Ignore also produces Suggested Ignore")
    @MainActor
    func similarTitleMatchToPriorIgnoreBecomesSuggestedIgnore() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14 tirsdag", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        #expect(secondViewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(secondViewModel.suggestedIgnoreMatches[secondItem.externalEventKey] == "Hockeytrening U14")
    }

    @Test("Required test 3: an unrelated title never produces Suggested Ignore, regardless of prior Ignore history")
    @MainActor
    func unrelatedTitleDoesNotProduceSuggestedIgnore() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Piano Lesson", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        #expect(secondViewModel.suggestedIgnoreItems.isEmpty)
        #expect(secondViewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
    }

    @Test("Required test 4: a training-vs-match conflict remains rejected by the shared similarity matcher, so it produces no Suggested Ignore")
    @MainActor
    func trainingVersusMatchConflictProducesNoSuggestedIgnore() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Hockeykamp U14", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        #expect(secondViewModel.suggestedIgnoreItems.isEmpty)
        #expect(secondViewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
    }

    @Test("Required test 5: prior Ignore evidence on a DIFFERENT ExternalPlanningSource never produces Suggested Ignore")
    @MainActor
    func ignoreEvidenceFromAnotherSourceDoesNotApply() throws {
        let fixture = try makeFixture()
        let sourceB = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-b", displayName: "Calendar B"
        )
        try fixture.coordinationService.setSourceEnabled(sourceB.externalPlanningSourceId, isEnabled: true)

        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let sourceAViewModel = makeViewModel(fixture)
        sourceAViewModel.load()
        let sourceAItem = try #require(sourceAViewModel.reviewQueue.first)
        sourceAViewModel.ignore(sourceAItem)

        var eventsForB = fixture.calendarProvider.eventsByCalendar["cal-b"] ?? []
        eventsForB.append(
            ExternalCalendarEvent(
                eventIdentifier: "evt-b-1", calendarIdentifier: "cal-b", title: "Team Practice",
                startDate: Self.referenceDate.addingTimeInterval(3600), endDate: Self.referenceDate.addingTimeInterval(7200),
                isAllDay: false, isRecurring: false
            )
        )
        fixture.calendarProvider.eventsByCalendar["cal-b"] = eventsForB
        let sourceBViewModel = CalendarImportReviewViewModel(
            calendarPlanningCoordinationService: fixture.coordinationService,
            athleteRepository: fixture.athleteRepository, sportRepository: fixture.sportRepository, source: sourceB, actorId: ActorId()
        )
        sourceBViewModel.load()
        let sourceBItem = try #require(sourceBViewModel.reviewQueue.first)

        #expect(sourceBViewModel.suggestedIgnoreItems.isEmpty)
        #expect(sourceBViewModel.needsReviewItems.map(\.externalEventKey).contains(sourceBItem.externalEventKey))
    }

    @Test("Required test 7: an IMPORTED (not ignored) prior event never becomes Suggested Ignore evidence — a similar new event gets a classification suggestion instead")
    @MainActor
    func importedHistoryNeverBecomesIgnoreEvidence() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.setStagedAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        firstViewModel.markReady(for: firstItem.externalEventKey)
        firstViewModel.bulkImportReadyItems()

        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14 tirsdag", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        #expect(secondViewModel.suggestedIgnoreItems.isEmpty)
        #expect(secondViewModel.stagedClassification(for: secondItem.externalEventKey).athleteId == fixture.athleteId)
    }

    @Test("Required test 8: merely staged (never ignored) state never becomes Suggested Ignore evidence for a different event")
    @MainActor
    func stagedButUndecidedEventNeverBecomesIgnoreEvidence() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14 tirsdag", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let firstItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-1" })
        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        // Stage (but never Ignore or import) the first event.
        viewModel.setStagedAthlete(fixture.athleteId, for: firstItem.externalEventKey)

        #expect(viewModel.suggestedIgnoreItems.isEmpty)
        #expect(viewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
    }

    @Test("Required test 11/12/13: reviewSuggestedIgnore(_:) moves the event to Needs Review, persists nothing, and the same suggestion does not reappear this session")
    @MainActor
    func reviewSuggestedIgnoreLiftsEventToReviewWithoutPersistingAndDoesNotReapply() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        #expect(secondViewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))

        secondViewModel.reviewSuggestedIgnore(secondItem)

        // Required test 11/12: moved to Needs Review, nothing persisted
        // beyond the original single Ignore decision.
        #expect(secondViewModel.suggestedIgnoreItems.isEmpty)
        #expect(secondViewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).count == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)

        // Required test 13: a later refresh in the SAME ViewModel/session
        // (e.g. the Parent reloading the screen) must not immediately
        // re-suggest Ignore for this exact event — `liftedToReviewKeys`
        // is instance state that survives repeated refreshes.
        secondViewModel.load()
        #expect(!secondViewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(secondViewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
    }

    @Test("Required test 14: explicit Ignore from a Suggested Ignore item uses the SAME canonical ignore(_:) path — exactly one .ignored decision results")
    @MainActor
    func explicitIgnoreFromSuggestedIgnoreUsesCanonicalPath() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        #expect(secondViewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))

        secondViewModel.ignore(secondItem)

        #expect(secondViewModel.suggestedIgnoreItems.isEmpty)
        #expect(secondViewModel.ignoredItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        let decisions = try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId)
        #expect(decisions.count == 2)
        #expect(decisions.allSatisfy { $0.status == .ignored })
    }

    // MARK: - V1.3 Needs Attention

    @Test("Required test 20: changing a staged picker after a bulk-import failure clears that event's failure state")
    @MainActor
    func changingPickerAfterFailureClearsFailureState() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Will Conflict", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let conflictItem = try #require(viewModel.reviewQueue.first)

        let today = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: secondAthleteId, weekStart: today)
        _ = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: secondAthleteId, activityType: .individualTraining,
            title: "Will Conflict", localDate: today, timeZoneId: Self.timeZoneId,
            externalSourceId: conflictItem.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        viewModel.setStagedAthlete(fixture.athleteId, for: conflictItem.externalEventKey)
        viewModel.markReady(for: conflictItem.externalEventKey)
        viewModel.bulkImportReadyItems()
        #expect(viewModel.needsAttentionItems.count == 1)
        #expect(viewModel.failedImportReasons[conflictItem.externalEventKey] != nil)

        // Parent changes Activity Type (any staged value change) — must
        // clear the stale failure marker immediately, before any retry.
        viewModel.setStagedActivityType(.teamTraining, for: conflictItem.externalEventKey)

        #expect(viewModel.failedImportReasons[conflictItem.externalEventKey] == nil)
        #expect(viewModel.needsAttentionItems.isEmpty)
        #expect(viewModel.needsReviewItems.map(\.externalEventKey).contains(conflictItem.externalEventKey))
    }

    @Test("Required test 21: a successful retry after a bulk-import failure removes the failure state entirely")
    @MainActor
    func successfulRetryRemovesFailureState() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Will Conflict", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let conflictItem = try #require(viewModel.reviewQueue.first)

        let today = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: secondAthleteId, weekStart: today)
        _ = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: secondAthleteId, activityType: .individualTraining,
            title: "Will Conflict", localDate: today, timeZoneId: Self.timeZoneId,
            externalSourceId: conflictItem.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        viewModel.setStagedAthlete(fixture.athleteId, for: conflictItem.externalEventKey)
        viewModel.markReady(for: conflictItem.externalEventKey)
        viewModel.bulkImportReadyItems()
        #expect(viewModel.needsAttentionItems.count == 1)

        // Parent re-classifies to the athlete the legacy activity ACTUALLY
        // belongs to (so the retry legitimately succeeds this time via
        // Blocker 4's own adoption path) and retries.
        viewModel.setStagedAthlete(secondAthleteId, for: conflictItem.externalEventKey)
        viewModel.markReady(for: conflictItem.externalEventKey)
        viewModel.bulkImportReadyItems()

        #expect(viewModel.needsAttentionItems.isEmpty)
        #expect(viewModel.failedImportReasons.isEmpty)
        #expect(viewModel.reviewQueue.isEmpty)
    }

    @Test("Required test 23: the aggregate partial-result summary uses the 'N imported. M need attention.' wording")
    @MainActor
    func aggregatePartialResultUsesNeedAttentionWording() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Will Succeed", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Will Conflict", hoursFromReference: 2)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let succeedItem = try #require(viewModel.reviewQueue.first { $0.event.title == "Will Succeed" })
        let conflictItem = try #require(viewModel.reviewQueue.first { $0.event.title == "Will Conflict" })
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

        viewModel.bulkImportReadyItems()

        #expect(viewModel.errorMessage == CalendarPlanningStrings.bulkImportPartialResult(imported: 1, failed: 1))
        #expect(viewModel.errorMessage == "1 imported. 1 need attention.")
    }

    @Test("Required test 25/26: an unexpected (unmapped) failure is surfaced with the generic safe reason, and no failure state is ever persisted")
    @MainActor
    func unexpectedFailureUsesGenericReasonAndPersistsNothing() throws {
        let fixture = try makeFixture()
        let otherWorkspaceId = WorkspaceId()
        let foreignAthleteId = try addSecondAthlete(fixture, name: "Foreign", workspaceId: otherWorkspaceId)
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        // Directly stage an athlete from a DIFFERENT workspace than the
        // source — the UI's own picker never offers this, but this
        // proves the generic-fallback mapping for an error this screen
        // does not specifically name (athleteOutsideSourceWorkspace).
        viewModel.setStagedAthlete(foreignAthleteId, for: item.externalEventKey)
        viewModel.markReady(for: item.externalEventKey)

        viewModel.bulkImportReadyItems()

        #expect(viewModel.needsAttentionItems.count == 1)
        #expect(viewModel.failedImportReasons[item.externalEventKey] == CalendarPlanningStrings.bulkImportGenericItemError)
        // Required test 26: transient only — nothing new persisted beyond
        // the (still-empty) decision/activity truth.
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
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
