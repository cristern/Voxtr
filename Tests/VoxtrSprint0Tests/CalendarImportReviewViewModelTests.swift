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

    // MARK: - 1, 2, 3: staging never persists; readiness is derived

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

    @Test("Complete staged classification (Athlete chosen) makes an event Ready — it moves from needsReviewItems to readyToImportItems")
    @MainActor
    func completeStagedClassificationBecomesReady() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        #expect(viewModel.needsReviewItems.count == 1)
        #expect(viewModel.readyToImportItems.isEmpty)

        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)

        #expect(viewModel.needsReviewItems.isEmpty)
        #expect(viewModel.readyToImportItems.count == 1)
        #expect(viewModel.readyToImportCount == 1)
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

        viewModel.bulkImportReadyItems()

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(viewModel.reviewQueue.count == 1)
        #expect(viewModel.needsReviewItems.count == 1)
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
        viewModel.setStagedAthlete(fixture.athleteId, for: conflictItem.externalEventKey)
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
        #expect(stagedAfterFailure.isEditing == true)

        let activitiesAfterFirstAttempt = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activitiesAfterFirstAttempt.count == 2) // the succeeded import + the pre-seeded legacy activity

        // Parent re-confirms the SAME (still-conflicting) staged athlete —
        // this re-collapses the item back to Ready, exactly as picking an
        // athlete always does — and retries the batch. Must not duplicate
        // the already-successful import, and must not create a second
        // activity for the still-conflicting one.
        viewModel.setStagedAthlete(fixture.athleteId, for: conflictItem.externalEventKey)
        #expect(viewModel.readyToImportCount == 1)
        viewModel.bulkImportReadyItems()

        #expect(viewModel.errorMessage != nil)
        let activitiesAfterRetry = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activitiesAfterRetry.count == 2)
        #expect(viewModel.reviewQueue.first?.externalEventKey == conflictItem.externalEventKey)
    }

    // MARK: - 8: Edit restores editable state without persisting

    @Test("Tapping Edit on a Ready item restores its editable classification state without persisting anything")
    @MainActor
    func editOnReadyItemRestoresEditableStateWithoutPersisting() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Team Practice", hoursFromReference: 1)
        let viewModel = makeViewModel(fixture)
        viewModel.load()
        let item = try #require(viewModel.reviewQueue.first)
        viewModel.setStagedAthlete(fixture.athleteId, for: item.externalEventKey)
        #expect(viewModel.readyToImportItems.count == 1)

        viewModel.beginEditing(for: item.externalEventKey)

        #expect(viewModel.needsReviewItems.count == 1)
        #expect(viewModel.readyToImportItems.isEmpty)
        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        // Values are preserved, not cleared.
        #expect(staged.athleteId == fixture.athleteId)
        #expect(staged.isEditing == true)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: fixture.source.externalPlanningSourceId).isEmpty)
    }

    // MARK: - 13, 14: remembered prefill is presentation-only and overridable

    @Test("A remembered prefill (from a prior exact-title import) never creates a PlannedActivity by itself — only an explicit bulk import does")
    @MainActor
    func rememberedPrefillAloneNeverCreatesPlannedActivity() throws {
        let fixture = try makeFixture()
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.setStagedAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        firstViewModel.setStagedActivityType(.teamTraining, for: firstItem.externalEventKey)
        firstViewModel.bulkImportReadyItems()
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 1)

        // A NEW, later occurrence of the exact same normalized title.
        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })

        let staged = secondViewModel.stagedClassification(for: secondItem.externalEventKey)
        #expect(staged.athleteId == fixture.athleteId)
        #expect(staged.activityType == .teamTraining)
        // Prefilled -> immediately Ready, but NOT imported — merely
        // presentation assistance.
        #expect(secondViewModel.readyToImportItems.count == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 1)
    }

    @Test("The Parent can override a remembered prefill before bulk import, and the override (not the remembered value) is what gets imported")
    @MainActor
    func parentCanOverrideRememberedPrefillBeforeBulkImport() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        addEvent(fixture, identifier: "evt-1", title: "Hockeytrening U14", hoursFromReference: 1)
        let firstViewModel = makeViewModel(fixture)
        firstViewModel.load()
        let firstItem = try #require(firstViewModel.reviewQueue.first)
        firstViewModel.setStagedAthlete(fixture.athleteId, for: firstItem.externalEventKey)
        firstViewModel.bulkImportReadyItems()

        addEvent(fixture, identifier: "evt-2", title: "Hockeytrening U14", hoursFromReference: 48)
        let secondViewModel = makeViewModel(fixture)
        secondViewModel.load()
        let secondItem = try #require(secondViewModel.reviewQueue.first { $0.event.eventIdentifier == "evt-2" })
        #expect(secondViewModel.stagedClassification(for: secondItem.externalEventKey).athleteId == fixture.athleteId)

        // Parent explicitly overrides to the sibling instead.
        secondViewModel.setStagedAthlete(secondAthleteId, for: secondItem.externalEventKey)
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
