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
        /// Runtime follow-up (evidence backward compatibility): exposed
        /// so a test can directly construct historical-shape evidence
        /// (e.g. children carrying DIFFERENT athleteIds, as pre-this-
        /// round evidence legitimately could) without going through
        /// classifyAndImportSplit, which would never itself produce that
        /// shape anymore.
        let decompositionEvidenceRepository: DecompositionEvidenceRepository
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
        let decomposedActivityLinkRepository = DecomposedActivityLinkRepository(modelContext: container.mainContext)
        let decompositionEvidenceRepository = DecompositionEvidenceRepository(modelContext: container.mainContext)
        let sportRepository = SportRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let calendarProvider = FakeCalendarEventProvider()
        let coordinationService = CalendarPlanningCoordinationService(
            sourceRepository: sourceRepository,
            importDecisionRepository: importDecisionRepository,
            legacyMappingRepository: legacyMappingRepository,
            decomposedActivityLinkRepository: decomposedActivityLinkRepository,
            decompositionEvidenceRepository: decompositionEvidenceRepository,
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
            decompositionEvidenceRepository: decompositionEvidenceRepository,
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

    // MARK: - PR #48 follow-up (durable Suggested Ignore evidence)

    @Test("Required test 2: after the original ignored event no longer appears in the provider (aged out of the reconciliation horizon), a NEW event with the exact same title still becomes Suggested Ignore")
    @MainActor
    func exactTitleSuggestedIgnoreSurvivesProviderHorizonExpiry() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        // The original ignored occurrence ages entirely out of the
        // provider's own reconciliation window — e.g. EventKit simply
        // stops returning it. Before this round's durable evidence, this
        // alone would have silently broken Suggested Ignore for every
        // future occurrence of the same repeating event.
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = []

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        #expect(secondViewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(secondViewModel.suggestedIgnoreMatches[secondItem.externalEventKey] == "Team Practice")
        // The Ignored section itself (horizon-bound, unchanged) no
        // longer shows the original occurrence — proving this
        // suggestion came from durable decision history, not from
        // `ignoredItems`.
        #expect(secondViewModel.ignoredItems.isEmpty)
    }

    @Test("Required test 3: after the original ignored event ages out of the provider horizon, a conservatively similar (not identical) title still becomes Suggested Ignore")
    @MainActor
    func similarTitleSuggestedIgnoreSurvivesProviderHorizonExpiry() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        fixture.calendarProvider.eventsByCalendar["cal-familie"] = []

        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14 tirsdag", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        #expect(secondViewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(secondViewModel.suggestedIgnoreMatches[secondItem.externalEventKey] == "Hockeytrening U14")
    }

    @Test("Required test 5: prior Ignore evidence in a DIFFERENT workspace's source never produces Suggested Ignore, even for an identically-titled event")
    @MainActor
    func ignoreEvidenceFromAnotherWorkspaceDoesNotApply() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        // A completely different family/workspace, with its own source
        // and its own independent occurrence of an identically-titled
        // event.
        let otherWorkspaceId = WorkspaceId()
        let otherSource = try fixture.coordinationService.createSource(
            forWorkspace: otherWorkspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-other-familie", displayName: "Other Familie"
        )
        try fixture.coordinationService.setSourceEnabled(otherSource.externalPlanningSourceId, isEnabled: true)
        fixture.calendarProvider.eventsByCalendar["cal-other-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-other-1", calendarIdentifier: "cal-other-familie", title: "Team Practice",
                startDate: Self.referenceDate.addingTimeInterval(3600), endDate: Self.referenceDate.addingTimeInterval(7200),
                isAllDay: false, isRecurring: false
            )
        ]
        let otherViewModel = CalendarImportReviewViewModel(
            calendarPlanningCoordinationService: fixture.coordinationService,
            athleteRepository: fixture.athleteRepository, sportRepository: fixture.sportRepository, source: otherSource, actorId: ActorId()
        )
        otherViewModel.load()
        let otherItem = try #require(otherViewModel.reviewQueue.first)

        #expect(otherViewModel.suggestedIgnoreItems.isEmpty)
        #expect(otherViewModel.needsReviewItems.map(\.externalEventKey).contains(otherItem.externalEventKey))
    }

    @Test("Required test 7: restoring (\"Review again\") the original ignored decision removes its durable evidence too — a later identically-titled event no longer becomes Suggested Ignore")
    @MainActor
    func restoringIgnoredDecisionRemovesDurableEvidence() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        try fixture.coordinationService.restoreIgnoredEvent(firstItem.externalEventKey, for: fixture.source)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        #expect(secondViewModel.suggestedIgnoreItems.isEmpty)
        #expect(secondViewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
    }

    @Test("Required test 11: the actual Ignored section (ignoredItems) stays horizon-bound and unchanged by durable Suggested Ignore evidence — it never retroactively includes a decision whose event has aged out")
    @MainActor
    func ignoredSectionStaysHorizonBoundAfterDurableEvidenceChange() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        viewModel.ignore(item)
        viewModel.load()
        #expect(viewModel.ignoredItems.map(\.externalEventKey).contains(item.externalEventKey))

        fixture.calendarProvider.eventsByCalendar["cal-familie"] = []
        viewModel.load()

        #expect(viewModel.ignoredItems.isEmpty)
    }

    @Test("Required test 12: an exact remembered classification for a title takes precedence over Suggested Ignore evidence for the SAME normalized title")
    @MainActor
    func classificationPrecedesSuggestedIgnoreForSameTitle() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.setStagedAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        firstViewModel.markReady(for: firstItem.externalEventKey)
        firstViewModel.bulkImportReadyItems()

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 24)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        secondViewModel.ignore(secondItem)

        addEvent(fixture, identifier: "evt-3", title: "Team Practice", hoursFromReference: 48)
        let thirdViewModel = makeViewModel(fixture)
        thirdViewModel.load()
        let thirdItem = try #require(thirdViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-3" })

        #expect(thirdViewModel.stagedClassification(for: thirdItem.externalEventKey).athleteId == fixture.athleteId)
        #expect(thirdViewModel.stagedClassification(for: thirdItem.externalEventKey).isConfirmedReady == true)
        #expect(!thirdViewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(thirdItem.externalEventKey))
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

    @Test("Required test 5: a source disabled before a single-row explicit Ignore creates no CalendarImportDecision, and surfaces the SAME calm sourceDisabledError copy restore(_:) already uses — never a generic fallback")
    @MainActor
    func singleRowIgnoreSurfacesSourceDisabledCalmlyAndPersistsNothing() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        try fixture.coordinationService.setSourceEnabled(fixture.source.externalPlanningSourceId, isEnabled: false)

        viewModel.ignore(item)

        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
        #expect(viewModel.errorMessage == CalendarPlanningStrings.sourceDisabledError)
    }

    // MARK: - Live Suggested Ignore re-evaluation

    @Test("Required test 1: initial load — two untouched pending identical-title events are both in Needs Review")
    @MainActor
    func initialLoadTwoIdenticalTitledEventsBothInNeedsReview() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()

        #expect(viewModel.needsReviewItems.count == 2)
        #expect(viewModel.suggestedIgnoreItems.isEmpty)
    }

    @Test("Required test 2: in the SAME ViewModel, explicitly Ignoring one event immediately moves the untouched identical-title sibling into Suggested Ignore — no new ViewModel, no re-entry")
    @MainActor
    func liveRefreshMovesIdenticalTitledSiblingToSuggestedIgnoreWithoutNewViewModel() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let firstItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-1" })
        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        // Root cause regression guard: BEFORE the fix, evt-2 already
        // received a default StagedClassification() on the load() above,
        // which the old short-circuit would have frozen forever.
        viewModel.ignore(firstItem)

        #expect(viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(!viewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
    }

    @Test("Required test 3: a conservatively similar (not identical) untouched title also moves live to Suggested Ignore in the SAME ViewModel session")
    @MainActor
    func liveRefreshMovesSimilarTitledSiblingToSuggestedIgnoreWithoutNewViewModel() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14 tirsdag", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let firstItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-1" })
        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        viewModel.ignore(firstItem)

        #expect(viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(viewModel.suggestedIgnoreMatches[secondItem.externalEventKey] == "Hockeytrening U14")
    }

    @Test("Required test 4: a Parent-edited Athlete on the sibling event is preserved after the other event is explicitly Ignored")
    @MainActor
    func liveRefreshPreservesParentEditedAthleteAfterSiblingIgnore() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let firstItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-1" })
        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        viewModel.setStagedAthlete(fixture.athleteId, for: secondItem.externalEventKey)
        viewModel.ignore(firstItem)

        #expect(!viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(viewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(viewModel.stagedClassification(for: secondItem.externalEventKey).athleteId == fixture.athleteId)
    }

    @Test("Required test 5: a Parent-edited Sport on the sibling event is preserved after the other event is explicitly Ignored")
    @MainActor
    func liveRefreshPreservesParentEditedSportAfterSiblingIgnore() throws {
        let fixture = try makeFixture()
        let seededSports = try fixture.sportRepository.seedCanonicalSportsIfNeeded()
        let sport = try #require(seededSports.first)
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let firstItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-1" })
        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        viewModel.setStagedSport(sport.sportId, for: secondItem.externalEventKey)
        viewModel.ignore(firstItem)

        #expect(!viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(viewModel.stagedClassification(for: secondItem.externalEventKey).sportId == sport.sportId)
    }

    @Test("Required test 6: a Parent-edited Activity Type on the sibling event is preserved after the other event is explicitly Ignored")
    @MainActor
    func liveRefreshPreservesParentEditedActivityTypeAfterSiblingIgnore() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let firstItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-1" })
        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        viewModel.setStagedActivityType(.teamTraining, for: secondItem.externalEventKey)
        viewModel.ignore(firstItem)

        #expect(!viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(viewModel.stagedClassification(for: secondItem.externalEventKey).activityType == .teamTraining)
    }

    @Test("Required test 7: a Ready matching sibling event remains Ready after the other event is explicitly Ignored")
    @MainActor
    func liveRefreshPreservesReadyEventAfterSiblingIgnore() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let firstItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-1" })
        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        viewModel.setStagedAthlete(fixture.athleteId, for: secondItem.externalEventKey)
        viewModel.markReady(for: secondItem.externalEventKey)
        #expect(viewModel.readyToImportItems.map(\.externalEventKey).contains(secondItem.externalEventKey))

        viewModel.ignore(firstItem)

        #expect(viewModel.readyToImportItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(!viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
    }

    @Test("Required test 8: an exact/similar PR #47 classification suggestion is preserved (stays a classification suggestion, never becomes Suggested Ignore) after an UNRELATED sibling event is explicitly Ignored")
    @MainActor
    func liveRefreshPreservesClassificationSuggestionAfterUnrelatedSiblingIgnore() throws {
        let fixture = try makeFixture()
        // Establish classification evidence via an imported event.
        addEvent(fixture, identifier: "evt-imported", title: "Hockeytrening U14", hoursFromReference: 1)
        let importViewModel = makeViewModel(fixture)
        importViewModel.load()
        let importItem = try #require(importViewModel.reviewQueue.first)
        importViewModel.setStagedAthlete(fixture.athleteId, for: importItem.externalEventKey)
        importViewModel.markReady(for: importItem.externalEventKey)
        importViewModel.bulkImportReadyItems()

        // A similar-titled event that PREFILLS from that evidence, plus
        // an unrelated identical-title pair used purely to trigger a
        // live refresh via an unrelated explicit Ignore.
        addEvent(fixture, identifier: "evt-similar", title: "Hockeytrening U14 tirsdag", hoursFromReference: 24)
        addEvent(fixture, identifier: "evt-unrelated-1", title: "Piano Lesson", hoursFromReference: 25)
        addEvent(fixture, identifier: "evt-unrelated-2", title: "Piano Lesson", hoursFromReference: 26)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let similarItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-similar" })
        let unrelatedFirst = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-unrelated-1" })

        guard case .similarPreviousEvent = viewModel.stagedClassification(for: similarItem.externalEventKey).suggestionKind else {
            Issue.record("expected a similar-event classification suggestion before the unrelated refresh")
            return
        }

        viewModel.ignore(unrelatedFirst)

        guard case .similarPreviousEvent(let matchedTitle) = viewModel.stagedClassification(for: similarItem.externalEventKey).suggestionKind else {
            Issue.record("similar-event classification suggestion was lost after an unrelated sibling Ignore")
            return
        }
        #expect(matchedTitle == "Hockeytrening U14")
        #expect(!viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(similarItem.externalEventKey))
    }

    @Test("Required test 9: a Needs Attention item stays Needs Attention — an unrelated explicit Ignore never moves a failed-import item into Suggested Ignore")
    @MainActor
    func liveRefreshPreservesNeedsAttentionAfterUnrelatedSiblingIgnore() throws {
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

        // An unrelated identical-title pair whose Ignore must not disturb
        // the already-established Needs Attention state above.
        addEvent(fixture, identifier: "evt-unrelated-1", title: "Piano Lesson", hoursFromReference: 24)
        addEvent(fixture, identifier: "evt-unrelated-2", title: "Piano Lesson", hoursFromReference: 25)
        viewModel.load()
        let unrelatedFirst = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-unrelated-1" })

        viewModel.ignore(unrelatedFirst)

        #expect(viewModel.needsAttentionItems.map(\.externalEventKey).contains(conflictItem.externalEventKey))
        #expect(viewModel.failedImportReasons[conflictItem.externalEventKey] != nil)
        #expect(!viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(conflictItem.externalEventKey))
    }

    @Test("Required test 10: a Reviewed Suggested Ignore item stays in Needs Review in the current session after a SUBSEQUENT, unrelated Ignore triggers another refresh")
    @MainActor
    func reviewedSuggestedIgnoreStaysInNeedsReviewAfterSubsequentUnrelatedIgnore() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        #expect(viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))

        viewModel.reviewSuggestedIgnore(secondItem)
        #expect(viewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))

        // A subsequent, unrelated explicit Ignore in the SAME session
        // triggers another refresh — the reviewed item must not be
        // pushed back into Suggested Ignore.
        addEvent(fixture, identifier: "evt-3", title: "Piano Lesson", hoursFromReference: 49)
        addEvent(fixture, identifier: "evt-4", title: "Piano Lesson", hoursFromReference: 50)
        viewModel.load()
        let unrelatedFirst = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-3" })
        viewModel.ignore(unrelatedFirst)

        #expect(!viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(viewModel.needsReviewItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
    }

    @Test("Required test 11: a fresh ViewModel still derives Suggested Ignore from durable Ignore evidence (unaffected by the live-refresh fix)")
    @MainActor
    func freshViewModelStillDerivesSuggestedIgnoreFromDurableEvidence() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let freshViewModel = makeViewModel(fixture)
        freshViewModel.load()
        let secondItem = try #require(freshViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        #expect(freshViewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
    }

    // MARK: - Import-time Suggested Ignore confirmation

    @Test("Required test 12: Import with zero Suggested Ignore items preserves existing immediate bulk-import behavior exactly")
    @MainActor
    func importWithZeroSuggestedIgnorePreservesExistingBehavior() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.suggestedIgnoreItems.isEmpty)

        viewModel.bulkImportReadyItems()

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 1)
        #expect(viewModel.reviewQueue.isEmpty)
    }

    @Test("Required test 13/21: merely reaching a state with Suggested Ignore items present never itself imports or ignores anything without an explicit confirmed call")
    @MainActor
    func suggestedIgnorePresentNeverAutoImportsOrIgnoresWithoutConfirmation() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        #expect(!viewModel.suggestedIgnoreItems.isEmpty)

        // Neither bulkImportReadyItems() nor confirmSuggestedIgnoresAndImportReadyItems()
        // was called — only the ONE original manual Ignore decision must
        // exist, and no PlannedActivity was ever created.
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).count == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
    }

    @Test("Required test 14: 'Review first' (never calling the confirmed action) persists no new Ignore decision, imports no Ready item, and Suggested Ignore items remain visible")
    @MainActor
    func reviewFirstLeavesSuggestedIgnoreItemsUntouched() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        #expect(viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))

        // "Review first" is purely a View-side dialog dismissal — it
        // calls nothing on the ViewModel at all (see
        // CalendarImportReviewView's own confirmationDialog). Simulated
        // here by simply not calling either import method.

        #expect(viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(secondItem.externalEventKey))
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).count == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
    }

    @Test("Required tests 15/16/17/18/19/20: 'Ignore & Import' persists every current Suggested Ignore item as a real .ignored decision (correct title/actor/source/event identity, no PlannedActivity), then imports every Ready item")
    @MainActor
    func confirmedBatchIgnoresSuggestedItemsAndImportsReadyItems() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        addEvent(fixture, identifier: "evt-ready", title: "New Activity", hoursFromReference: 49)
        let actorId = ActorId()
        let viewModel = CalendarImportReviewViewModel(
            calendarPlanningCoordinationService: fixture.coordinationService,
            athleteRepository: fixture.athleteRepository, sportRepository: fixture.sportRepository,
            source: fixture.source, actorId: actorId
        )
        viewModel.load()
        let suggestedItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        let readyItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-ready" })
        #expect(viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(suggestedItem.externalEventKey))

        viewModel.setStagedAthlete(fixture.athleteId, for: readyItem.externalEventKey)
        viewModel.markReady(for: readyItem.externalEventKey)
        #expect(viewModel.readyToImportItems.map(\.externalEventKey).contains(readyItem.externalEventKey))

        viewModel.confirmSuggestedIgnoresAndImportReadyItems()

        // 15/16/17: a real .ignored decision, correct title/actor/source/
        // event identity.
        let ignoredDecision = try #require(
            try fixture.importDecisionRepository.fetch(sourceId: fixture.source.externalPlanningSourceId, externalEventKey: suggestedItem.externalEventKey)
        )
        #expect(ignoredDecision.status == .ignored)
        #expect(ignoredDecision.ignoredEventTitle == "Team Practice")
        #expect(ignoredDecision.decidedBy == actorId.rawValue)
        #expect(ignoredDecision.sourceId == fixture.source.id)
        #expect(ignoredDecision.externalEventKey == suggestedItem.externalEventKey)

        // 19: the Ready item imported.
        let importedActivities = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(importedActivities.count == 1)
        #expect(importedActivities.first?.externalSourceId == readyItem.externalEventKey)

        // 20: no PlannedActivity was ever created for the ignored event.
        #expect(!importedActivities.contains { $0.externalSourceId == suggestedItem.externalEventKey })

        // 18: the ignored event now shows up as an actual Ignored row
        // (still within the provider horizon), and no longer as
        // Suggested Ignore or pending.
        #expect(viewModel.ignoredItems.map(\.externalEventKey).contains(suggestedItem.externalEventKey))
        #expect(viewModel.suggestedIgnoreItems.isEmpty)
        #expect(viewModel.reviewQueue.isEmpty)
    }

    @Test("Required tests 24/26: a Ready item's own import failure in a confirmed batch does not roll back an already-succeeded Suggested Ignore sibling, and surfaces under Needs Attention exactly like any other bulk-import failure")
    @MainActor
    func confirmedBatchKeepsSuccessfulIgnoreWhenReadyImportPartiallyFails() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        addEvent(fixture, identifier: "evt-conflict", title: "Will Conflict", hoursFromReference: 49)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let suggestedItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        let conflictItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-conflict" })
        #expect(viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(suggestedItem.externalEventKey))

        // A genuine, existing PlannedActivity conflict for the Ready
        // item, so its import legitimately fails.
        let today = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: secondAthleteId, weekStart: today)
        _ = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: secondAthleteId, activityType: .individualTraining,
            title: "Will Conflict", localDate: today, timeZoneId: Self.timeZoneId,
            externalSourceId: conflictItem.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        viewModel.setStagedAthlete(fixture.athleteId, for: conflictItem.externalEventKey)
        viewModel.markReady(for: conflictItem.externalEventKey)

        viewModel.confirmSuggestedIgnoresAndImportReadyItems()

        // The successful Suggested Ignore still persisted, even though a
        // DIFFERENT item in the SAME confirmed batch failed to import.
        let ignoredDecision = try fixture.importDecisionRepository.fetch(
            sourceId: fixture.source.externalPlanningSourceId, externalEventKey: suggestedItem.externalEventKey
        )
        #expect(ignoredDecision?.status == .ignored)

        // The Ready item's failure surfaces as Needs Attention exactly
        // like any other bulkImportReadyItems() failure — never
        // fabricated success.
        #expect(viewModel.needsAttentionItems.map(\.externalEventKey).contains(conflictItem.externalEventKey))
        #expect(viewModel.errorMessage != nil)
    }

    @Test("Required test 4/25: a source ALREADY disabled before the Parent confirms creates ZERO new Ignore decisions, ZERO PlannedActivities, stops immediately, and surfaces sourceDisabled — never a silent partial-success claim")
    @MainActor
    func confirmedBatchWithSourceAlreadyDisabledCreatesNoNewDecisionsOrActivities() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)
        let decisionCountBeforeConfirmation = try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).count

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        addEvent(fixture, identifier: "evt-3", title: "Team Practice", hoursFromReference: 49)
        addEvent(fixture, identifier: "evt-ready", title: "New Activity", hoursFromReference: 50)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let readyItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-ready" })
        viewModel.setStagedAthlete(fixture.athleteId, for: readyItem.externalEventKey)
        viewModel.markReady(for: readyItem.externalEventKey)
        // Two Suggested Ignore candidates queued for the batch, so this
        // test also proves the loop stops at the FIRST one rather than
        // merely happening to have nothing to process.
        #expect(viewModel.suggestedIgnoreItems.count == 2)

        // Stale-screen case: the source was ALREADY disabled before the
        // Parent even tapped "Ignore & Import."
        try fixture.coordinationService.setSourceEnabled(fixture.source.externalPlanningSourceId, isEnabled: false)

        viewModel.confirmSuggestedIgnoresAndImportReadyItems()

        // ZERO new Ignore decisions — the canonical ignore(...) guard
        // (PR #49 follow-up) rejects the very first attempt, so the
        // batch never proceeds to a second item or to Ready import.
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).count == decisionCountBeforeConfirmation)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(viewModel.errorMessage == CalendarPlanningStrings.sourceDisabledError)
    }

    @Test("A confirmed batch with Suggested Ignore items but ZERO Ready items still refreshes state correctly — bulkImportReadyItems()'s own early return (nothing to import) must never leave the screen showing stale Suggested Ignore truth")
    @MainActor
    func confirmedBatchWithNoReadyItemsStillRefreshesSuggestedIgnoreTruth() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let suggestedItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        #expect(viewModel.suggestedIgnoreItems.map(\.externalEventKey).contains(suggestedItem.externalEventKey))
        #expect(viewModel.readyToImportCount == 0)

        viewModel.confirmSuggestedIgnoresAndImportReadyItems()

        #expect(viewModel.suggestedIgnoreItems.isEmpty)
        #expect(viewModel.reviewQueue.isEmpty)
        #expect(viewModel.ignoredItems.map(\.externalEventKey).contains(suggestedItem.externalEventKey))
        let ignoredDecision = try fixture.importDecisionRepository.fetch(
            sourceId: fixture.source.externalPlanningSourceId, externalEventKey: suggestedItem.externalEventKey
        )
        #expect(ignoredDecision?.status == .ignored)
    }

    // MARK: - PR #49 follow-up (zero-ready top action copy)

    @Test("Required test 8: Ready > 0, Suggested Ignore == 0 — topActionState carries the exact unchanged 'Import N' semantics")
    @MainActor
    func topActionStateWithOnlyReadyItemsUsesUnchangedImportSemantics() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.markReady(for: item.externalEventKey)

        #expect(viewModel.suggestedIgnoreItems.isEmpty)
        #expect(viewModel.topActionState == .readyToImport(readyCount: 1))
    }

    @Test("Required test 9: Ready > 0, Suggested Ignore > 0 — topActionState still reports 'Import N' (Ready import stays the primary action), and confirmation is still required by the View's own tap-routing logic")
    @MainActor
    func topActionStateWithReadyAndSuggestedIgnoreKeepsImportSemantics() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        addEvent(fixture, identifier: "evt-ready", title: "New Activity", hoursFromReference: 49)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let readyItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-ready" })
        viewModel.setStagedAthlete(fixture.athleteId, for: readyItem.externalEventKey)
        viewModel.markReady(for: readyItem.externalEventKey)

        #expect(!viewModel.suggestedIgnoreItems.isEmpty)
        // Still "Import 1" — importing Ready activities remains the
        // primary completion action even with Suggested Ignore items
        // present; the confirmation dialog itself explains the
        // additional Ignore decision (see CalendarImportReviewView's own
        // top-level button action, which still routes through
        // isSuggestedIgnoreConfirmationPresented whenever
        // suggestedIgnoreItems is non-empty).
        #expect(viewModel.topActionState == .readyToImport(readyCount: 1))
    }

    @Test("Required test 10: Ready == 0, Suggested Ignore > 0 — topActionState is suggestedIgnoreOnly (never 'Import 0'), with contextual copy and the same confirmation path")
    @MainActor
    func topActionStateWithOnlySuggestedIgnoreAvoidsImportZeroCopy() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.ignore(firstItem)

        addEvent(fixture, identifier: "evt-2", title: "Team Practice", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()

        #expect(viewModel.readyToImportCount == 0)
        #expect(viewModel.suggestedIgnoreItems.count == 1)
        #expect(viewModel.topActionState == .suggestedIgnoreOnly(count: 1))

        // The derived copy never mentions "Import 0" and is calm,
        // contextual text instead.
        let summary = CalendarPlanningStrings.suggestedIgnoreOnlySummary(count: 1)
        let button = CalendarPlanningStrings.suggestedIgnoreOnlyButton(count: 1)
        #expect(!summary.localizedCaseInsensitiveContains("import 0"))
        #expect(!button.localizedCaseInsensitiveContains("import 0"))
        #expect(button.contains("1"))
    }

    /// Lead Review follow-up (split semantics — minimum two children):
    /// a split-enabled row is never Ready until at least 2 valid
    /// children exist, even though the Parent may toggle Split on with
    /// exactly one editable child and edit it freely — proves
    /// `StagedClassification.splitChildrenAreValid`/
    /// `satisfiesMinimumImportRequirements` and `markReady`'s own no-op
    /// guard compose correctly, mirroring
    /// `CalendarPlanningCoordinationService`'s own
    /// `.splitRequiresAtLeastTwoChildren` guard.
    @Test("VX-038 Lead Review follow-up: a split with only one child never becomes Ready; a second valid child is required")
    @MainActor
    func splitWithOnlyOneChildNeverBecomesReady() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        // Toggling Split on starts with exactly ONE editable child —
        // never auto-created as a second classified child.
        #expect(viewModel.stagedClassification(for: item.externalEventKey).splitChildren.count == 1)
        viewModel.setSplitAthlete(fixture.athleteId, for: item.externalEventKey)
        #expect(!viewModel.stagedClassification(for: item.externalEventKey).splitChildrenAreValid)
        #expect(!viewModel.stagedClassification(for: item.externalEventKey).satisfiesMinimumImportRequirements)

        // markReady is a no-op with only one child, even with the shared
        // Athlete already set.
        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.isEmpty)
        #expect(viewModel.needsReviewItems.count == 1)

        // Adding a second, valid child (Activity Type/timing only —
        // runtime follow-up: shared Athlete/Sport) makes it eligible for
        // Ready.
        viewModel.addSplitChild(for: item.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { child in
            child.startOffsetMinutes = 70
            child.durationMinutes = 60
        }
        #expect(viewModel.stagedClassification(for: item.externalEventKey).splitChildrenAreValid)
        #expect(viewModel.stagedClassification(for: item.externalEventKey).satisfiesMinimumImportRequirements)

        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.count == 1)
        #expect(viewModel.needsReviewItems.isEmpty)
    }

    /// Runtime follow-up (split UX — shared Athlete/Sport), test
    /// requirement 5: two valid children are NOT enough on their own —
    /// the ONE shared `splitAthleteId` is required before a split can
    /// become Ready, mirroring the ordinary path's own `athleteId != nil`
    /// requirement.
    @Test("Runtime follow-up: a split with two valid children but no shared Athlete never becomes Ready")
    @MainActor
    func splitWithTwoChildrenButNoSharedAthleteNeverBecomesReady() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { child in
            child.startOffsetMinutes = 70
            child.durationMinutes = 60
        }
        #expect(viewModel.stagedClassification(for: item.externalEventKey).splitChildrenAreValid)
        #expect(viewModel.stagedClassification(for: item.externalEventKey).splitAthleteId == nil)
        #expect(!viewModel.stagedClassification(for: item.externalEventKey).satisfiesMinimumImportRequirements)

        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.isEmpty)
        #expect(viewModel.needsReviewItems.count == 1)

        viewModel.setSplitAthlete(fixture.athleteId, for: item.externalEventKey)
        #expect(viewModel.stagedClassification(for: item.externalEventKey).satisfiesMinimumImportRequirements)
        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.count == 1)
    }

    /// Runtime follow-up (split UX — shared Athlete/Sport), test
    /// requirement 3: `bulkImportReadyItems()` expands the ONE shared
    /// `splitAthleteId`/`splitSportId` into EVERY imported child at the
    /// service boundary — the service's own `DecomposedChildInput` stays
    /// fully explicit per child, never weakened.
    @Test("Runtime follow-up: bulk import expands the shared Athlete/Sport into every split child")
    @MainActor
    func bulkImportExpandsSharedAthleteSportIntoEveryChild() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        // Sport left nil (legitimately optional, same as the ordinary
        // path's own sportId) — still proves the shared value is
        // expanded uniformly into every child, not just the first.
        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        let firstChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[0].id
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(firstChildId, for: item.externalEventKey) { child in
            child.activityType = .individualTraining
            child.startOffsetMinutes = 0
            child.durationMinutes = 40
        }
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { child in
            child.activityType = .teamTraining
            child.startOffsetMinutes = 70
            child.durationMinutes = 60
        }
        viewModel.markReady(for: item.externalEventKey)

        viewModel.bulkImportReadyItems()

        let imported = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.athleteId == fixture.athleteId.rawValue })
        #expect(imported.allSatisfy { $0.sportId == nil })
        #expect(Set(imported.map(\.plannedDurationMinutes)) == [40, 60])
    }

    /// Runtime follow-up (evidence backward compatibility), test
    /// requirement 6: historical evidence whose children all agree on
    /// athleteId/sportId loads correctly into the new shared-context
    /// staging — proven with evidence written DIRECTLY through the
    /// repository (not `classifyAndImportSplit`), so this proves the
    /// READ side works independently of how the evidence was produced.
    @Test("Runtime follow-up: existing evidence where all children share Athlete/Sport loads into the new shared-context staging")
    @MainActor
    func agreeingHistoricalEvidenceLoadsIntoSharedContextStaging() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        try fixture.decompositionEvidenceRepository.insert(
            sourceId: fixture.source.externalPlanningSourceId, recurringEventIdentifier: nil, normalizedTitle: "hockey training",
            createdBy: ActorId(),
            children: [
                (athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40),
                (athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60)
            ]
        )

        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        let staged = viewModel.stagedClassification(for: item.externalEventKey)

        #expect(staged.isSplitEnabled)
        #expect(staged.isSuggestedSplitPrefill)
        #expect(staged.splitAthleteId == fixture.athleteId)
        #expect(staged.splitSportId == nil)
        #expect(staged.splitChildren.map(\.durationMinutes) == [40, 60])
    }

    /// Runtime follow-up (evidence backward compatibility), test
    /// requirement 7: historical evidence whose children carry DIFFERENT
    /// athleteIds (a shape only possible from before this round, since
    /// every current split now shares one athlete across its children)
    /// must never be silently collapsed into a single-athlete
    /// suggestion — the event is left unsuggested, falling through to
    /// its ordinary blank staging.
    @Test("Runtime follow-up: incompatible historical evidence with different child Athletes is not silently collapsed")
    @MainActor
    func disagreeingHistoricalEvidenceIsNotSilentlyCollapsed() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        try fixture.decompositionEvidenceRepository.insert(
            sourceId: fixture.source.externalPlanningSourceId, recurringEventIdentifier: nil, normalizedTitle: "hockey training",
            createdBy: ActorId(),
            children: [
                (athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40),
                (athleteId: secondAthleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60)
            ]
        )

        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        let staged = viewModel.stagedClassification(for: item.externalEventKey)

        #expect(!staged.isSplitEnabled)
        #expect(!staged.isSuggestedSplitPrefill)
        #expect(staged.splitAthleteId == nil)
    }

    /// Runtime follow-up (Part 2 — missing Suggested Split), test
    /// requirements 8 and 10: importing an explicit split for the first
    /// occurrence of a recurring series makes an untouched, later
    /// occurrence of the SAME series receive a Suggested Split on the
    /// SAME refresh cycle (the one `bulkImportReadyItems()` itself
    /// triggers) — never requiring a second `load()` / new ViewModel
    /// instance. A THIRD, unrelated event carrying genuine Parent-owned
    /// staging (an explicit Athlete selection) is untouched by this same
    /// refresh — meaningful staging is never overwritten by a newly
    /// learned suggestion.
    @Test("Runtime follow-up: after importing one split, an untouched later same-series occurrence gets Suggested Split on the same refresh cycle, and Parent-owned staging elsewhere is preserved")
    @MainActor
    func laterOccurrenceGetsSuggestedSplitOnSameRefreshCycleAfterImport() throws {
        let fixture = try makeFixture()
        let firstOccurrence = Self.referenceDate.addingTimeInterval(3600)
        let secondOccurrence = firstOccurrence.addingTimeInterval(7 * 24 * 3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: firstOccurrence, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: firstOccurrence, endDate: firstOccurrence.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: secondOccurrence, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: secondOccurrence, endDate: secondOccurrence.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            )
        ]
        addEvent(fixture, identifier: "evt-unrelated", title: "Swim practice", hoursFromReference: 5)

        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let firstItem = try #require(viewModel.reviewQueue.first { $0.event.occurrenceDate == firstOccurrence })
        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.occurrenceDate == secondOccurrence })
        let unrelatedItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-unrelated" })

        // Parent-owned staging on the unrelated item, BEFORE the split
        // import below.
        viewModel.setStagedAthlete(fixture.athleteId, for: unrelatedItem.externalEventKey)
        viewModel.setStagedActivityType(.individualTraining, for: unrelatedItem.externalEventKey)

        viewModel.setSplitEnabled(true, for: firstItem.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        viewModel.addSplitChild(for: firstItem.externalEventKey)
        let firstChildId = viewModel.stagedClassification(for: firstItem.externalEventKey).splitChildren[0].id
        let secondChildId = viewModel.stagedClassification(for: firstItem.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(firstChildId, for: firstItem.externalEventKey) { $0.durationMinutes = 40 }
        viewModel.updateSplitChild(secondChildId, for: firstItem.externalEventKey) {
            $0.startOffsetMinutes = 70
            $0.durationMinutes = 60
        }
        viewModel.markReady(for: firstItem.externalEventKey)

        viewModel.bulkImportReadyItems()

        // Requirement 8: the untouched SECOND occurrence, still pending,
        // already carries the Suggested Split — no second refresh
        // needed.
        let secondStaged = viewModel.stagedClassification(for: secondItem.externalEventKey)
        #expect(secondStaged.isSplitEnabled)
        #expect(secondStaged.isSuggestedSplitPrefill)
        #expect(secondStaged.splitAthleteId == fixture.athleteId)
        #expect(secondStaged.splitChildren.map(\.durationMinutes) == [40, 60])

        // Requirement 10: the unrelated item's own Parent-owned staging
        // survived this same refresh untouched.
        let unrelatedStaged = viewModel.stagedClassification(for: unrelatedItem.externalEventKey)
        #expect(unrelatedStaged.athleteId == fixture.athleteId)
        #expect(unrelatedStaged.activityType == .individualTraining)
        #expect(!unrelatedStaged.isSplitEnabled)
    }

    /// Runtime follow-up (Part 2 — missing Suggested Split), test
    /// requirement 9: when the later occurrence's recurring identity
    /// does NOT match (a genuinely different, non-recurring event), the
    /// same-source exact-title fallback still surfaces a Suggested
    /// Split on the same refresh cycle.
    @Test("Runtime follow-up: exact-title fallback surfaces Suggested Split on the same refresh cycle when recurring identity does not match")
    @MainActor
    func exactTitleFallbackSurfacesSuggestedSplitOnSameRefreshCycle() throws {
        let fixture = try makeFixture()
        let firstStart = Self.referenceDate.addingTimeInterval(3600)
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)

        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let firstItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-1" })

        viewModel.setSplitEnabled(true, for: firstItem.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        viewModel.addSplitChild(for: firstItem.externalEventKey)
        let firstChildId = viewModel.stagedClassification(for: firstItem.externalEventKey).splitChildren[0].id
        let secondChildId = viewModel.stagedClassification(for: firstItem.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(firstChildId, for: firstItem.externalEventKey) { $0.durationMinutes = 40 }
        viewModel.updateSplitChild(secondChildId, for: firstItem.externalEventKey) {
            $0.startOffsetMinutes = 70
            $0.durationMinutes = 60
        }
        viewModel.markReady(for: firstItem.externalEventKey)

        // A SECOND, non-recurring event added only AFTER the first
        // import — same exact title, different eventIdentifier, no
        // recurring identity in common at all.
        let secondStart = firstStart.addingTimeInterval(7 * 24 * 3600)
        var events = fixture.calendarProvider.eventsByCalendar["cal-familie"] ?? []
        events.append(
            ExternalCalendarEvent(
                eventIdentifier: "evt-2", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: secondStart, endDate: secondStart.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        )
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = events

        viewModel.bulkImportReadyItems()

        let secondItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        let secondStaged = viewModel.stagedClassification(for: secondItem.externalEventKey)
        #expect(secondStaged.isSplitEnabled)
        #expect(secondStaged.isSuggestedSplitPrefill)
        #expect(secondStaged.splitAthleteId == fixture.athleteId)
        #expect(secondStaged.splitChildren.map(\.durationMinutes) == [40, 60])
    }

    // MARK: - VX-038 TestFlight follow-up: helpers

    /// Like `addEvent`, but with a caller-controlled duration — needed
    /// for Part 3's sequential timing assistance tests, which depend on
    /// the external event's own end time.
    private func addTimedEvent(_ fixture: Fixture, identifier: String, title: String, hoursFromReference: Double, durationMinutes: Double, isRecurring: Bool = false) {
        let start = Self.referenceDate.addingTimeInterval(hoursFromReference * 3600)
        var existing = fixture.calendarProvider.eventsByCalendar["cal-familie"] ?? []
        existing.append(
            ExternalCalendarEvent(
                eventIdentifier: identifier, calendarIdentifier: "cal-familie", title: title,
                startDate: start, endDate: start.addingTimeInterval(durationMinutes * 60), isAllDay: false, isRecurring: isRecurring
            )
        )
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = existing
    }

    // MARK: - VX-038 TestFlight follow-up: classification preservation (Part 1/2)

    @Test("VX-038 TestFlight follow-up test 1: ordinary Athlete/Sport/Activity Type are inherited on first Split activation")
    @MainActor
    func firstSplitActivationInheritsOrdinaryClassification() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.setStagedActivityType(.teamTraining, for: item.externalEventKey)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)

        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        #expect(staged.splitAthleteId == fixture.athleteId)
        #expect(staged.splitChildren.count == 1)
        #expect(staged.splitChildren[0].activityType == .teamTraining)
    }

    @Test("VX-038 TestFlight follow-up test 2: ordinary values remain intact underneath after Split activation, and Split OFF falls back to them exactly")
    @MainActor
    func ordinaryClassificationSurvivesUnderneathSplitActivation() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.setStagedActivityType(.teamTraining, for: item.externalEventKey)
        viewModel.setSplitEnabled(true, for: item.externalEventKey)

        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        #expect(staged.athleteId == fixture.athleteId)
        #expect(staged.activityType == .teamTraining)

        viewModel.setSplitEnabled(false, for: item.externalEventKey)
        let stagedAfterOff = viewModel.stagedClassification(for: item.externalEventKey)
        #expect(stagedAfterOff.athleteId == fixture.athleteId)
        #expect(stagedAfterOff.activityType == .teamTraining)
        #expect(!stagedAfterOff.isSplitEnabled)
    }

    @Test("VX-038 TestFlight follow-up test 3: Split edits survive Split OFF -> ON")
    @MainActor
    func splitEditsSurviveOffThenOnToggle() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { $0.durationMinutes = 55 }

        viewModel.setSplitEnabled(false, for: item.externalEventKey)
        viewModel.setSplitEnabled(true, for: item.externalEventKey)

        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        #expect(staged.splitChildren.count == 2)
        #expect(staged.splitChildren[1].durationMinutes == 55)
        #expect(staged.splitAthleteId == fixture.athleteId)
    }

    @Test("VX-038 TestFlight follow-up test 4: reactivation never re-seeds prior split state from ordinary fields, even when the ordinary fields changed in between")
    @MainActor
    func reactivationDoesNotReseedFromChangedOrdinaryFields() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        #expect(viewModel.stagedClassification(for: item.externalEventKey).splitAthleteId == fixture.athleteId)

        viewModel.setSplitEnabled(false, for: item.externalEventKey)
        // The Parent changes the ORDINARY athlete while Split is off.
        viewModel.setStagedAthlete(secondAthleteId, for: item.externalEventKey)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)

        // Reactivation must NOT re-seed splitAthleteId from the
        // now-changed ordinary athlete — the Parent's own prior split
        // choice wins untouched.
        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        #expect(staged.splitAthleteId == fixture.athleteId)
        #expect(staged.splitChildren.count == 2)
    }

    @Test("VX-038 TestFlight follow-up test 5: partial ordinary classification inherits only the available values")
    @MainActor
    func partialOrdinaryClassificationInheritsOnlyAvailableValues() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        // Only Activity Type set — no Athlete, no Sport.
        viewModel.setStagedActivityType(.teamTraining, for: item.externalEventKey)
        viewModel.setSplitEnabled(true, for: item.externalEventKey)

        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        #expect(staged.splitAthleteId == nil)
        #expect(staged.splitSportId == nil)
        #expect(staged.splitChildren[0].activityType == .teamTraining)
    }

    @Test("VX-038 TestFlight follow-up test 6: optional Sport remains optional through Split activation, editing, and import")
    @MainActor
    func optionalSportRemainsOptionalAfterSplitActivation() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) {
            $0.startOffsetMinutes = 70
            $0.durationMinutes = 60
        }

        #expect(viewModel.stagedClassification(for: item.externalEventKey).splitSportId == nil)
        #expect(viewModel.stagedClassification(for: item.externalEventKey).satisfiesMinimumImportRequirements)
        viewModel.markReady(for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.count == 1)
    }

    // MARK: - VX-038 TestFlight follow-up: sequential split timing assistance (Part 3)

    @Test("VX-038 TestFlight follow-up test 7: a 90-minute event with first child 0/30 defaults the second child to 30/60")
    @MainActor
    func secondChildDefaultsToRemainingEventTime() throws {
        let fixture = try makeFixture()
        addTimedEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1, durationMinutes: 90)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        let first = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[0]
        #expect(first.startOffsetMinutes == 0)
        #expect(first.durationMinutes == 30)

        viewModel.addSplitChild(for: item.externalEventKey)
        let second = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1]
        #expect(second.startOffsetMinutes == 30)
        #expect(second.durationMinutes == 60)
    }

    @Test("VX-038 TestFlight follow-up test 8: moving the derived second child's start from 30 to 40 recalculates its duration from 60 to 50")
    @MainActor
    func movingDerivedChildStartRecalculatesDuration() throws {
        let fixture = try makeFixture()
        addTimedEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1, durationMinutes: 90)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id

        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { $0.startOffsetMinutes = 40 }

        let second = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1]
        #expect(second.startOffsetMinutes == 40)
        #expect(second.durationMinutes == 50)
    }

    @Test("VX-038 TestFlight follow-up test 9: moving the derived second child's start again keeps its duration anchored to the event end")
    @MainActor
    func movingDerivedChildStartAgainStaysAnchoredToEventEnd() throws {
        let fixture = try makeFixture()
        addTimedEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1, durationMinutes: 90)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id

        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { $0.startOffsetMinutes = 40 }
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { $0.startOffsetMinutes = 50 }

        let second = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1]
        #expect(second.startOffsetMinutes == 50)
        #expect(second.durationMinutes == 40)
    }

    @Test("VX-038 TestFlight follow-up test 10: an explicit duration edit converts the child's duration to Parent-owned")
    @MainActor
    func explicitDurationEditBecomesParentOwned() throws {
        let fixture = try makeFixture()
        addTimedEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1, durationMinutes: 90)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id

        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { $0.durationMinutes = 45 }
        // A subsequent start-offset change must NOT recalculate this
        // Parent-owned duration back to the event remainder.
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { $0.startOffsetMinutes = 40 }

        let second = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1]
        #expect(second.startOffsetMinutes == 40)
        #expect(second.durationMinutes == 45)
    }

    @Test("VX-038 TestFlight follow-up test 11: after a Parent duration edit, repeated start-offset changes keep preserving the manual duration")
    @MainActor
    func repeatedStartOffsetChangesPreserveManualDuration() throws {
        let fixture = try makeFixture()
        addTimedEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1, durationMinutes: 90)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id

        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { $0.durationMinutes = 45 }
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { $0.startOffsetMinutes = 35 }
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { $0.startOffsetMinutes = 60 }

        let second = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1]
        #expect(second.startOffsetMinutes == 60)
        #expect(second.durationMinutes == 45)
    }

    @Test("VX-038 TestFlight follow-up test 12: a third child starts where the second one ends and receives the event's remaining time")
    @MainActor
    func thirdChildStartsAtPreviousChildEndAndReceivesRemainder() throws {
        let fixture = try makeFixture()
        addTimedEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1, durationMinutes: 120)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        // child1 = 0/30 (safe default).
        viewModel.addSplitChild(for: item.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id
        // Parent explicitly sets child2 = 30/40.
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) { $0.durationMinutes = 40 }

        viewModel.addSplitChild(for: item.externalEventKey)
        let third = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[2]
        #expect(third.startOffsetMinutes == 70)
        #expect(third.durationMinutes == 50)
    }

    @Test("VX-038 TestFlight follow-up test 13: a missing event end time falls back to the safe existing split defaults")
    @MainActor
    func missingEventEndFallsBackToSafeDefaults() throws {
        let fixture = try makeFixture()
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: nil, isAllDay: false, isRecurring: false
            )
        ]
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)

        let second = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1]
        #expect(second.startOffsetMinutes == 30)
        #expect(second.durationMinutes == 30)
    }

    /// Lead Review follow-up (PR #55 — do not auto-create a child outside
    /// the event envelope), required test 1: a 90-minute event whose
    /// only child already consumes the WHOLE event — tapping "Add
    /// another activity" must not invent an app-generated activity
    /// starting at the event's own boundary. No second child is
    /// appended at all.
    @Test("VX-038 Lead Review follow-up test 1: a child already consuming the whole event blocks the automatic Add proposal")
    @MainActor
    func addSplitChildDoesNothingWhenPreviousChildConsumesWholeEvent() throws {
        let fixture = try makeFixture()
        addTimedEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1, durationMinutes: 90)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        let firstChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[0].id
        // Parent explicitly stretches the first child to consume the
        // WHOLE event.
        viewModel.updateSplitChild(firstChildId, for: item.externalEventKey) { $0.durationMinutes = 90 }

        viewModel.addSplitChild(for: item.externalEventKey)

        #expect(viewModel.stagedClassification(for: item.externalEventKey).splitChildren.count == 1)
    }

    /// Lead Review follow-up (PR #55), required test 2: a child that
    /// already exceeds the known event end — same guard applies whether
    /// the previous child ends exactly at, or past, the event boundary.
    @Test("VX-038 Lead Review follow-up test 2: a child already past the event end also blocks the automatic Add proposal")
    @MainActor
    func addSplitChildDoesNothingWhenPreviousChildExceedsEventEnd() throws {
        let fixture = try makeFixture()
        addTimedEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1, durationMinutes: 60)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        let firstChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[0].id
        // Parent explicitly extends the first child PAST the event's own
        // end — Parent judgement wins on this existing gap/overlap
        // (unaffected by the automatic-Add guard).
        viewModel.updateSplitChild(firstChildId, for: item.externalEventKey) { $0.durationMinutes = 90 }

        viewModel.addSplitChild(for: item.externalEventKey)

        #expect(viewModel.stagedClassification(for: item.externalEventKey).splitChildren.count == 1)
    }

    /// Lead Review follow-up (PR #55), required test 6: a general sweep
    /// confirming no automatic Add operation with a known event end ever
    /// produces a child whose startOffset is at or beyond the event's
    /// own duration — exercised at the exact boundary (offset ==
    /// duration) via test 1 above, and comfortably past it via test 2 —
    /// this asserts the same invariant directly against
    /// `addSplitChild`'s own no-op contract for a THIRD attempt after
    /// the guard has already fired once, proving it does not flip on a
    /// later call.
    @Test("VX-038 Lead Review follow-up test 6: repeated Add taps never produce a child starting at or past the event end")
    @MainActor
    func repeatedAddNeverProducesChildAtOrPastEventEnd() throws {
        let fixture = try makeFixture()
        addTimedEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1, durationMinutes: 60)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        let firstChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[0].id
        viewModel.updateSplitChild(firstChildId, for: item.externalEventKey) { $0.durationMinutes = 60 }

        viewModel.addSplitChild(for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)

        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        #expect(staged.splitChildren.count == 1)
        #expect(staged.splitChildren.allSatisfy { $0.startOffsetMinutes < 60 })
    }

    /// Lead Review follow-up (PR #55), required test 5: the automatic-Add
    /// guard never reaches back and blocks (or rewrites) a gap/overlap
    /// the Parent has already explicitly created by editing an EXISTING
    /// child's own values — this guard applies only to the automatic
    /// "Add another activity" proposal itself.
    @Test("VX-038 Lead Review follow-up test 5: an existing manually-created gap/overlap between children remains fully editable and untouched")
    @MainActor
    func manuallyCreatedGapOrOverlapRemainsAllowed() throws {
        let fixture = try makeFixture()
        addTimedEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1, durationMinutes: 90)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)

        viewModel.setSplitEnabled(true, for: item.externalEventKey)
        viewModel.addSplitChild(for: item.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: item.externalEventKey).splitChildren[1].id
        // Parent explicitly creates an overlap: second child starts
        // BEFORE the first child ends.
        viewModel.updateSplitChild(secondChildId, for: item.externalEventKey) {
            $0.startOffsetMinutes = 10
            $0.durationMinutes = 20
        }

        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        #expect(staged.splitChildren[0].startOffsetMinutes == 0)
        #expect(staged.splitChildren[0].durationMinutes == 30)
        #expect(staged.splitChildren[1].startOffsetMinutes == 10)
        #expect(staged.splitChildren[1].durationMinutes == 20)
        #expect(staged.splitChildrenAreValid)
    }

    // MARK: - VX-038 TestFlight follow-up: real Suggested Split root cause (Part 4)

    /// THE root-cause regression test. Every earlier Suggested Split test
    /// (PR #54 and before) set up a CLEAN event — one with no prior
    /// classification history at all — so `stagedClassifications` had NO
    /// existing entry for the "next occurrence" before the split import,
    /// and `hasMeaningfulStaging` was trivially `false` for a missing
    /// key. That is why those tests missed this bug entirely.
    ///
    /// The REAL TestFlight sequence is different: the Parent has ALREADY
    /// imported earlier occurrences of this recurring event ORDINARILY
    /// (non-split) at some point before trying Split — completely
    /// realistic, since Split is a new feature layered onto an existing
    /// workflow. That leaves durable V1.1 Remembered Exact Choice
    /// history for this title. The very first time Review is opened
    /// after that, EVERY still-pending occurrence — including one the
    /// Parent has not looked at yet — gets an immediate, already-Ready,
    /// system-generated `.exactRemembered` prefill (never touched by the
    /// Parent — `hasUserInteraction` stays `false`). Before this round's
    /// fix, that untouched prefill was (incorrectly) treated as
    /// permanently "meaningful" by `hasMeaningfulStaging` (via the old
    /// `isConfirmedReady`/`suggestionKind != .none` checks) the instant
    /// it was first computed — so when the Parent later explicitly
    /// splits an EARLIER occurrence and new decomposition evidence is
    /// written, the LATER occurrence's stale exact-remembered staging
    /// was preserved untouched forever, and `suggestedSplit(for:source:)`
    /// was never even called for it again. This test reproduces that
    /// exact sequence and proves the later occurrence now correctly
    /// receives the Suggested Split.
    @Test("VX-038 TestFlight follow-up (root cause): a later occurrence carrying a stale, untouched Remembered Exact Choice prefill is superseded by newly-learned Suggested Split evidence")
    @MainActor
    func staleRememberedChoicePrefillIsSupersededByNewlyLearnedSuggestedSplit() throws {
        let fixture = try makeFixture()

        // Prior history: an EARLIER occurrence of "Hockey training",
        // imported ORDINARILY (non-split) before Split was ever used —
        // this is what makes V1.1 remembered-exact history exist for
        // this title.
        addEvent(fixture, identifier: "evt-0", title: "Hockey training", hoursFromReference: 1)
        let historyViewModel = makeViewModel(fixture)
        historyViewModel.load()
        let historyItem = try #require(historyViewModel.reviewQueue.first)
        historyViewModel.setStagedAthlete(fixture.athleteId, for: historyItem.externalEventKey)
        historyViewModel.markReady(for: historyItem.externalEventKey)
        historyViewModel.bulkImportReadyItems()

        // Two MORE future occurrences of the same title — evt-A (about
        // to be explicitly split) and evt-B (the untouched "next
        // matching calendar activity" from the TestFlight report).
        addEvent(fixture, identifier: "evt-A", title: "Hockey training", hoursFromReference: 24)
        addEvent(fixture, identifier: "evt-B", title: "Hockey training", hoursFromReference: 48)

        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })
        let itemB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-B" })

        // Precondition: BOTH evt-A and evt-B immediately received the
        // system-generated exact-remembered prefill on this very first
        // load() — neither has been touched by the Parent yet.
        #expect(viewModel.stagedClassification(for: itemA.externalEventKey).suggestionKind == .exactRemembered)
        #expect(viewModel.stagedClassification(for: itemA.externalEventKey).isConfirmedReady)
        let itemBPreStaged = viewModel.stagedClassification(for: itemB.externalEventKey)
        #expect(itemBPreStaged.suggestionKind == .exactRemembered)
        #expect(itemBPreStaged.isConfirmedReady)
        #expect(!itemBPreStaged.isSplitEnabled)

        // The Parent explicitly decides to Split evt-A instead of
        // accepting its exact-remembered prefill (Part 1: this inherits
        // the already-prefilled ordinary Athlete into the shared split
        // Athlete).
        viewModel.setSplitEnabled(true, for: itemA.externalEventKey)
        viewModel.addSplitChild(for: itemA.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: itemA.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(secondChildId, for: itemA.externalEventKey) {
            $0.startOffsetMinutes = 70
            $0.durationMinutes = 60
        }
        viewModel.markReady(for: itemA.externalEventKey)

        viewModel.bulkImportReadyItems()

        // evt-B, still pending and NEVER touched by the Parent, must now
        // be superseded by the freshly-learned Suggested Split — not
        // left stuck on its stale, untouched exact-remembered prefill.
        let itemBStaged = viewModel.stagedClassification(for: itemB.externalEventKey)
        #expect(itemBStaged.isSplitEnabled)
        #expect(itemBStaged.isSuggestedSplitPrefill)
        #expect(itemBStaged.splitAthleteId == fixture.athleteId)
        #expect(itemBStaged.splitChildren.map(\.durationMinutes) == [30, 60])
    }

    /// Bounded-audit follow-up to the `hasMeaningfulStaging` fix above:
    /// since a bare system-generated suggestion is no longer sticky on
    /// its own, tapping "Edit" must itself count as Parent interaction —
    /// otherwise an unrelated refresh mid-edit could silently wipe and
    /// re-derive (and potentially re-confirm Ready) a row the Parent is
    /// actively reconsidering. `beginEditing(for:)` now also sets
    /// `hasUserInteraction = true` to close that gap.
    @Test("VX-038 TestFlight follow-up: tapping Edit on an exact-remembered Ready item protects it from an unrelated refresh re-deriving/re-confirming it before the Parent acts again")
    @MainActor
    func editOnRememberedItemSurvivesUnrelatedRefresh() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-history", title: "Hockey training", hoursFromReference: 1)
        let historyViewModel = makeViewModel(fixture)
        historyViewModel.load()
        let historyItem = try #require(historyViewModel.reviewQueue.first)
        historyViewModel.setStagedAthlete(fixture.athleteId, for: historyItem.externalEventKey)
        historyViewModel.markReady(for: historyItem.externalEventKey)
        historyViewModel.bulkImportReadyItems()

        addEvent(fixture, identifier: "evt-remembered", title: "Hockey training", hoursFromReference: 24)
        addEvent(fixture, identifier: "evt-unrelated", title: "Piano Lesson", hoursFromReference: 25)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let rememberedItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-remembered" })
        let unrelatedItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-unrelated" })
        #expect(viewModel.stagedClassification(for: rememberedItem.externalEventKey).isConfirmedReady)

        viewModel.beginEditing(for: rememberedItem.externalEventKey)
        #expect(!viewModel.stagedClassification(for: rememberedItem.externalEventKey).isConfirmedReady)

        // An unrelated action elsewhere triggers another refresh cycle.
        viewModel.ignore(unrelatedItem)

        // The item being actively edited must still show NOT Ready — it
        // must never silently snap back to auto-Ready underneath the
        // Parent mid-edit.
        #expect(!viewModel.stagedClassification(for: rememberedItem.externalEventKey).isConfirmedReady)
        #expect(viewModel.stagedClassification(for: rememberedItem.externalEventKey).athleteId == fixture.athleteId)
    }

    @Test("VX-038 TestFlight follow-up test 17: a fresh CalendarImportReviewViewModel against the SAME persistence derives Suggested Split from durable evidence")
    @MainActor
    func freshViewModelAgainstSamePersistenceDerivesSuggestedSplit() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)

        firstViewModel.setSplitEnabled(true, for: firstItem.externalEventKey)
        firstViewModel.setSplitAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        firstViewModel.addSplitChild(for: firstItem.externalEventKey)
        let secondChildId = firstViewModel.stagedClassification(for: firstItem.externalEventKey).splitChildren[1].id
        firstViewModel.updateSplitChild(secondChildId, for: firstItem.externalEventKey) {
            $0.startOffsetMinutes = 70
            $0.durationMinutes = 60
        }
        firstViewModel.markReady(for: firstItem.externalEventKey)
        firstViewModel.bulkImportReadyItems()

        // DISCARD firstViewModel entirely — a genuinely fresh ViewModel
        // instance, same coordination service, same persisted store.
        addEvent(fixture, identifier: "evt-2", title: "Hockey training", hoursFromReference: 24 * 7)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        let staged = secondViewModel.stagedClassification(for: secondItem.externalEventKey)
        #expect(staged.isSplitEnabled)
        #expect(staged.isSuggestedSplitPrefill)
        #expect(staged.splitAthleteId == fixture.athleteId)
        #expect(staged.splitChildren.map(\.durationMinutes) == [30, 60])
    }

    @Test("VX-038 TestFlight follow-up test 24: Suggested Split never itself imports anything — the Parent's own explicit Ready/import action is still required")
    @MainActor
    func suggestedSplitNeverAutoImports() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        try fixture.decompositionEvidenceRepository.insert(
            sourceId: fixture.source.externalPlanningSourceId, recurringEventIdentifier: nil, normalizedTitle: "hockey training",
            createdBy: ActorId(),
            children: [
                (athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40),
                (athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60)
            ]
        )

        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        #expect(staged.isSplitEnabled)
        #expect(staged.isSuggestedSplitPrefill)
        // A Suggested Split prefill NEVER auto-confirms Ready.
        #expect(!staged.isConfirmedReady)
        #expect(viewModel.readyToImportItems.isEmpty)
        #expect(viewModel.reviewQueue.count == 1)

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
    }

    // MARK: - VX-038 unified recognition follow-up: restore + Split preservation (required tests 1-5)

    @Test("VX-038 unified test 1/2/3: Ignore -> Review again -> Athlete/Sport/non-default Activity Type -> Split inherits all three, using the actual restored externalEventKey, with ordinary values intact underneath")
    @MainActor
    func restoreThenClassifyThenSplitInheritsAllThree() throws {
        let fixture = try makeFixture()
        let seededSports = try fixture.sportRepository.seedCanonicalSportsIfNeeded()
        let sport = try #require(seededSports.first)
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let originalItem = try #require(viewModel.reviewQueue.first)

        // Step 4-5: Ignore, then confirm it left pending Review and
        // appears in Ignored.
        viewModel.ignore(originalItem)
        #expect(viewModel.reviewQueue.isEmpty)
        #expect(viewModel.ignoredItems.map(\.externalEventKey).contains(originalItem.externalEventKey))

        // Step 6-7: restore ("Review again") — back in the review queue,
        // editable, SAME externalEventKey.
        let ignoredItem = try #require(viewModel.ignoredItems.first)
        viewModel.restore(ignoredItem)
        let restoredItem = try #require(viewModel.reviewQueue.first)
        #expect(restoredItem.externalEventKey == originalItem.externalEventKey)

        // Step 8-9: Athlete/Sport/a NON-DEFAULT Activity Type, using the
        // real ViewModel setters and the actual restored key.
        viewModel.setStagedAthlete(fixture.athleteId, for: restoredItem.externalEventKey)
        viewModel.setStagedSport(sport.sportId, for: restoredItem.externalEventKey)
        viewModel.setStagedActivityType(.teamTraining, for: restoredItem.externalEventKey)

        let beforeSplit = viewModel.stagedClassification(for: restoredItem.externalEventKey)
        #expect(beforeSplit.athleteId == fixture.athleteId)
        #expect(beforeSplit.sportId == sport.sportId)
        #expect(beforeSplit.activityType == .teamTraining)

        // Step 10-11: enable Split — inherits all three immediately.
        viewModel.setSplitEnabled(true, for: restoredItem.externalEventKey)
        let afterSplit = viewModel.stagedClassification(for: restoredItem.externalEventKey)
        #expect(afterSplit.isSplitEnabled)
        #expect(afterSplit.splitAthleteId == fixture.athleteId)
        #expect(afterSplit.splitSportId == sport.sportId)
        #expect(afterSplit.splitChildren.first?.activityType == .teamTraining)

        // Ordinary values remain intact underneath.
        #expect(afterSplit.athleteId == fixture.athleteId)
        #expect(afterSplit.sportId == sport.sportId)
        #expect(afterSplit.activityType == .teamTraining)
    }

    @Test("VX-038 unified test 4/5: after restore, Split OFF/ON preserves Parent-edited Split state, and reactivation never overwrites it from the ordinary fields")
    @MainActor
    func restoreThenSplitOffOnPreservesEditedSplitState() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let originalItem = try #require(viewModel.reviewQueue.first)
        viewModel.ignore(originalItem)
        viewModel.restore(try #require(viewModel.ignoredItems.first))
        let restoredItem = try #require(viewModel.reviewQueue.first)

        viewModel.setStagedAthlete(fixture.athleteId, for: restoredItem.externalEventKey)
        viewModel.setSplitEnabled(true, for: restoredItem.externalEventKey)
        viewModel.addSplitChild(for: restoredItem.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: restoredItem.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(secondChildId, for: restoredItem.externalEventKey) { $0.durationMinutes = 55 }

        // Split OFF/ON preserves the edited split state.
        viewModel.setSplitEnabled(false, for: restoredItem.externalEventKey)
        viewModel.setSplitEnabled(true, for: restoredItem.externalEventKey)
        let staged = viewModel.stagedClassification(for: restoredItem.externalEventKey)
        #expect(staged.splitChildren.count == 2)
        #expect(staged.splitChildren[1].durationMinutes == 55)

        // Changing the ordinary Athlete while Split is off never
        // re-seeds the already-edited split Athlete on reactivation.
        viewModel.setSplitEnabled(false, for: restoredItem.externalEventKey)
        viewModel.setStagedAthlete(secondAthleteId, for: restoredItem.externalEventKey)
        viewModel.setSplitEnabled(true, for: restoredItem.externalEventKey)
        #expect(viewModel.stagedClassification(for: restoredItem.externalEventKey).splitAthleteId == fixture.athleteId)
    }

    // MARK: - VX-038 unified recognition follow-up: existing normal recognition (required tests 6-7)

    @Test("VX-038 unified test 6: an ordinary classification marked Ready — WITHOUT importing first — assists a matching untouched pending event within the same active Review workflow")
    @MainActor
    func ordinaryReadyClassificationAssistsMatchingEventWithoutImportFirst() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-A", title: "Hockey training", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-B", title: "Hockey training", hoursFromReference: 24)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })
        let itemB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-B" })

        viewModel.setStagedAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.setStagedActivityType(.teamTraining, for: itemA.externalEventKey)
        viewModel.markReady(for: itemA.externalEventKey)

        // A was never imported — no PlannedActivity exists yet.
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)

        let stagedB = viewModel.stagedClassification(for: itemB.externalEventKey)
        #expect(stagedB.athleteId == fixture.athleteId)
        #expect(stagedB.activityType == .teamTraining)
        #expect(stagedB.isConfirmedReady)
        #expect(stagedB.suggestionKind == .exactRemembered)
    }

    @Test("VX-038 unified test 7: a Ready ordinary classification creates no Planning truth before Import")
    @MainActor
    func readyOrdinaryClassificationCreatesNoPlanningTruthBeforeImport() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        viewModel.markReady(for: item.externalEventKey)

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
        #expect(try fixture.decompositionEvidenceRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
    }

    // MARK: - VX-038 unified recognition follow-up: unified Split recognition (required tests 8-15)

    @Test("VX-038 unified test 8: a configured but NOT Ready Split does not teach a matching pending event")
    @MainActor
    func configuredButNotReadySplitDoesNotTeach() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-A", title: "Hockey training", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-B", title: "Hockey training", hoursFromReference: 24)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })
        let itemB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-B" })

        viewModel.setSplitEnabled(true, for: itemA.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.addSplitChild(for: itemA.externalEventKey)
        // Deliberately NOT marked Ready.

        let stagedB = viewModel.stagedClassification(for: itemB.externalEventKey)
        #expect(!stagedB.isSplitEnabled)
        #expect(stagedB.athleteId == nil)
    }

    @Test("VX-038 unified test 9/10/11/12: a Parent-confirmed Ready Split — WITHOUT importing first — teaches a matching untouched event within the same Review workflow, with correct shared Athlete/Sport, child count/order, Activity Types, offsets and durations, and (Lead Review Blocker 1) arrives already Ready — the SAME confirmation status the equivalent ordinary exact match already gets")
    @MainActor
    func readySplitTeachesMatchingEventWithoutImportFirst() throws {
        let fixture = try makeFixture()
        let seededSports = try fixture.sportRepository.seedCanonicalSportsIfNeeded()
        let sport = try #require(seededSports.first)
        addEvent(fixture, identifier: "evt-A", title: "Hockey training", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-B", title: "Hockey training", hoursFromReference: 24)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })
        let itemB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-B" })

        viewModel.setSplitEnabled(true, for: itemA.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.setSplitSport(sport.sportId, for: itemA.externalEventKey)
        viewModel.addSplitChild(for: itemA.externalEventKey)
        let firstChildId = viewModel.stagedClassification(for: itemA.externalEventKey).splitChildren[0].id
        let secondChildId = viewModel.stagedClassification(for: itemA.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(firstChildId, for: itemA.externalEventKey) { $0.durationMinutes = 40 }
        viewModel.updateSplitChild(secondChildId, for: itemA.externalEventKey) {
            $0.startOffsetMinutes = 70
            $0.durationMinutes = 60
        }
        viewModel.markReady(for: itemA.externalEventKey)

        // A was never imported.
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)

        let stagedB = viewModel.stagedClassification(for: itemB.externalEventKey)
        #expect(stagedB.isSplitEnabled)
        #expect(stagedB.isSuggestedSplitPrefill)
        #expect(stagedB.splitAthleteId == fixture.athleteId)
        #expect(stagedB.splitSportId == sport.sportId)
        #expect(stagedB.splitChildren.map(\.startOffsetMinutes) == [0, 70])
        #expect(stagedB.splitChildren.map(\.durationMinutes) == [40, 60])
        // Lead Review follow-up (Blocker 1 — single/split Ready semantic
        // parity): this exact session-ready match arrives ALREADY Ready,
        // exactly like the equivalent ordinary exact match does — shape
        // must never determine confirmation status, only evidence
        // strength does, and this match is exact either way.
        #expect(stagedB.isConfirmedReady)
        #expect(viewModel.readyToImportItems.map(\.externalEventKey).contains(itemB.externalEventKey))
    }

    @Test("VX-038 unified test 13: a Split classification derived from session Ready evidence arrives already Ready (Blocker 1 parity), but only becomes GENUINE session evidence itself once the Parent explicitly acts on it (hasUserInteraction, Part 12)")
    @MainActor
    func sessionDerivedSplitBecomesGenuineEvidenceOnlyAfterExplicitParentAction() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-A", title: "Hockey training", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-B", title: "Hockey training", hoursFromReference: 24)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })
        let itemB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-B" })

        viewModel.setSplitEnabled(true, for: itemA.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.addSplitChild(for: itemA.externalEventKey)
        viewModel.markReady(for: itemA.externalEventKey)

        // B arrives already Ready (Blocker 1 — same confirmation status
        // as the equivalent ordinary exact match), but purely as a
        // system prefill it never itself confirmed.
        let stagedBBeforeTouch = viewModel.stagedClassification(for: itemB.externalEventKey)
        #expect(stagedBBeforeTouch.isConfirmedReady)
        #expect(!stagedBBeforeTouch.hasUserInteraction)

        // The Parent explicitly re-confirms B — this is the ONE thing
        // that makes B itself genuinely Parent-approved evidence,
        // exactly like `markReady(for:)`'s own doc comment describes
        // (Part 12: a bare system-arrived Ready state must not itself
        // teach a third event until the Parent does something explicit
        // with it).
        viewModel.markReady(for: itemB.externalEventKey)
        #expect(viewModel.stagedClassification(for: itemB.externalEventKey).hasUserInteraction)
    }

    @Test("VX-038 unified test 14: editing a Ready Split invalidates its evidence eligibility until Ready is explicitly confirmed again")
    @MainActor
    func editingReadySplitInvalidatesEvidenceUntilReconfirmed() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-A", title: "Hockey training", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-B", title: "Hockey training", hoursFromReference: 24)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })
        let itemB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-B" })

        viewModel.setSplitEnabled(true, for: itemA.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.addSplitChild(for: itemA.externalEventKey)
        viewModel.markReady(for: itemA.externalEventKey)
        #expect(viewModel.stagedClassification(for: itemB.externalEventKey).isSplitEnabled)

        // The Parent edits A's split AFTER marking it Ready — this
        // un-confirms A (existing invariant, unchanged for Split).
        let firstChildId = viewModel.stagedClassification(for: itemA.externalEventKey).splitChildren[0].id
        viewModel.updateSplitChild(firstChildId, for: itemA.externalEventKey) { $0.durationMinutes = 45 }
        #expect(!viewModel.stagedClassification(for: itemA.externalEventKey).isConfirmedReady)

        // A THIRD event now appears — since A is no longer confirmed
        // Ready, it must NOT receive A's now-stale shape.
        addEvent(fixture, identifier: "evt-C", title: "Hockey training", hoursFromReference: 48)
        viewModel.load()
        let itemC = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-C" })
        #expect(!viewModel.stagedClassification(for: itemC.externalEventKey).isSplitEnabled)
    }

    @Test("VX-038 unified test 15: conflicting Ready Split shapes for the same title produce no automatic Split suggestion")
    @MainActor
    func conflictingReadySplitShapesProduceNoAutomaticSuggestion() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-A", title: "Hockey training", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-B", title: "Hockey training", hoursFromReference: 24)
        addEvent(fixture, identifier: "evt-C", title: "Hockey training", hoursFromReference: 48)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })
        let itemB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-B" })
        let itemC = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-C" })

        viewModel.setSplitEnabled(true, for: itemA.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.addSplitChild(for: itemA.externalEventKey)
        viewModel.markReady(for: itemA.externalEventKey)

        // A conflicting shared Athlete, marked Ready on a DIFFERENT
        // occurrence of the SAME title.
        viewModel.setSplitEnabled(true, for: itemB.externalEventKey)
        viewModel.setSplitAthlete(secondAthleteId, for: itemB.externalEventKey)
        viewModel.addSplitChild(for: itemB.externalEventKey)
        viewModel.markReady(for: itemB.externalEventKey)

        let stagedC = viewModel.stagedClassification(for: itemC.externalEventKey)
        #expect(!stagedC.isSplitEnabled)
    }

    // MARK: - VX-038 unified recognition follow-up: refresh/state safety (required tests 16-20)

    @Test("VX-038 unified test 16/17/18/19/20: marking Ready re-evaluates untouched pending rows while preserving Parent-owned staging, existing Ready rows, Needs Attention state, and lifted Suggested Ignore state")
    @MainActor
    func markReadyReEvaluatesWhilePreservingAllOtherState() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-A", title: "Hockey training", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-B", title: "Hockey training", hoursFromReference: 24)
        addEvent(fixture, identifier: "evt-parent-owned", title: "Swim practice", hoursFromReference: 25)
        addEvent(fixture, identifier: "evt-already-ready", title: "Piano recital", hoursFromReference: 26)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })
        let itemParentOwned = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-parent-owned" })
        let itemAlreadyReady = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-already-ready" })

        // A different, unrelated Parent-owned edit — not yet Ready.
        viewModel.setStagedAthlete(fixture.athleteId, for: itemParentOwned.externalEventKey)
        viewModel.setStagedActivityType(.recovery, for: itemParentOwned.externalEventKey)

        // A different, already-Ready item.
        viewModel.setStagedAthlete(fixture.athleteId, for: itemAlreadyReady.externalEventKey)
        viewModel.markReady(for: itemAlreadyReady.externalEventKey)

        // Now mark A Ready — this triggers the required re-evaluation.
        viewModel.setStagedAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.markReady(for: itemA.externalEventKey)

        // The untouched matching row (B) got re-evaluated.
        let itemB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-B" })
        #expect(viewModel.stagedClassification(for: itemB.externalEventKey).athleteId == fixture.athleteId)

        // The unrelated Parent-owned edit survived, untouched.
        let stagedParentOwned = viewModel.stagedClassification(for: itemParentOwned.externalEventKey)
        #expect(stagedParentOwned.athleteId == fixture.athleteId)
        #expect(stagedParentOwned.activityType == .recovery)
        #expect(!stagedParentOwned.isConfirmedReady)

        // The already-Ready item survived Ready.
        #expect(viewModel.stagedClassification(for: itemAlreadyReady.externalEventKey).isConfirmedReady)
        #expect(viewModel.readyToImportItems.map(\.externalEventKey).contains(itemAlreadyReady.externalEventKey))
    }

    @Test("VX-038 unified test 19 (Needs Attention survives markReady-triggered re-evaluation)")
    @MainActor
    func needsAttentionSurvivesMarkReadyTriggeredReEvaluation() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-conflict", title: "Will Conflict", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-other", title: "Hockey training", hoursFromReference: 24)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let conflictItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-conflict" })
        let otherItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-other" })

        // Pre-seed a legacy PlannedActivity owned by a DIFFERENT athlete
        // so classifyAndImport throws existingActivityConflict for this
        // one item — the same established pattern as
        // partialBatchFailureLeavesFailedItemEditableWithoutDuplicating.
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
        #expect(viewModel.needsAttentionItems.map(\.externalEventKey).contains(conflictItem.externalEventKey))

        // Now mark a DIFFERENT, unrelated item Ready — this triggers the
        // required re-evaluation of the rest of the queue.
        viewModel.setStagedAthlete(fixture.athleteId, for: otherItem.externalEventKey)
        viewModel.markReady(for: otherItem.externalEventKey)

        // The Needs Attention item survived, untouched.
        #expect(viewModel.needsAttentionItems.map(\.externalEventKey).contains(conflictItem.externalEventKey))
        #expect(viewModel.failedImportReasons[conflictItem.externalEventKey] == CalendarPlanningStrings.existingActivityConflictError)
    }

    // MARK: - VX-038 unified recognition follow-up: Ignore lifecycle (required tests 21-22)

    @Test("VX-038 unified test 21: a prior Ignore -> Review again history never blocks normal recognition for the SAME event")
    @MainActor
    func priorIgnoreReviewAgainDoesNotBlockNormalRecognition() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let originalItem = try #require(viewModel.reviewQueue.first)
        viewModel.ignore(originalItem)
        viewModel.restore(try #require(viewModel.ignoredItems.first))
        let restoredItem = try #require(viewModel.reviewQueue.first)

        viewModel.setStagedAthlete(fixture.athleteId, for: restoredItem.externalEventKey)
        #expect(viewModel.stagedClassification(for: restoredItem.externalEventKey).satisfiesMinimumImportRequirements)
        viewModel.markReady(for: restoredItem.externalEventKey)
        #expect(viewModel.readyToImportItems.map(\.externalEventKey).contains(restoredItem.externalEventKey))
    }

    @Test("VX-038 unified test 22: a newer explicit Ready classification can assist a matching pending event even though an older Ignore decision exists for a DIFFERENT prior occurrence, without deleting that canonical Ignore history")
    @MainActor
    func newerExplicitReadySupersedesStaleIgnoreDerivedAssistance() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-ignored", title: "Hockey training", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let ignoredOriginal = try #require(viewModel.reviewQueue.first)
        viewModel.ignore(ignoredOriginal)
        #expect(viewModel.ignoredItems.map(\.externalEventKey).contains(ignoredOriginal.externalEventKey))

        addEvent(fixture, identifier: "evt-A", title: "Hockey training", hoursFromReference: 24)
        addEvent(fixture, identifier: "evt-B", title: "Hockey training", hoursFromReference: 48)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })
        viewModel.setStagedAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.markReady(for: itemA.externalEventKey)

        let itemB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-B" })
        #expect(viewModel.stagedClassification(for: itemB.externalEventKey).athleteId == fixture.athleteId)

        // The original Ignore decision is untouched — canonical history
        // was never deleted to achieve this.
        #expect(viewModel.ignoredItems.map(\.externalEventKey).contains(ignoredOriginal.externalEventKey))
    }

    // MARK: - VX-038 unified recognition follow-up: persistence boundary (required tests 23-30)

    @Test("VX-038 unified test 23/24/25: Ready alone — for both ordinary and Split — creates no PlannedActivity, no CalendarImportDecision, and no persisted DecompositionEvidence")
    @MainActor
    func readyAloneCreatesNoDurableTruthForEitherShape() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-single", title: "Swim practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-split", title: "Hockey training", hoursFromReference: 24)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let singleItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-single" })
        let splitItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-split" })

        viewModel.setStagedAthlete(fixture.athleteId, for: singleItem.externalEventKey)
        viewModel.markReady(for: singleItem.externalEventKey)

        viewModel.setSplitEnabled(true, for: splitItem.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: splitItem.externalEventKey)
        viewModel.addSplitChild(for: splitItem.externalEventKey)
        viewModel.markReady(for: splitItem.externalEventKey)

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
        #expect(try fixture.decompositionEvidenceRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
    }

    @Test("VX-038 unified test 26/27: bulk import uses the existing canonical classifyAndImport/classifyAndImportSplit paths, and an imported Split creates durable decomposition evidence")
    @MainActor
    func bulkImportUsesCanonicalPathsAndCreatesDurableSplitEvidence() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-single", title: "Swim practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-split", title: "Hockey training", hoursFromReference: 24)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let singleItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-single" })
        let splitItem = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-split" })

        viewModel.setStagedAthlete(fixture.athleteId, for: singleItem.externalEventKey)
        viewModel.markReady(for: singleItem.externalEventKey)

        viewModel.setSplitEnabled(true, for: splitItem.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: splitItem.externalEventKey)
        viewModel.addSplitChild(for: splitItem.externalEventKey)
        let secondChildId = viewModel.stagedClassification(for: splitItem.externalEventKey).splitChildren[1].id
        viewModel.updateSplitChild(secondChildId, for: splitItem.externalEventKey) {
            $0.startOffsetMinutes = 70
            $0.durationMinutes = 60
        }
        viewModel.markReady(for: splitItem.externalEventKey)

        viewModel.bulkImportReadyItems()

        let imported = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(imported.count == 3) // 1 single + 2 split children
        let decisions = try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId)
        #expect(decisions.count == 2)
        let evidence = try fixture.decompositionEvidenceRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId)
        #expect(evidence.count == 1)
    }

    @Test("VX-038 unified test 28/29: a fresh coordination service and fresh ViewModel, against a genuinely closed-and-reopened on-disk store, can still suggest the Split for a later matching occurrence from durable evidence")
    @MainActor
    func freshServiceAndViewModelAgainstReopenedStoreSuggestSplitFromDurableEvidence() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("vx038-unified-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: AppSchemaV10.self)

        var workspaceId: WorkspaceId!
        var athleteId: AthleteId!
        var sourceId: ExternalPlanningSourceId!
        let calendarProvider = FakeCalendarEventProvider()
        let firstStart = Self.referenceDate.addingTimeInterval(3600)
        let secondStart = firstStart.addingTimeInterval(7 * 24 * 3600)
        calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: firstStart, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: firstStart, endDate: firstStart.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: secondStart, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: secondStart, endDate: secondStart.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            )
        ]

        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let planningRepository = PlanningRepository(modelContext: container.mainContext)
            let trainingRepository = TrainingRepository(modelContext: container.mainContext)
            let athleteRepository = AthleteRepository(modelContext: container.mainContext)
            let sportRepository = SportRepository(modelContext: container.mainContext)
            let sourceRepository = ExternalPlanningSourceRepository(modelContext: container.mainContext)
            let importDecisionRepository = CalendarImportDecisionRepository(modelContext: container.mainContext)
            let legacyMappingRepository = CalendarPlanningMappingRepository(modelContext: container.mainContext)
            let decomposedActivityLinkRepository = DecomposedActivityLinkRepository(modelContext: container.mainContext)
            let decompositionEvidenceRepository = DecompositionEvidenceRepository(modelContext: container.mainContext)
            let planningService = PlanningService(repository: planningRepository)
            let trainingService = TrainingService(repository: trainingRepository)
            let coordinationService = CalendarPlanningCoordinationService(
                sourceRepository: sourceRepository,
                importDecisionRepository: importDecisionRepository,
                legacyMappingRepository: legacyMappingRepository,
                decomposedActivityLinkRepository: decomposedActivityLinkRepository,
                decompositionEvidenceRepository: decompositionEvidenceRepository,
                calendarEventProvider: calendarProvider,
                planningService: planningService,
                trainingService: trainingService,
                athleteRepository: athleteRepository,
                dateProvider: FixedDateProvider(now: Self.referenceDate)
            )
            let workspace = WorkspaceId()
            let athlete = try athleteRepository.createAthlete(
                workspaceId: workspace, givenName: "Runner", birthDate: LocalDate(year: 2012, month: 3, day: 1),
                timeZoneId: Self.timeZoneId, developmentStage: .parentLed
            )
            let source = try coordinationService.createSource(
                forWorkspace: workspace, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
            )
            try coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
            workspaceId = workspace
            athleteId = athlete.athleteId
            sourceId = source.externalPlanningSourceId

            let viewModel = CalendarImportReviewViewModel(
                calendarPlanningCoordinationService: coordinationService,
                athleteRepository: athleteRepository, sportRepository: sportRepository, source: source, actorId: ActorId()
            )
            viewModel.load()
            let firstItem = try #require(viewModel.reviewQueue.first { $0.event.occurrenceDate == firstStart })

            viewModel.setSplitEnabled(true, for: firstItem.externalEventKey)
            viewModel.setSplitAthlete(athlete.athleteId, for: firstItem.externalEventKey)
            viewModel.addSplitChild(for: firstItem.externalEventKey)
            let secondChildId = viewModel.stagedClassification(for: firstItem.externalEventKey).splitChildren[1].id
            viewModel.updateSplitChild(secondChildId, for: firstItem.externalEventKey) {
                $0.startOffsetMinutes = 70
                $0.durationMinutes = 60
            }
            viewModel.markReady(for: firstItem.externalEventKey)
            viewModel.bulkImportReadyItems()

            #expect(try coordinationService.hasDecompositionEvidence(for: source) == true)
        }

        let reopenedContainer = try ModelContainer(
            for: schema, migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let reopenedPlanningRepository = PlanningRepository(modelContext: reopenedContainer.mainContext)
        let reopenedTrainingRepository = TrainingRepository(modelContext: reopenedContainer.mainContext)
        let reopenedAthleteRepository = AthleteRepository(modelContext: reopenedContainer.mainContext)
        let reopenedSportRepository = SportRepository(modelContext: reopenedContainer.mainContext)
        let reopenedSourceRepository = ExternalPlanningSourceRepository(modelContext: reopenedContainer.mainContext)
        let reopenedImportDecisionRepository = CalendarImportDecisionRepository(modelContext: reopenedContainer.mainContext)
        let reopenedLegacyMappingRepository = CalendarPlanningMappingRepository(modelContext: reopenedContainer.mainContext)
        let reopenedDecomposedActivityLinkRepository = DecomposedActivityLinkRepository(modelContext: reopenedContainer.mainContext)
        let reopenedDecompositionEvidenceRepository = DecompositionEvidenceRepository(modelContext: reopenedContainer.mainContext)
        let reopenedPlanningService = PlanningService(repository: reopenedPlanningRepository)
        let reopenedTrainingService = TrainingService(repository: reopenedTrainingRepository)
        let reopenedCoordinationService = CalendarPlanningCoordinationService(
            sourceRepository: reopenedSourceRepository,
            importDecisionRepository: reopenedImportDecisionRepository,
            legacyMappingRepository: reopenedLegacyMappingRepository,
            decomposedActivityLinkRepository: reopenedDecomposedActivityLinkRepository,
            decompositionEvidenceRepository: reopenedDecompositionEvidenceRepository,
            calendarEventProvider: calendarProvider,
            planningService: reopenedPlanningService,
            trainingService: reopenedTrainingService,
            athleteRepository: reopenedAthleteRepository,
            dateProvider: FixedDateProvider(now: Self.referenceDate)
        )
        let reopenedSource = try #require(try reopenedSourceRepository.fetch(byId: sourceId))
        let reopenedViewModel = CalendarImportReviewViewModel(
            calendarPlanningCoordinationService: reopenedCoordinationService,
            athleteRepository: reopenedAthleteRepository, sportRepository: reopenedSportRepository, source: reopenedSource, actorId: ActorId()
        )
        reopenedViewModel.load()
        let secondItem = try #require(reopenedViewModel.reviewQueue.first { $0.event.occurrenceDate == secondStart })
        let staged = reopenedViewModel.stagedClassification(for: secondItem.externalEventKey)
        #expect(staged.isSplitEnabled)
        #expect(staged.isSuggestedSplitPrefill)
        #expect(staged.splitAthleteId == athleteId)
        #expect(staged.splitChildren.map(\.durationMinutes) == [30, 60])
    }

    @Test("VX-038 unified test 30: no automatic Import occurs anywhere in the Ready-time recognition flow, even once both A and B legitimately appear Ready")
    @MainActor
    func noAutomaticImportOccursInReadyTimeRecognitionFlow() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-A", title: "Hockey training", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-B", title: "Hockey training", hoursFromReference: 24)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })

        viewModel.setSplitEnabled(true, for: itemA.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.addSplitChild(for: itemA.externalEventKey)
        viewModel.markReady(for: itemA.externalEventKey)

        let itemB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-B" })
        #expect(viewModel.stagedClassification(for: itemB.externalEventKey).isSuggestedSplitPrefill)
        // Lead Review follow-up (Blocker 1): B now arrives already Ready
        // too — the SAME confirmation status as the ordinary case — so
        // it legitimately appears in readyToImportItems alongside A.
        // Neither was ever imported by this flow alone, though: no
        // PlannedActivity exists until the Parent's own explicit
        // bulkImportReadyItems() call, which this test never makes.
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(viewModel.readyToImportItems.map(\.externalEventKey).contains(itemA.externalEventKey))
        #expect(viewModel.readyToImportItems.map(\.externalEventKey).contains(itemB.externalEventKey))
    }

    // MARK: - Lead Review follow-up (PR #56): Ready semantic parity (Blocker 1)

    /// Required tests 1-4/6: Single and Split Ready-time recognition
    /// must share the SAME confirmation/import-workflow lifecycle —
    /// proven BEHAVIORALLY (a single bulk-import call imports both
    /// without any further Parent action on either), not merely by
    /// comparing boolean fields.
    @Test("VX-038 Lead Review (Blocker 1) test: Single and Split Ready-time recognition share the SAME confirmation and import-workflow lifecycle")
    @MainActor
    func singleAndSplitReadyRecognitionShareTheSameLifecycle() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-single-A", title: "Swim practice", hoursFromReference: 1)
        addEvent(fixture, identifier: "evt-single-B", title: "Swim practice", hoursFromReference: 24)
        addEvent(fixture, identifier: "evt-split-C", title: "Hockey training", hoursFromReference: 2)
        addEvent(fixture, identifier: "evt-split-D", title: "Hockey training", hoursFromReference: 25)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemSingleA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-single-A" })
        let itemSplitC = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-split-C" })

        viewModel.setStagedAthlete(fixture.athleteId, for: itemSingleA.externalEventKey)
        viewModel.markReady(for: itemSingleA.externalEventKey)

        viewModel.setSplitEnabled(true, for: itemSplitC.externalEventKey)
        viewModel.setSplitAthlete(fixture.athleteId, for: itemSplitC.externalEventKey)
        viewModel.addSplitChild(for: itemSplitC.externalEventKey)
        viewModel.markReady(for: itemSplitC.externalEventKey)

        let itemSingleB = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-single-B" })
        let itemSplitD = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-split-D" })

        // Field-level parity: shape alone never determines readiness.
        let stagedB = viewModel.stagedClassification(for: itemSingleB.externalEventKey)
        let stagedD = viewModel.stagedClassification(for: itemSplitD.externalEventKey)
        #expect(stagedB.isConfirmedReady == stagedD.isConfirmedReady)
        #expect(stagedB.isConfirmedReady)

        // Behavioral parity: WITHOUT any further Parent action on B or
        // D, one bulk import call imports every currently-Ready item —
        // including both B and D, exactly like it already does for A
        // and C. This is the actual workflow proof, not just a field
        // comparison.
        viewModel.bulkImportReadyItems()
        let imported = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        let importedKeys = Set(imported.map(\.externalSourceId))
        #expect(importedKeys.contains(itemSingleA.externalEventKey))
        #expect(importedKeys.contains(itemSingleB.externalEventKey))
        #expect(importedKeys.contains(itemSplitC.externalEventKey))
        #expect(importedKeys.contains(itemSplitD.externalEventKey))
    }

    /// Required test 5: a WEAK Similar-Event Suggestion (V1.2 — no exact
    /// match) must still arrive un-confirmed — this round only changes
    /// the session-Ready tier's own confirmation rule for an EXACT
    /// match; weaker evidence is untouched.
    @Test("VX-038 Lead Review test: a weak Similar-Event Suggestion still arrives NOT Ready — evidence strength, not shape, controls confirmation")
    @MainActor
    func weakSimilarEventSuggestionStillArrivesNotReady() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.setStagedAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        firstViewModel.markReady(for: firstItem.externalEventKey)
        firstViewModel.bulkImportReadyItems()

        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14 tirsdag", hoursFromReference: 24)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        let staged = secondViewModel.stagedClassification(for: secondItem.externalEventKey)
        #expect(staged.athleteId == fixture.athleteId)
        #expect(!staged.isConfirmedReady)
    }

    // MARK: - Lead Review follow-up (PR #56): recurring conflict must veto title fallback (Blocker 2)

    /// Required tests 7/8: two Parent-confirmed Ready events sharing the
    /// SAME recurring eventIdentifier but carrying DIFFERENT shapes make
    /// the recurring tier conflicted for that series — evaluating a
    /// LATER occurrence of that same series must receive NO recognition
    /// at all, even though its own exact title ("Hockey" — shared with
    /// occurrence A only, not B) would otherwise resolve unambiguously
    /// through the title tier alone. Stronger conflicting evidence must
    /// veto the weaker fallback, never be silently bypassed by it.
    @Test("VX-038 Lead Review (Blocker 2) test 7/8: a recurring-series conflict vetoes exact-title fallback, even when the title index alone would otherwise resolve unambiguously")
    @MainActor
    func recurringConflictVetoesTitleFallback() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        let occurrenceA = Self.referenceDate.addingTimeInterval(3600)
        let occurrenceB = occurrenceA.addingTimeInterval(24 * 3600)
        let occurrenceC = occurrenceA.addingTimeInterval(48 * 3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "SERIES-1", occurrenceDate: occurrenceA, calendarIdentifier: "cal-familie", title: "Hockey",
                startDate: occurrenceA, endDate: occurrenceA.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "SERIES-1", occurrenceDate: occurrenceB, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: occurrenceB, endDate: occurrenceB.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "SERIES-1", occurrenceDate: occurrenceC, calendarIdentifier: "cal-familie", title: "Hockey",
                startDate: occurrenceC, endDate: occurrenceC.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            )
        ]
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.occurrenceDate == occurrenceA })
        let itemB = try #require(viewModel.reviewQueue.first { $0.event.occurrenceDate == occurrenceB })

        viewModel.setStagedAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.markReady(for: itemA.externalEventKey)

        // A DIFFERENT shape, marked Ready on ANOTHER occurrence of the
        // SAME recurring series — this is what makes the recurring tier
        // conflicted for "SERIES-1".
        viewModel.setStagedAthlete(secondAthleteId, for: itemB.externalEventKey)
        viewModel.markReady(for: itemB.externalEventKey)

        let itemC = try #require(viewModel.reviewQueue.first { $0.event.occurrenceDate == occurrenceC })
        let stagedC = viewModel.stagedClassification(for: itemC.externalEventKey)
        // NO recognition at all — the recurring conflict vetoes the
        // exact-title fallback, even though "Hockey" alone (shared only
        // with occurrence A's own title) would otherwise resolve
        // unambiguously via the title tier.
        #expect(stagedC.athleteId == nil)
        #expect(!stagedC.isConfirmedReady)
    }

    /// Required test 9: when the recurring tier has NO evidence at all
    /// (a genuinely different series with no Ready siblings of its
    /// own), the exact-title fallback still applies normally.
    @Test("VX-038 Lead Review (Blocker 2) test 9: exact-title fallback still applies when the recurring tier has no evidence at all")
    @MainActor
    func titleFallbackAppliesWhenRecurringTierHasNoEvidence() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-A", title: "Hockey", hoursFromReference: 1)
        let occurrenceC = Self.referenceDate.addingTimeInterval(48 * 3600)
        var events = fixture.calendarProvider.eventsByCalendar["cal-familie"] ?? []
        events.append(
            ExternalCalendarEvent(
                eventIdentifier: "SERIES-2", occurrenceDate: occurrenceC, calendarIdentifier: "cal-familie", title: "Hockey",
                startDate: occurrenceC, endDate: occurrenceC.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            )
        )
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = events
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-A" })
        viewModel.setStagedAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.markReady(for: itemA.externalEventKey)

        let itemC = try #require(viewModel.reviewQueue.first { $0.event.eventIdentifier == "SERIES-2" })
        let stagedC = viewModel.stagedClassification(for: itemC.externalEventKey)
        // itemC is recurring ("SERIES-2"), which has NO Ready evidence
        // of its own — falls through cleanly to the exact-title
        // fallback, which DOES resolve (A shares the same "Hockey" title).
        #expect(stagedC.athleteId == fixture.athleteId)
        #expect(stagedC.isConfirmedReady)
    }

    /// Required test 10: two AGREEING Ready shapes for the SAME
    /// recurring series (no conflict) still produce recognition
    /// normally through the recurring tier.
    @Test("VX-038 Lead Review (Blocker 2) test 10: two agreeing Ready shapes for the same recurring series still produce recognition normally")
    @MainActor
    func agreeingRecurringReadyShapesStillProduceRecognition() throws {
        let fixture = try makeFixture()
        let occurrenceA = Self.referenceDate.addingTimeInterval(3600)
        let occurrenceB = occurrenceA.addingTimeInterval(24 * 3600)
        let occurrenceC = occurrenceA.addingTimeInterval(48 * 3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "SERIES-3", occurrenceDate: occurrenceA, calendarIdentifier: "cal-familie", title: "Hockey",
                startDate: occurrenceA, endDate: occurrenceA.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "SERIES-3", occurrenceDate: occurrenceB, calendarIdentifier: "cal-familie", title: "Hockey",
                startDate: occurrenceB, endDate: occurrenceB.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "SERIES-3", occurrenceDate: occurrenceC, calendarIdentifier: "cal-familie", title: "Hockey",
                startDate: occurrenceC, endDate: occurrenceC.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            )
        ]
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let itemA = try #require(viewModel.reviewQueue.first { $0.event.occurrenceDate == occurrenceA })
        let itemB = try #require(viewModel.reviewQueue.first { $0.event.occurrenceDate == occurrenceB })

        viewModel.setStagedAthlete(fixture.athleteId, for: itemA.externalEventKey)
        viewModel.markReady(for: itemA.externalEventKey)
        viewModel.setStagedAthlete(fixture.athleteId, for: itemB.externalEventKey)
        viewModel.markReady(for: itemB.externalEventKey)

        let itemC = try #require(viewModel.reviewQueue.first { $0.event.occurrenceDate == occurrenceC })
        let stagedC = viewModel.stagedClassification(for: itemC.externalEventKey)
        #expect(stagedC.athleteId == fixture.athleteId)
        #expect(stagedC.isConfirmedReady)
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
