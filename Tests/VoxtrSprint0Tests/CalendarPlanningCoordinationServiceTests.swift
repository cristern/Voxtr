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
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.
// `FakeCalendarEventProvider` below is the one shared type this file
// defines for itself (never real EventKit) — matching this project's own
// "every test file builds its own inline fakes" convention, not a
// cross-file shared helper.

/// A deterministic, in-memory stand-in for `EventKitCalendarEventProvider`
/// — never touches real EventKit. `events` is keyed by calendar identifier
/// so a test can script exactly what "the external source currently says"
/// for one or more calendars, and change it between reconciliation calls
/// to simulate an update/disappearance.
///
/// `unavailableCalendars` lets a test simulate the OTHER genuinely
/// distinct failure mode — a source that cannot currently be read at all
/// — as opposed to `eventsByCalendar` returning `[]` for a calendar
/// identifier, which is a genuine, authoritative "read successfully,
/// zero matching events right now." The production
/// `EventKitCalendarEventProvider` never conflates these two; this fake
/// must not either.
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

@Suite("CalendarPlanningCoordinationService (Family-Owned Calendar Sources V1, Lead Review follow-up)", .serialized)
struct CalendarPlanningCoordinationServiceTests {

    private static let referenceDate = Date(timeIntervalSince1970: 1_767_312_000)
    private static let timeZoneId = TimeZoneId(rawValue: "Europe/Oslo")

    private struct Fixture {
        let planningService: PlanningService
        let trainingService: TrainingService
        let athleteRepository: AthleteRepository
        let sourceRepository: ExternalPlanningSourceRepository
        let importDecisionRepository: CalendarImportDecisionRepository
        let legacyMappingRepository: CalendarPlanningMappingRepository
        let calendarProvider: FakeCalendarEventProvider
        let coordinationService: CalendarPlanningCoordinationService
        /// Family isolation test only — `CalendarImportReviewViewModel`'s
        /// third constructor dependency; not used by any coordination-
        /// service-level test in this file.
        let sportRepository: SportRepository
        let workspaceId: WorkspaceId
        let athleteId: AthleteId
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
        return Fixture(
            planningService: planningService,
            trainingService: trainingService,
            athleteRepository: athleteRepository,
            sourceRepository: sourceRepository,
            importDecisionRepository: importDecisionRepository,
            legacyMappingRepository: legacyMappingRepository,
            calendarProvider: calendarProvider,
            coordinationService: coordinationService,
            sportRepository: sportRepository,
            workspaceId: workspaceId,
            athleteId: athlete.athleteId
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

    // MARK: - Blocker 1: family/workspace ownership

    // Required test 1: source belongs to one canonical family/workspace.
    @Test("A created source carries its owning workspace, and fetchSources(forWorkspace:) returns it")
    @MainActor
    func sourceBelongsToOneCanonicalWorkspace() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        #expect(source.externalContainerIdentifier == "cal-familie")
        #expect(source.isEnabled == false)

        let sources = try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId)
        #expect(sources.count == 1)
        #expect(sources.first?.externalPlanningSourceId == source.externalPlanningSourceId)
    }

    // Required test 2: source lists are family-isolated.
    @Test("A source created for one workspace never appears in a different workspace's fetchSources(forWorkspace:)")
    @MainActor
    func sourceListsAreFamilyIsolated() throws {
        let fixture = try makeFixture()
        let otherWorkspaceId = WorkspaceId()
        _ = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )

        let ownSources = try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId)
        let otherSources = try fixture.coordinationService.fetchSources(forWorkspace: otherWorkspaceId)
        #expect(ownSources.count == 1)
        #expect(otherSources.isEmpty)
    }

    // Required test 3: same external calendar identifier in two
    // workspaces does not collapse.
    @Test("Two different workspaces can each connect a calendar sharing the same externalContainerIdentifier without colliding or collapsing")
    @MainActor
    func sameCalendarIdentifierInTwoWorkspacesDoesNotCollapse() throws {
        let fixture = try makeFixture()
        let otherWorkspaceId = WorkspaceId()
        let ownSource = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        let otherSource = try fixture.coordinationService.createSource(
            forWorkspace: otherWorkspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie (other family)"
        )

        #expect(ownSource.externalPlanningSourceId != otherSource.externalPlanningSourceId)
        #expect(try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId).count == 1)
        #expect(try fixture.coordinationService.fetchSources(forWorkspace: otherWorkspaceId).count == 1)
    }

    @Test("Creating a source for an already-CONNECTED calendar in the SAME workspace throws duplicateSource")
    @MainActor
    func duplicateSourceRejectedWithinSameWorkspace() throws {
        let fixture = try makeFixture()
        _ = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        #expect(throws: CalendarPlanningCoordinationError.duplicateSource) {
            try fixture.coordinationService.createSource(
                forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie (renamed)"
            )
        }
    }

    @Test("The SAME source's events can be classified to different athletes in the same workspace, each with its own explicit Sport/Activity Type")
    @MainActor
    func sameSourceClassifiesToDifferentAthletes() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-oliver", calendarIdentifier: "cal-familie", title: "Oliver's Football",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-sibling", calendarIdentifier: "cal-familie", title: "Sibling's Handball",
                startDate: start.addingTimeInterval(7200), endDate: start.addingTimeInterval(10800), isAllDay: false, isRecurring: false
            )
        ]

        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        #expect(queue.count == 2)
        let oliverItem = try #require(queue.first { $0.event.eventIdentifier == "evt-oliver" })
        let siblingItem = try #require(queue.first { $0.event.eventIdentifier == "evt-sibling" })

        let actorId = ActorId()
        let oliverActivity = try fixture.coordinationService.classifyAndImport(
            oliverItem, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: actorId
        )
        let siblingActivity = try fixture.coordinationService.classifyAndImport(
            siblingItem, for: source, athleteId: secondAthleteId, sportId: nil, activityType: .teamTraining, decidedBy: actorId
        )

        #expect(oliverActivity.athleteId == fixture.athleteId.rawValue)
        #expect(oliverActivity.activityType == .individualTraining)
        #expect(siblingActivity.athleteId == secondAthleteId.rawValue)
        #expect(siblingActivity.activityType == .teamTraining)
        #expect(oliverActivity.plannedActivityId != siblingActivity.plannedActivityId)

        // Both events are now decided — neither remains in the review
        // queue.
        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).isEmpty)
    }

    @Test("An unclassified event never becomes a PlannedActivity — reconcile() never creates, only fetchReviewQueue() surfaces it")
    @MainActor
    func unclassifiedEventNeverBecomesPlannedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]

        let outcome = try fixture.coordinationService.reconcile(source)
        #expect(outcome.updated == 0)
        #expect(outcome.cancelled == 0)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)

        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        #expect(queue.count == 1)
        #expect(queue.first?.event.eventIdentifier == "evt-1")
    }

    @Test("Ignoring an event never creates a PlannedActivity, and it never reappears in the review queue")
    @MainActor
    func ignoredEventNeverBecomesPlannedActivityAndNeverResurfaces() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        try fixture.coordinationService.ignore(item, for: source, decidedBy: ActorId())

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).isEmpty)
        // Item 2 (runtime fix): exactly one .ignored decision was
        // persisted — never more, never an .imported one.
        let allDecisions = try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId)
        #expect(allDecisions.count == 1)
        #expect(allDecisions.first?.status == .ignored)

        // Even a fresh fetch (simulating the Parent reopening Review
        // later) never resurfaces an ignored event.
        let outcome = try fixture.coordinationService.reconcile(source)
        #expect(outcome.updated == 0)
        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).isEmpty)
    }

    // MARK: - Runtime fix: Ignored section read model + restore ("Review again")

    @Test("Item 4: fetchIgnoredReviewItems returns an ignored event that is still within the current external provider horizon")
    @MainActor
    func fetchIgnoredReviewItemsReturnsCurrentHorizonIgnoredEvents() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.ignore(item, for: source, decidedBy: ActorId())

        let ignoredItems = try fixture.coordinationService.fetchIgnoredReviewItems(for: source)

        #expect(ignoredItems.count == 1)
        #expect(ignoredItems.first?.externalEventKey == item.externalEventKey)
        // Never shown as pending — the two read models are disjoint.
        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).isEmpty)
    }

    @Test("Item 5: an ignored event whose external event has since disappeared from the provider horizon is no longer returned by fetchIgnoredReviewItems")
    @MainActor
    func fetchIgnoredReviewItemsExcludesEventsNoLongerInHorizon() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.ignore(item, for: source, decidedBy: ActorId())
        #expect(try fixture.coordinationService.fetchIgnoredReviewItems(for: source).count == 1)

        // The event itself disappears from the source's calendar (e.g.
        // it was deleted or moved outside the review window) — the
        // decision row still exists, but it must never be surfaced as
        // an active ignored row without a corresponding real event.
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = []

        #expect(try fixture.coordinationService.fetchIgnoredReviewItems(for: source).isEmpty)
    }

    @Test("Item 6/7/8: restoreIgnoredEvent removes only the matching .ignored decision, creates no PlannedActivity, and the event naturally reappears in Needs Review")
    @MainActor
    func restoreIgnoredEventReturnsEventToNeedsReview() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.ignore(item, for: source, decidedBy: ActorId())
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId).count == 1)

        try fixture.coordinationService.restoreIgnoredEvent(item.externalEventKey, for: source)

        // Item 6: the matching decision is gone — no decision at all
        // remains for this source.
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId).isEmpty)
        // Item 7: no PlannedActivity was ever created by restoring.
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        // Item 8: the event naturally reappears as pending, and no
        // longer shows as an active ignored row.
        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        #expect(queue.count == 1)
        #expect(queue.first?.externalEventKey == item.externalEventKey)
        #expect(try fixture.coordinationService.fetchIgnoredReviewItems(for: source).isEmpty)
    }

    @Test("Item 9: restoreIgnoredEvent cannot remove an .imported decision — it throws decisionNotIgnored and leaves the decision and its PlannedActivity untouched")
    @MainActor
    func restoreCannotRemoveImportedDecision() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        #expect(throws: CalendarPlanningCoordinationError.decisionNotIgnored) {
            try fixture.coordinationService.restoreIgnoredEvent(item.externalEventKey, for: source)
        }

        let decisions = try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId)
        #expect(decisions.count == 1)
        #expect(decisions.first?.status == .imported)
        #expect(try fixture.planningService.fetchPlannedActivity(byId: imported.plannedActivityId) != nil)
    }

    @Test("Item 10: restoreIgnoredEvent is source-scoped — an ignored decision on a DIFFERENT source (even sharing the same externalEventKey text) is never restored by a call scoped to this source")
    @MainActor
    func restoreIsSourceScoped() throws {
        let fixture = try makeFixture()
        let sourceA = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-a", displayName: "Calendar A"
        )
        let sourceB = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-b", displayName: "Calendar B"
        )
        try fixture.coordinationService.setSourceEnabled(sourceA.externalPlanningSourceId, isEnabled: true)
        try fixture.coordinationService.setSourceEnabled(sourceB.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-b"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-b", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let itemB = try #require(try fixture.coordinationService.fetchReviewQueue(for: sourceB).first)
        try fixture.coordinationService.ignore(itemB, for: sourceB, decidedBy: ActorId())
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: sourceB.externalPlanningSourceId).count == 1)

        // A restore call scoped to sourceA, using sourceB's own event
        // key, must find nothing for sourceA and leave sourceB's
        // decision completely untouched.
        try fixture.coordinationService.restoreIgnoredEvent(itemB.externalEventKey, for: sourceA)

        #expect(try fixture.importDecisionRepository.fetchAll(forSource: sourceB.externalPlanningSourceId).count == 1)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: sourceB.externalPlanningSourceId).first?.status == .ignored)
    }

    @Test("Item 10: restoreIgnoredEvent respects the disabled/disconnected source boundary, failing calmly rather than acting on a stale source")
    @MainActor
    func restoreRespectsDisabledSourceBoundary() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.ignore(item, for: source, decidedBy: ActorId())

        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: false)

        #expect(throws: CalendarPlanningCoordinationError.sourceDisabled) {
            try fixture.coordinationService.restoreIgnoredEvent(item.externalEventKey, for: source)
        }
        // The ignored decision survives the rejected restore attempt.
        let decisions = try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId)
        #expect(decisions.count == 1)
        #expect(decisions.first?.status == .ignored)
    }

    @Test("Calling reconcile() repeatedly after an event is imported never creates a second PlannedActivity")
    @MainActor
    func repeatedSyncNeverDuplicatesImportedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        _ = try fixture.coordinationService.reconcile(source)
        _ = try fixture.coordinationService.reconcile(source)
        _ = try fixture.coordinationService.reconcile(source)

        let activities = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activities.count == 1)
    }

    @Test("reconcile() refreshes an already-imported PlannedActivity's source-owned title/time, preserving its identity and Parent-chosen Sport/Activity Type")
    @MainActor
    func reconcileRefreshesSourceOwnedFieldsOnAlreadyImportedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        // Source-owned title changes; time stays the same week.
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice (Renamed)",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let outcome = try fixture.coordinationService.reconcile(source)
        #expect(outcome.updated == 1)
        #expect(outcome.cancelled == 0)

        let refreshed = try #require(try fixture.planningService.fetchPlannedActivity(byId: imported.plannedActivityId))
        #expect(refreshed.title == "Team Practice (Renamed)")
        // Parent's own classification survives reconciliation untouched.
        #expect(refreshed.activityType == .individualTraining)
        #expect(refreshed.athleteId == fixture.athleteId.rawValue)
    }

    // MARK: - Blocker 2: disabled source cannot discover/classify

    // Required test 4: disabled source returns no review queue.
    @Test("A disabled source's fetchReviewQueue(for:) returns [] even though it has qualifying upcoming events")
    @MainActor
    func disabledSourceReturnsNoReviewQueue() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        // Deliberately left isEnabled == false (the default).
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]

        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).isEmpty)

        let outcome = try fixture.coordinationService.reconcile(source)
        #expect(outcome.updated == 0)
        #expect(outcome.cancelled == 0)
        #expect(outcome.skipped == 0)
    }

    // Required test 5: disabled source cannot classify/import through a
    // stale item.
    @Test("classifyAndImport throws sourceDisabled for a stale CalendarReviewItem captured before the source was disabled")
    @MainActor
    func disabledSourceCannotClassifyThroughStaleItem() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        // Capture the item, and the SOURCE VALUE, while still enabled —
        // exactly what a stale UI would be holding.
        let staleItem = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let staleSource = source

        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: false)

        #expect(throws: CalendarPlanningCoordinationError.sourceDisabled) {
            try fixture.coordinationService.classifyAndImport(
                staleItem, for: staleSource, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
            )
        }
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)

        // Re-enabling makes discovery (and classification) available
        // again.
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).count == 1)
    }

    // MARK: - Blocker 3: disconnect/reconnect preserves stable identity

    // Required test 6: disconnected migrated source is not recreated on
    // next load.
    @Test("A disconnected source is never recreated by migrateLegacySourcesIfNeeded on a later load")
    @MainActor
    func disconnectedMigratedSourceIsNotRecreatedOnNextLoad() throws {
        let fixture = try makeFixture()
        _ = try fixture.legacyMappingRepository.insert(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-familie",
            calendarTitle: "Familie", activityType: .individualTraining, sportId: nil
        )

        let firstRun = try fixture.coordinationService.migrateLegacySourcesIfNeeded(forWorkspace: fixture.workspaceId)
        #expect(firstRun.count == 1)
        let migratedId = try #require(firstRun.first?.externalPlanningSourceId)

        try fixture.coordinationService.disconnectSource(migratedId)
        #expect(try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId).isEmpty)

        // Simulate the Parent reopening the app / reloading the source
        // list — migration runs again against the SAME legacy mapping.
        let secondRun = try fixture.coordinationService.migrateLegacySourcesIfNeeded(forWorkspace: fixture.workspaceId)
        #expect(secondRun.isEmpty)
        #expect(try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId).isEmpty)
    }

    // Required test 7: reconnecting the same family/provider/calendar
    // preserves source ID.
    @Test("Reconnecting the same (workspace, provider, container) tuple after disconnect reuses the existing ExternalPlanningSourceId")
    @MainActor
    func reconnectingSameSourcePreservesId() throws {
        let fixture = try makeFixture()
        let original = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.disconnectSource(original.externalPlanningSourceId)
        #expect(try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId).isEmpty)

        let reconnected = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie (renamed)"
        )

        #expect(reconnected.externalPlanningSourceId == original.externalPlanningSourceId)
        #expect(reconnected.displayName == "Familie (renamed)")
        let sources = try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId)
        #expect(sources.count == 1)
    }

    // Required test 8: decisions remain associated after reconnect.
    @Test("A CalendarImportDecision made before disconnect is still found (and the resulting PlannedActivity unchanged) after reconnect")
    @MainActor
    func decisionsRemainAssociatedAfterReconnect() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        try fixture.coordinationService.disconnectSource(source.externalPlanningSourceId)
        let reconnected = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        #expect(reconnected.externalPlanningSourceId == source.externalPlanningSourceId)

        let decision = try fixture.importDecisionRepository.fetch(
            sourceId: reconnected.externalPlanningSourceId, externalEventKey: item.externalEventKey
        )
        #expect(decision != nil)
        #expect(decision?.plannedActivityId == imported.plannedActivityId.rawValue)
        #expect(try fixture.planningService.fetchPlannedActivity(byId: imported.plannedActivityId) != nil)

        // The already-decided event does not resurface as pending after
        // reconnect.
        try fixture.coordinationService.setSourceEnabled(reconnected.externalPlanningSourceId, isEnabled: true)
        #expect(try fixture.coordinationService.fetchReviewQueue(for: reconnected).isEmpty)
    }

    @Test("Disconnecting a source never touches its already-imported PlannedActivity or LoggedActivity truth")
    @MainActor
    func disconnectingSourcePreservesLoggedActivityTruth() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )
        _ = try fixture.trainingService.logActivity(
            athleteId: fixture.athleteId, plannedActivityId: imported.plannedActivityId,
            activityType: .individualTraining, title: "Team Practice", startedAt: start
        )

        try fixture.coordinationService.disconnectSource(source.externalPlanningSourceId)

        #expect(try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId).isEmpty)
        #expect(try fixture.planningService.fetchPlannedActivity(byId: imported.plannedActivityId) != nil)
        #expect(try fixture.trainingService.fetchLoggedActivities(forPlannedActivity: imported.plannedActivityId).count == 1)
    }

    @Test("An UNAVAILABLE calendar does NOT cancel a previously-imported unperformed future PlannedActivity")
    @MainActor
    func unavailableCalendarCannotMassDelete() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        fixture.calendarProvider.unavailableCalendars.insert("cal-familie")
        #expect(throws: CalendarEventProviderError.calendarUnavailable) {
            try fixture.coordinationService.reconcile(source)
        }

        // The previously-imported activity survives completely
        // untouched — an unavailable read is never treated as "every
        // event disappeared."
        #expect(try fixture.planningService.fetchPlannedActivity(byId: imported.plannedActivityId) != nil)
    }

    @Test("Recurring occurrences sharing one eventIdentifier are classified as distinct PlannedActivities, and moving one occurrence updates only that occurrence")
    @MainActor
    func recurringOccurrenceIdentityRemainsCorrect() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let firstOccurrence = Self.referenceDate.addingTimeInterval(3600)
        let secondOccurrence = firstOccurrence.addingTimeInterval(7 * 24 * 3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: firstOccurrence, calendarIdentifier: "cal-familie", title: "Weekly Practice",
                startDate: firstOccurrence, endDate: firstOccurrence.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: secondOccurrence, calendarIdentifier: "cal-familie", title: "Weekly Practice",
                startDate: secondOccurrence, endDate: secondOccurrence.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            )
        ]

        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        #expect(queue.count == 2)
        // Distinct keys despite sharing eventIdentifier — occurrenceDate
        // participates in identity for a recurring event.
        #expect(Set(queue.map(\.externalEventKey)).count == 2)

        let actorId = ActorId()
        for item in queue {
            try fixture.coordinationService.classifyAndImport(
                item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: actorId
            )
        }
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 2)

        // Move only the first occurrence (detached) — its identity
        // (eventIdentifier + STABLE occurrenceDate) stays the same even
        // though startDate moved.
        let movedStart = firstOccurrence.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: firstOccurrence, calendarIdentifier: "cal-familie", title: "Weekly Practice (moved)",
                startDate: movedStart, endDate: movedStart.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: secondOccurrence, calendarIdentifier: "cal-familie", title: "Weekly Practice",
                startDate: secondOccurrence, endDate: secondOccurrence.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            )
        ]
        let outcome = try fixture.coordinationService.reconcile(source)
        #expect(outcome.updated == 2)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 2)
    }

    @Test("migrateLegacySourcesIfNeeded(forWorkspace:) creates one disabled ExternalPlanningSource per distinct legacy calendarIdentifier owned by that workspace, dropping athlete/sport/activityType, and creates no CalendarImportDecision")
    @MainActor
    func migrateLegacySourcesIfNeededDropsClassificationDefaults() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        // Two legacy mappings for the SAME calendar, two different
        // athletes/sports/activity types, BOTH in the same workspace —
        // simulating exactly the real evidence this migration exists for
        // (one Spond "Familie" calendar, previously mapped once per
        // child).
        _ = try fixture.legacyMappingRepository.insert(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-familie",
            calendarTitle: "Familie", activityType: .individualTraining, sportId: nil
        )
        _ = try fixture.legacyMappingRepository.insert(
            athleteId: secondAthleteId, calendarIdentifier: "cal-familie",
            calendarTitle: "Familie", activityType: .teamTraining, sportId: nil
        )

        let created = try fixture.coordinationService.migrateLegacySourcesIfNeeded(forWorkspace: fixture.workspaceId)
        #expect(created.count == 1)
        #expect(created.first?.externalContainerIdentifier == "cal-familie")
        #expect(created.first?.displayName == "Familie")
        #expect(created.first?.isEnabled == false)

        let sources = try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId)
        #expect(sources.count == 1)
        // No CalendarImportDecision was fabricated from the legacy
        // athlete/sport/activityType values — migration seeds ONLY the
        // container.
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: sources[0].externalPlanningSourceId).isEmpty)

        // Idempotent: calling again is a safe no-op, never a second
        // source for the same calendar.
        let secondRun = try fixture.coordinationService.migrateLegacySourcesIfNeeded(forWorkspace: fixture.workspaceId)
        #expect(secondRun.isEmpty)
        #expect(try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId).count == 1)
    }

    @Test("A legacy mapping whose athlete belongs to a DIFFERENT workspace is never migrated into this workspace's sources, even sharing the same calendarIdentifier")
    @MainActor
    func migrationRespectsWorkspaceIsolation() throws {
        let fixture = try makeFixture()
        let otherWorkspaceId = WorkspaceId()
        let otherAthlete = try fixture.athleteRepository.createAthlete(
            workspaceId: otherWorkspaceId, givenName: "Other Family Child",
            birthDate: LocalDate(year: 2013, month: 6, day: 1), timeZoneId: Self.timeZoneId, developmentStage: .parentLed
        )
        _ = try fixture.legacyMappingRepository.insert(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-familie",
            calendarTitle: "Familie", activityType: .individualTraining, sportId: nil
        )
        _ = try fixture.legacyMappingRepository.insert(
            athleteId: otherAthlete.athleteId, calendarIdentifier: "cal-familie",
            calendarTitle: "Familie (other family)", activityType: .teamTraining, sportId: nil
        )

        let ownMigrated = try fixture.coordinationService.migrateLegacySourcesIfNeeded(forWorkspace: fixture.workspaceId)
        let otherMigrated = try fixture.coordinationService.migrateLegacySourcesIfNeeded(forWorkspace: otherWorkspaceId)

        #expect(ownMigrated.count == 1)
        #expect(otherMigrated.count == 1)
        #expect(ownMigrated.first?.externalPlanningSourceId != otherMigrated.first?.externalPlanningSourceId)
        #expect(try fixture.coordinationService.fetchSources(forWorkspace: fixture.workspaceId).count == 1)
        #expect(try fixture.coordinationService.fetchSources(forWorkspace: otherWorkspaceId).count == 1)
    }

    // MARK: - Blocker 4: existing-activity duplicate prevention

    // Required test 9 & 13: fresh classify/import creates exactly one
    // PlannedActivity + one decision; a pre-existing legacy
    // PlannedActivity carrying the same externalSourceId is adopted, not
    // duplicated (test 10), and a conflicting one is neither duplicated
    // nor silently reassigned (test 11); retry after a partial decision
    // failure is safe (test 12).

    @Test("A normal fresh classifyAndImport creates exactly one PlannedActivity and one CalendarImportDecision")
    @MainActor
    func freshClassifyAndImportCreatesExactlyOneActivityAndDecision() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        let activities = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activities.count == 1)
        #expect(activities.first?.plannedActivityId == imported.plannedActivityId)
        let decision = try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey)
        #expect(decision?.status == .imported)
        #expect(decision?.plannedActivityId == imported.plannedActivityId.rawValue)
    }

    @Test("A pre-existing legacy PlannedActivity carrying the same externalSourceId, with no decision yet, is ADOPTED (linked) rather than duplicated when the Parent's explicit classification matches it exactly")
    @MainActor
    func explicitClassificationMatchingExistingActivityAdoptsIt() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false,
                notes: "External notes that must never overwrite the existing row", location: "External Field"
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        // Simulate a Calendar Planning Source V1 legacy auto-import: a
        // PlannedActivity already exists carrying the exact same
        // externalSourceId/externalSourceType, but no CalendarImportDecision.
        // Its own notes/location are Vǫxtr-owned (e.g. manually entered),
        // and must survive adoption untouched.
        let today = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: fixture.athleteId, weekStart: today)
        let legacyActivity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: "Team Practice", localDate: today, timeZoneId: Self.timeZoneId,
            externalSourceId: item.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType,
            notes: "Existing Vǫxtr-owned notes", location: "Existing Vǫxtr-owned location"
        )

        let result = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        #expect(result.plannedActivityId == legacyActivity.plannedActivityId)
        let activities = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activities.count == 1)
        // Required test 5: adoption must NEVER overwrite the existing
        // activity's own notes/location with the external event's.
        #expect(result.notes == "Existing Vǫxtr-owned notes")
        #expect(result.location == "Existing Vǫxtr-owned location")
        let decision = try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey)
        #expect(decision?.status == .imported)
        #expect(decision?.plannedActivityId == legacyActivity.plannedActivityId.rawValue)
    }

    // MARK: - Creation-time notes/location preservation

    @Test("Required test 1: a newly imported event with notes and location creates a PlannedActivity with exactly those notes/location values")
    @MainActor
    func freshClassifyAndImportPreservesNotesAndLocation() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false,
                notes: "Bring shin guards and a water bottle", location: "Community Sports Hall, Court 2"
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        #expect(imported.notes == "Bring shin guards and a water bottle")
        #expect(imported.location == "Community Sports Hall, Court 2")
        // Required test 3: existing title/start/duration behavior remains
        // unchanged alongside the new notes/location.
        #expect(imported.title == "Team Practice")
        #expect(imported.startLocalTime != nil)
        #expect(imported.plannedDurationMinutes == 60)
        // Required test 4: existing Athlete/Sport/Activity Type
        // classification behavior remains unchanged.
        #expect(imported.athleteId == fixture.athleteId.rawValue)
        #expect(imported.sportId == nil)
        #expect(imported.activityType == .individualTraining)
    }

    @Test("Closeout required test 32: classifyAndImport preserves a long external notes string exactly, without truncation")
    @MainActor
    func classifyAndImportPreservesLongNotesExactlyWithoutTruncation() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        let longNotes = String(repeating: "n", count: 4000)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false,
                notes: longNotes
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        #expect(imported.notes == longNotes)
        #expect(imported.notes?.count == 4000)
    }

    @Test("Closeout required test 33: an external notes string over the OLD 500-character limit but within the new 4000 now imports successfully")
    @MainActor
    func classifyAndImportSucceedsForNotesOverOldLimitButWithinNewLimit() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        // 1200 characters: comfortably over the OLD 500 limit (this
        // exact shape was the confirmed TestFlight bulk-import failure
        // path before this round), comfortably under the NEW 4000.
        let overOldLimitNotes = String(repeating: "n", count: 1200)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false,
                notes: overOldLimitNotes
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        #expect(imported.notes == overOldLimitNotes)
    }

    @Test("Required test 2: a newly imported event with nil notes/location leaves PlannedActivity notes/location nil")
    @MainActor
    func freshClassifyAndImportWithNilMetadataLeavesNotesLocationNil() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        #expect(imported.notes == nil)
        #expect(imported.location == nil)
    }

    @Test("Required test 6: reconcile() continues preserving an already-imported activity's existing notes/location rather than replacing them from the external event")
    @MainActor
    func reconcilePreservesExistingNotesAndLocationRatherThanReplacing() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false,
                notes: "Original external notes", location: "Original external location"
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )
        #expect(imported.notes == "Original external notes")

        // The Parent edits the Vǫxtr copy directly after import.
        let editedWeekPlanId = WeekPlanId(rawValue: imported.weekPlanId)
        _ = try fixture.planningService.editPlannedActivity(
            imported.plannedActivityId, expectedWeekPlanId: editedWeekPlanId, activityType: imported.activityType,
            title: imported.title, localDate: imported.localDate, timeZoneId: Self.timeZoneId,
            notes: "Parent's own edited notes", location: "Parent's own edited location"
        )

        // The external event's title changes (source-owned fact) and its
        // notes/location also change — reconciliation must refresh the
        // former and leave the latter alone.
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice (Renamed)",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false,
                notes: "Changed external notes", location: "Changed external location"
            )
        ]
        let outcome = try fixture.coordinationService.reconcile(source)
        #expect(outcome.updated == 1)

        let refreshed = try #require(try fixture.planningService.fetchPlannedActivity(byId: imported.plannedActivityId))
        #expect(refreshed.title == "Team Practice (Renamed)")
        #expect(refreshed.notes == "Parent's own edited notes")
        #expect(refreshed.location == "Parent's own edited location")
    }

    @Test("A pre-existing PlannedActivity with the same externalSourceId but a DIFFERENT athlete/sport/activityType than the Parent's explicit selection throws existingActivityConflict, never duplicating or silently reassigning")
    @MainActor
    func conflictingExistingActivityIsNotDuplicatedOrReassigned() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        // Legacy activity attributed to the FIRST athlete.
        let today = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: fixture.athleteId, weekStart: today)
        let legacyActivity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: "Team Practice", localDate: today, timeZoneId: Self.timeZoneId,
            externalSourceId: item.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )

        // Parent now explicitly classifies it to the SECOND athlete —
        // a conflicting selection.
        #expect(throws: CalendarPlanningCoordinationError.existingActivityConflict) {
            try fixture.coordinationService.classifyAndImport(
                item, for: source, athleteId: secondAthleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
            )
        }

        // No duplicate was created, and the legacy activity was never
        // silently reassigned.
        let activities = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activities.count == 1)
        #expect(activities.first?.plannedActivityId == legacyActivity.plannedActivityId)
        #expect(activities.first?.athleteId == fixture.athleteId.rawValue)
        #expect(try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey) == nil)
    }

    @Test("Retrying classifyAndImport after a PlannedActivity was created but the CalendarImportDecision write failed creates no duplicate — the retry adopts the existing activity")
    @MainActor
    func retryAfterPartialDecisionFailureCreatesNoDuplicate() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        // Simulate the FIRST attempt's PlannedActivity write having
        // succeeded but its CalendarImportDecision write NOT (e.g. a
        // crash between the two steps) — a PlannedActivity now carries
        // this exact externalSourceId, but no decision exists yet.
        let (localDate, _) = (Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId), 0)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: fixture.athleteId, weekStart: localDate)
        let firstAttemptActivity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: item.event.title, localDate: localDate, timeZoneId: Self.timeZoneId,
            externalSourceId: item.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )

        // The retry — same Parent-chosen classification as before.
        let retried = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        #expect(retried.plannedActivityId == firstAttemptActivity.plannedActivityId)
        let activities = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activities.count == 1)
        #expect(try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey) != nil)

        // A further retry (now with a decision present) is a pure
        // idempotent no-op, still no duplicate.
        let secondRetry = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )
        #expect(secondRetry.plannedActivityId == firstAttemptActivity.plannedActivityId)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 1)
    }

    @Test("classifyAndImport throws alreadyDecided, never creating a duplicate, when a decision exists but its PlannedActivity no longer resolves")
    @MainActor
    func decisionReferencingMissingPlannedActivityThrowsRatherThanDuplicating() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        // Delete the PlannedActivity through a path OTHER than
        // removeImportedActivities, leaving the decision dangling —
        // an inconsistency this method must never paper over by quietly
        // creating a replacement.
        let weekPlan = try #require(try fixture.planningService.fetchWeekPlan(byId: WeekPlanId(rawValue: imported.weekPlanId)))
        try fixture.planningService.deletePlannedActivity(
            imported.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, deletedBy: ActorId()
        )

        #expect(throws: CalendarPlanningCoordinationError.alreadyDecided) {
            try fixture.coordinationService.classifyAndImport(
                item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
            )
        }
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
    }

    // MARK: - Family isolation (Lead Review follow-up: classifyAndImport must never let a source's events become Planning for a different workspace's athlete)

    @Test("classifyAndImport rejects an athlete belonging to a DIFFERENT workspace than the source, throwing athleteOutsideSourceWorkspace and creating neither a PlannedActivity nor a CalendarImportDecision")
    @MainActor
    func classifyAndImportRejectsAthleteOutsideSourceWorkspace() throws {
        let fixture = try makeFixture()
        let otherWorkspaceId = WorkspaceId()
        let otherWorkspaceAthleteId = try addSecondAthlete(fixture, name: "Other Family Child", workspaceId: otherWorkspaceId)
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        #expect(throws: CalendarPlanningCoordinationError.athleteOutsideSourceWorkspace) {
            try fixture.coordinationService.classifyAndImport(
                item, for: source, athleteId: otherWorkspaceAthleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
            )
        }

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey) == nil)
        // Still fully pending — the rejected attempt left nothing behind.
        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).count == 1)
    }

    @Test("An existing same-key PlannedActivity owned by an athlete from a DIFFERENT workspace is never adopted — the workspace guard runs BEFORE the existing-activity adoption path")
    @MainActor
    func existingActivityFromDifferentWorkspaceIsNeverAdopted() throws {
        let fixture = try makeFixture()
        let otherWorkspaceId = WorkspaceId()
        let otherWorkspaceAthleteId = try addSecondAthlete(fixture, name: "Other Family Child", workspaceId: otherWorkspaceId)
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        // An existing PlannedActivity already carries this exact external
        // event key, but is owned by an athlete from the OTHER workspace
        // — e.g. that OTHER family's own source happened to produce the
        // same externalContainerIdentifier + eventIdentifier (see the
        // "same calendar identifier in two workspaces" isolation test
        // above for why this can genuinely occur).
        let otherToday = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let otherWeekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: otherWorkspaceAthleteId, weekStart: otherToday)
        let otherWorkspaceActivity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: otherWeekPlan.weekPlanId, athleteId: otherWorkspaceAthleteId, activityType: .individualTraining,
            title: "Team Practice", localDate: otherToday, timeZoneId: Self.timeZoneId,
            externalSourceId: item.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )

        // The Parent explicitly classifies to that SAME (other-workspace)
        // athlete — exactly what Step 2's adoption path would otherwise
        // match on — but the workspace guard must reject this before
        // Step 2 ever runs.
        #expect(throws: CalendarPlanningCoordinationError.athleteOutsideSourceWorkspace) {
            try fixture.coordinationService.classifyAndImport(
                item, for: source, athleteId: otherWorkspaceAthleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
            )
        }

        // The other workspace's activity was never touched, and no
        // decision was created against THIS source for it.
        let activities = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(activities.count == 1)
        #expect(activities.first?.plannedActivityId == otherWorkspaceActivity.plannedActivityId)
        #expect(try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey) == nil)
    }

    @Test("CalendarImportReviewViewModel.load() only exposes active athletes belonging to source.workspaceId, never every athlete in the local store")
    @MainActor
    func importReviewViewModelOnlyExposesSourceWorkspaceAthletes() throws {
        let fixture = try makeFixture()
        let otherWorkspaceId = WorkspaceId()
        _ = try addSecondAthlete(fixture, name: "Other Family Child", workspaceId: otherWorkspaceId)
        let sameWorkspaceSecondAthleteId = try addSecondAthlete(fixture, name: "Sibling")
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )

        let viewModel = CalendarImportReviewViewModel(
            calendarPlanningCoordinationService: fixture.coordinationService,
            athleteRepository: fixture.athleteRepository,
            sportRepository: fixture.sportRepository,
            source: source,
            actorId: ActorId()
        )
        viewModel.load()

        let athleteIds = Set(viewModel.athletes.map(\.athleteId))
        #expect(athleteIds == Set([fixture.athleteId, sameWorkspaceSecondAthleteId]))
    }

    // MARK: - Remembered Exact Choices (Calendar Import Review V1.1)

    @Test("rememberedClassifications prefills Athlete/Sport/Activity Type when every prior explicit import of an exact normalized title agrees")
    @MainActor
    func rememberedClassificationsPrefillsConsistentPriorClassification() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let firstStart = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "  Hockeytrening   U14 ",
                startDate: firstStart, endDate: firstStart.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let firstItem = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.classifyAndImport(
            firstItem, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, decidedBy: ActorId()
        )

        let candidates = try fixture.coordinationService.rememberedClassifications(for: source)

        // The stored title has irregular internal whitespace and mixed
        // case; the lookup key must be the SAME normalized form
        // `ExternalEventTitleNormalization.normalize(_:)` itself produces.
        let normalizedTitle = try #require(ExternalEventTitleNormalization.normalize("Hockeytrening U14"))
        let match = try #require(candidates[normalizedTitle])
        #expect(match.athleteId == fixture.athleteId)
        #expect(match.sportId == nil)
        #expect(match.activityType == .teamTraining)
    }

    @Test("Remembered classifications are scoped to the SAME ExternalPlanningSource — a different source (even in the same workspace) never sees another source's history")
    @MainActor
    func rememberedClassificationsScopedToSameSource() throws {
        let fixture = try makeFixture()
        let sourceA = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-a", displayName: "Calendar A"
        )
        let sourceB = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-b", displayName: "Calendar B"
        )
        try fixture.coordinationService.setSourceEnabled(sourceA.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-a"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-a", title: "Weekly Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: sourceA).first)
        try fixture.coordinationService.classifyAndImport(
            item, for: sourceA, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        let candidatesForA = try fixture.coordinationService.rememberedClassifications(for: sourceA)
        let candidatesForB = try fixture.coordinationService.rememberedClassifications(for: sourceB)

        #expect(!candidatesForA.isEmpty)
        #expect(candidatesForB.isEmpty)
    }

    @Test("Conflicting prior classifications for the same exact normalized title produce NO remembered candidate — human judgement wins over guessing")
    @MainActor
    func rememberedClassificationsProduceNoCandidateWhenPriorClassificationsConflict() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let firstStart = Self.referenceDate.addingTimeInterval(3600)
        let secondStart = firstStart.addingTimeInterval(7 * 24 * 3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Hockeytrening U14",
                startDate: firstStart, endDate: firstStart.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let firstItem = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.classifyAndImport(
            firstItem, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, decidedBy: ActorId()
        )

        // A SECOND explicit import of the exact same normalized title,
        // this time to a DIFFERENT athlete — a genuine, real disagreement
        // (e.g. two different children both have events historically
        // titled "Hockeytrening U14").
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-2", calendarIdentifier: "cal-familie", title: "Hockeytrening U14",
                startDate: secondStart, endDate: secondStart.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let secondItem = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first { $0.event.eventIdentifier == "evt-2" })
        try fixture.coordinationService.classifyAndImport(
            secondItem, for: source, athleteId: secondAthleteId, sportId: nil, activityType: .teamTraining, decidedBy: ActorId()
        )

        let candidates = try fixture.coordinationService.rememberedClassifications(for: source)

        let normalizedTitle = try #require(ExternalEventTitleNormalization.normalize("Hockeytrening U14"))
        #expect(candidates[normalizedTitle] == nil)
    }

    @Test("A remembered classification whose athlete is archived produces NO candidate — the event is left requiring normal Parent review")
    @MainActor
    func rememberedClassificationsExcludeArchivedAthlete() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Weekly Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        let athlete = try #require(try fixture.athleteRepository.fetchAthlete(byId: fixture.athleteId))
        athlete.isArchived = true
        try fixture.athleteRepository.save()

        let candidates = try fixture.coordinationService.rememberedClassifications(for: source)

        let normalizedTitle = try #require(ExternalEventTitleNormalization.normalize("Weekly Practice"))
        #expect(candidates[normalizedTitle] == nil)
    }

    // MARK: - Similar-Event Suggestions (Calendar Import Review V1.2)
    //
    // These exercise `historicalTitleClassifications(for:)` together with
    // `ExternalEventTitleSimilarity.suggestedMatch(forEventTitle:among:)`
    // — the SAME combination `CalendarImportReviewViewModel.refreshQueueAndStaging()`
    // itself calls — so this is genuine end-to-end coverage of the V1.2
    // suggestion path through real persisted `.imported` decision history,
    // not just the pure matcher in isolation (see
    // `ExternalEventTitleSimilarityTests.swift` for that).

    @Test("Required test 8: a similar title on a DIFFERENT ExternalPlanningSource (even in the same workspace) produces no suggestion")
    @MainActor
    func similarSuggestionNeverCrossesSourceBoundary() throws {
        let fixture = try makeFixture()
        let sourceA = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-a", displayName: "Calendar A"
        )
        let sourceB = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-b", displayName: "Calendar B"
        )
        try fixture.coordinationService.setSourceEnabled(sourceA.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-a"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-a", title: "Hockeytrening U14",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: sourceA).first)
        try fixture.coordinationService.classifyAndImport(
            item, for: sourceA, athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, decidedBy: ActorId()
        )

        let historyForB = try fixture.coordinationService.historicalTitleClassifications(for: sourceB)
        #expect(historyForB.isEmpty)
        let suggestion = ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14 tirsdag", among: historyForB)
        #expect(suggestion == nil)
    }

    @Test("Required test 9: a similar title in a DIFFERENT workspace produces no suggestion")
    @MainActor
    func similarSuggestionNeverCrossesWorkspaceBoundary() throws {
        let fixture = try makeFixture()
        let otherWorkspaceId = WorkspaceId()
        let ownSource = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        let otherSource = try fixture.coordinationService.createSource(
            forWorkspace: otherWorkspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie-other", displayName: "Other family"
        )
        try fixture.coordinationService.setSourceEnabled(ownSource.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Hockeytrening U14",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: ownSource).first)
        try fixture.coordinationService.classifyAndImport(
            item, for: ownSource, athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, decidedBy: ActorId()
        )

        let historyForOther = try fixture.coordinationService.historicalTitleClassifications(for: otherSource)
        #expect(historyForOther.isEmpty)
    }

    @Test("Required test 10: an archived athlete's prior classification never produces a similar-event suggestion")
    @MainActor
    func similarSuggestionExcludesArchivedAthlete() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Hockeytrening U14",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, decidedBy: ActorId()
        )

        let athlete = try #require(try fixture.athleteRepository.fetchAthlete(byId: fixture.athleteId))
        athlete.isArchived = true
        try fixture.athleteRepository.save()

        let history = try fixture.coordinationService.historicalTitleClassifications(for: source)
        let suggestion = ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14 tirsdag", among: history)
        #expect(suggestion == nil)
    }

    @Test("Required test 11: an IGNORED event's title never becomes similar-event suggestion evidence")
    @MainActor
    func similarSuggestionExcludesIgnoredDecisions() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Hockeytrening U14",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.ignore(item, for: source, decidedBy: ActorId())

        let history = try fixture.coordinationService.historicalTitleClassifications(for: source)
        #expect(history.isEmpty)
        let suggestion = ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14 tirsdag", among: history)
        #expect(suggestion == nil)
    }

    @Test("Required test 12: a decision whose linked PlannedActivity no longer resolves never becomes similar-event suggestion evidence")
    @MainActor
    func similarSuggestionExcludesDanglingDecision() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Hockeytrening U14",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, decidedBy: ActorId()
        )
        let weekPlan = try #require(try fixture.planningService.fetchWeekPlan(byId: WeekPlanId(rawValue: imported.weekPlanId)))
        try fixture.planningService.deletePlannedActivity(
            imported.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, deletedBy: ActorId()
        )

        let history = try fixture.coordinationService.historicalTitleClassifications(for: source)
        #expect(history.isEmpty)
        let suggestion = ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14 tirsdag", among: history)
        #expect(suggestion == nil)
    }

    @Test("A similar (not identical) title with unambiguous history produces a suggestion end-to-end through historicalTitleClassifications, carrying the matched original title for display")
    @MainActor
    func similarSuggestionProducedEndToEndFromRealImportHistory() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Hockeytrening U14",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, decidedBy: ActorId()
        )

        let history = try fixture.coordinationService.historicalTitleClassifications(for: source)
        let suggestion = try #require(ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14 tirsdag", among: history))
        #expect(suggestion.athleteId == fixture.athleteId)
        #expect(suggestion.activityType == .teamTraining)
        #expect(suggestion.matchedOriginalTitle == "Hockeytrening U14")
    }

    // MARK: - Recovery (adapted from Calendar Planning Source V1's PR #40)

    @Test("removeImportedActivities never touches a manually-created PlannedActivity (no externalSourceType)")
    @MainActor
    func cleanupPreservesManuallyCreatedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        let today = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: fixture.athleteId, weekStart: today)
        let manual = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: "Manually added session", localDate: today, timeZoneId: Self.timeZoneId
        )

        let outcome = try fixture.coordinationService.removeImportedActivities(for: source, removedBy: ActorId())
        #expect(outcome.removed == 0)

        let stillThere = try fixture.planningService.fetchPlannedActivity(byId: manual.plannedActivityId)
        #expect(stillThere != nil)
    }

    @Test("removeImportedActivities never reopens or deletes activities in a historical week, committed or draft")
    @MainActor
    func cleanupPreservesHistoricalPlanning() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        let historicalWeekStart = LocalDate(year: 2025, month: 12, day: 1)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: fixture.athleteId, weekStart: historicalWeekStart)
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: "Old Practice", localDate: historicalWeekStart, timeZoneId: Self.timeZoneId,
            externalSourceId: "cal-familie|evt-old", externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        try fixture.planningService.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: weekPlan.revision, committedBy: ActorId())

        let outcome = try fixture.coordinationService.removeImportedActivities(for: source, removedBy: ActorId())

        #expect(outcome.removed == 0)
        #expect(outcome.historicalWeeksSkipped == 1)
        let stillCommitted = try #require(try fixture.planningService.fetchWeekPlan(byId: weekPlan.weekPlanId))
        #expect(stillCommitted.status == .committed)
        let remaining = try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType)
        #expect(remaining.count == 1)
        #expect(remaining.first?.plannedActivityId == activity.plannedActivityId)
    }

    @Test("removeImportedActivities never removes an imported activity that already has a LoggedActivity")
    @MainActor
    func cleanupPreservesLoggedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )
        _ = try fixture.trainingService.logActivity(
            athleteId: fixture.athleteId, plannedActivityId: imported.plannedActivityId,
            activityType: .individualTraining, title: "Practice", startedAt: start
        )

        let outcome = try fixture.coordinationService.removeImportedActivities(for: source, removedBy: ActorId())

        #expect(outcome.removed == 0)
        #expect(outcome.preservedLogged == 1)
        #expect(try fixture.planningService.fetchPlannedActivity(byId: imported.plannedActivityId) != nil)
    }

    // Recovery also reopens/restores a committed week's lifecycle,
    // exactly as PR #40 established, now source-scoped across athletes.
    @Test("removeImportedActivities reopens a committed CURRENT week, removes the activity, then restores committed status, and re-opens the event for review")
    @MainActor
    func cleanupReopensCommittedWeekAndReenablesReview() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let imported = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )
        let weekPlanId = WeekPlanId(rawValue: imported.weekPlanId)
        let weekPlan = try #require(try fixture.planningService.fetchWeekPlan(byId: weekPlanId))
        try fixture.planningService.commitWeekPlan(weekPlanId, expectedRevision: weekPlan.revision, committedBy: ActorId())

        let outcome = try fixture.coordinationService.removeImportedActivities(for: source, removedBy: ActorId())

        #expect(outcome.removed == 1)
        #expect(outcome.lifecycleRestoreFailed == 0)
        #expect(try #require(fixture.planningService.fetchWeekPlan(byId: weekPlanId)).status == .committed)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)

        // The event is reviewable again — its CalendarImportDecision was
        // removed alongside the PlannedActivity it produced.
        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).count == 1)
    }

    // Idempotency, carried over from PR #40's own cleanup contract.
    @Test("Calling removeImportedActivities a second time is a safe no-op once everything eligible has already been removed")
    @MainActor
    func cleanupIsIdempotent() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        let first = try fixture.coordinationService.removeImportedActivities(for: source, removedBy: ActorId())
        let second = try fixture.coordinationService.removeImportedActivities(for: source, removedBy: ActorId())

        #expect(first.removed == 1)
        #expect(second.removed == 0)
        #expect(second.failed == 0)
    }

    // MARK: - Diagnostic metadata inspection (Alpha)

    @Test("fetchDiagnosticEvents returns notes/location/URL exactly as the provider supplies them, bounded and sorted")
    @MainActor
    func diagnosticEventsCarryMetadata() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        let start = Self.referenceDate.addingTimeInterval(3600)
        let sampleURL = try #require(URL(string: "https://spond.com/group/abc123"))
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Oliver's Football",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false,
                notes: "Group: U10 Boys Football", location: "Main Pitch", url: sampleURL
            )
        ]

        let events = try fixture.coordinationService.fetchDiagnosticEvents(inCalendar: source.externalContainerIdentifier)

        #expect(events.count == 1)
        #expect(events.first?.notes == "Group: U10 Boys Football")
        #expect(events.first?.location == "Main Pitch")
        #expect(events.first?.url == sampleURL)
    }

    @Test("fetchDiagnosticEvents handles an event with no notes/location/URL without error, and bounds/sorts results")
    @MainActor
    func diagnosticEventsHandleMissingMetadataAndBounding() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = (0..<12).map { index in
            let eventStart = start.addingTimeInterval(TimeInterval(11 - index) * 3600)
            return ExternalCalendarEvent(
                eventIdentifier: "evt-\(index)", calendarIdentifier: "cal-familie", title: "Practice \(index)",
                startDate: eventStart, endDate: eventStart.addingTimeInterval(1800), isAllDay: false, isRecurring: false
            )
        }

        let events = try fixture.coordinationService.fetchDiagnosticEvents(inCalendar: source.externalContainerIdentifier)

        #expect(events.count == CalendarPlanningCoordinationService.diagnosticEventLimit)
        #expect(events.allSatisfy { $0.notes == nil && $0.location == nil && $0.url == nil })
        #expect(events == events.sorted { $0.startDate < $1.startDate })
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
