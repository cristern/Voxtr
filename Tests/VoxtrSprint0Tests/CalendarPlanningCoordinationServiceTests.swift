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
        /// VX-038: exposed so a test can directly inspect persisted
        /// decomposition evidence (e.g. "editing a suggested split for a
        /// later occurrence does not rewrite the original evidence row")
        /// without a second, parallel read path.
        let decomposedActivityLinkRepository: DecomposedActivityLinkRepository
        let decompositionEvidenceRepository: DecompositionEvidenceRepository
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
        return Fixture(
            planningService: planningService,
            trainingService: trainingService,
            athleteRepository: athleteRepository,
            sourceRepository: sourceRepository,
            importDecisionRepository: importDecisionRepository,
            legacyMappingRepository: legacyMappingRepository,
            decomposedActivityLinkRepository: decomposedActivityLinkRepository,
            decompositionEvidenceRepository: decompositionEvidenceRepository,
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

    // MARK: - PR #49 follow-up (source-disabled Ignore safety)

    @Test("Required test 1/3: canonical ignore(...) throws sourceDisabled for a disabled source, and creates no CalendarImportDecision")
    @MainActor
    func ignoreThrowsSourceDisabledForDisabledSourceAndPersistsNothing() throws {
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

        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: false)

        #expect(throws: CalendarPlanningCoordinationError.sourceDisabled) {
            try fixture.coordinationService.ignore(item, for: source, decidedBy: ActorId())
        }
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId).isEmpty)
    }

    @Test("Required test 2/3: canonical ignore(...) throws sourceDisabled for a DISCONNECTED source, and creates no CalendarImportDecision")
    @MainActor
    func ignoreThrowsSourceDisabledForDisconnectedSourceAndPersistsNothing() throws {
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

        try fixture.coordinationService.disconnectSource(source.externalPlanningSourceId)

        #expect(throws: CalendarPlanningCoordinationError.sourceDisabled) {
            try fixture.coordinationService.ignore(item, for: source, decidedBy: ActorId())
        }
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId).isEmpty)
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

    // MARK: - PR #48 follow-up: durable Suggested Ignore evidence
    // (historicalIgnoredTitles(for:))

    @Test("Required test 1: an explicit Ignore persists the event's title on its CalendarImportDecision, and historicalIgnoredTitles(for:) returns it even after the event disappears from the provider horizon")
    @MainActor
    func ignorePersistsTitleEvidenceSurvivingHorizonExpiry() throws {
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

        let decision = try #require(try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey))
        #expect(decision.ignoredEventTitle == "Team Practice")

        // The event ages entirely out of the provider's own
        // reconciliation window — historicalIgnoredTitles never touches
        // the provider at all, so this must not affect it.
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = []
        #expect(try fixture.coordinationService.fetchIgnoredReviewItems(for: source).isEmpty)

        #expect(try fixture.coordinationService.historicalIgnoredTitles(for: source) == ["Team Practice"])
    }

    @Test("Required test 4: historicalIgnoredTitles(for:) never includes titles ignored on a DIFFERENT source")
    @MainActor
    func historicalIgnoredTitlesIsSourceScoped() throws {
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

        #expect(try fixture.coordinationService.historicalIgnoredTitles(for: sourceA).isEmpty)
        #expect(try fixture.coordinationService.historicalIgnoredTitles(for: sourceB) == ["Team Practice"])
    }

    @Test("Required test 6: historicalIgnoredTitles(for:) never includes a title from an .imported decision")
    @MainActor
    func historicalIgnoredTitlesExcludesImportedDecisions() throws {
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
        _ = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        #expect(try fixture.coordinationService.historicalIgnoredTitles(for: source).isEmpty)
    }

    @Test("Required test 7: restoreIgnoredEvent deletes the decision that carried the title snapshot, so historicalIgnoredTitles(for:) no longer returns it")
    @MainActor
    func restoreRemovesTitleEvidence() throws {
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
        #expect(try fixture.coordinationService.historicalIgnoredTitles(for: source) == ["Team Practice"])

        try fixture.coordinationService.restoreIgnoredEvent(item.externalEventKey, for: source)

        #expect(try fixture.coordinationService.historicalIgnoredTitles(for: source).isEmpty)
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

extension CalendarPlanningCoordinationServiceTests {
    // MARK: - VX-038: External Event Decomposition / Suggested Split

    /// Test requirement 1: the ordinary one-event -> one-activity path
    /// is completely unchanged by this feature.
    @Test("VX-038: ordinary classifyAndImport still creates exactly one PlannedActivity, unaffected by decomposition")
    @MainActor
    func ordinaryImportStillCreatesOnePlannedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Football",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let activity = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )
        let decision = try #require(try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey))
        #expect(try fixture.coordinationService.plannedActivityIds(for: decision) == [activity.plannedActivityId])
        #expect(try fixture.decomposedActivityLinkRepository.fetchAll(forDecision: decision.calendarImportDecisionId).isEmpty)
    }

    /// Test requirements 2, 3, 4, 5: an explicit split creates the
    /// correct number of distinct PlannedActivities, each preserving the
    /// SAME external-event provenance while carrying its own stable ID,
    /// with correct offset-derived start times and preserved durations.
    @Test("VX-038: classifyAndImportSplit creates distinct PlannedActivities with correct offsets, durations, and shared provenance")
    @MainActor
    func explicitSplitCreatesDistinctChildrenWithCorrectTimingAndProvenance() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-hockey", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        let children = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
            ),
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: secondAthleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
            )
        ]
        let created = try fixture.coordinationService.classifyAndImportSplit(item, for: source, children: children, decidedBy: ActorId())

        #expect(created.count == 2)
        #expect(created[0].plannedActivityId != created[1].plannedActivityId)
        #expect(created[0].externalSourceId == item.externalEventKey)
        #expect(created[1].externalSourceId == item.externalEventKey)
        #expect(created[0].athleteId == fixture.athleteId.rawValue)
        #expect(created[0].plannedDurationMinutes == 40)
        #expect(created[0].startLocalTime == LocalTime(hour: 2, minute: 0))
        #expect(created[1].athleteId == secondAthleteId.rawValue)
        #expect(created[1].plannedDurationMinutes == 60)
        // start + 70 min offset => 3h10m after Self.referenceDate.
        #expect(created[1].startLocalTime == LocalTime(hour: 3, minute: 10))

        let decision = try #require(try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey))
        let linkedIds = try fixture.coordinationService.plannedActivityIds(for: decision)
        #expect(Set(linkedIds) == Set(created.map(\.plannedActivityId)))
    }

    /// Test requirement 6: invalid child data fails safely, without
    /// leaving a partial split — no PlannedActivity from the batch
    /// survives, and no CalendarImportDecision is created.
    @Test("VX-038: classifyAndImportSplit with an invalid child fails safely, leaving no partial split")
    @MainActor
    func invalidSplitChildFailsWithoutPartialState() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-hockey", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        let children = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
            ),
            // Invalid: zero duration.
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 70, durationMinutes: 0
            )
        ]
        #expect(throws: CalendarPlanningCoordinationError.invalidSplitChildDuration(index: 1)) {
            try fixture.coordinationService.classifyAndImportSplit(item, for: source, children: children, decidedBy: ActorId())
        }

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey) == nil)
        // Still pending — the event remains reviewable, not stuck.
        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).count == 1)
    }

    /// Test requirement 7: recurring-series evidence from an explicitly
    /// imported split produces a Suggested Split for a LATER occurrence
    /// sharing the same source + recurring eventIdentifier.
    @Test("VX-038: an explicit split's evidence produces a Suggested Split for a later occurrence of the same recurring series")
    @MainActor
    func recurringSeriesEvidenceProducesSuggestedSplitForLaterOccurrence() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
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
        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        let firstItem = try #require(queue.first { $0.event.occurrenceDate == firstOccurrence })
        let secondItem = try #require(queue.first { $0.event.occurrenceDate == secondOccurrence })

        // Test requirement 8: no evidence yet -> no Suggested Split.
        #expect(try fixture.coordinationService.suggestedSplit(for: secondItem.event, source: source) == nil)

        let children = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
            ),
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
            )
        ]
        try fixture.coordinationService.classifyAndImportSplit(firstItem, for: source, children: children, decidedBy: ActorId())

        // Test requirement 8 (continued): Suggested Split never itself
        // creates a PlannedActivity for the second, still-pending
        // occurrence — it is a pure read.
        let suggested = try #require(try fixture.coordinationService.suggestedSplit(for: secondItem.event, source: source))
        #expect(suggested.children.count == 2)
        #expect(suggested.children[0].startOffsetMinutes == 0)
        #expect(suggested.children[0].durationMinutes == 40)
        #expect(suggested.children[1].startOffsetMinutes == 70)
        #expect(suggested.children[1].durationMinutes == 60)
        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).contains { $0.externalEventKey == secondItem.externalEventKey })

        // Test requirement 9: accepting the suggestion creates the
        // expected children for the NEW occurrence.
        let acceptedChildren = suggested.children.map {
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: $0.athleteId, sportId: $0.sportId, activityType: $0.activityType,
                startOffsetMinutes: $0.startOffsetMinutes, durationMinutes: $0.durationMinutes
            )
        }
        let secondCreated = try fixture.coordinationService.classifyAndImportSplit(secondItem, for: source, children: acceptedChildren, decidedBy: ActorId())
        #expect(secondCreated.count == 2)
        #expect(secondCreated[0].externalSourceId == secondItem.externalEventKey)
    }

    /// Test requirement 10: a later, EDITED split for a second occurrence
    /// of the same series does not silently rewrite the original
    /// evidence — the historical evidence row (and its children) stay
    /// exactly as first learned.
    @Test("VX-038: an edited split for a later occurrence does not rewrite the original recurring-series evidence")
    @MainActor
    func editedLaterSplitDoesNotRewriteOriginalEvidence() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
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
        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        let firstItem = try #require(queue.first { $0.event.occurrenceDate == firstOccurrence })
        let secondItem = try #require(queue.first { $0.event.occurrenceDate == secondOccurrence })

        try fixture.coordinationService.classifyAndImportSplit(
            firstItem, for: source,
            children: [
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
                ),
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
                )
            ],
            decidedBy: ActorId()
        )
        let evidenceBefore = try fixture.decompositionEvidenceRepository.fetchAll(forSource: source.externalPlanningSourceId)
        #expect(evidenceBefore.count == 1)
        let childrenBefore = try fixture.decompositionEvidenceRepository.fetchChildren(forEvidence: evidenceBefore[0].decompositionEvidenceId)
        #expect(childrenBefore.map(\.durationMinutes) == [40, 60])

        // A DIFFERENT, explicitly EDITED split for the second occurrence
        // (still 2 children — the canonical minimum — but different
        // durations/offsets than the original evidence).
        try fixture.coordinationService.classifyAndImportSplit(
            secondItem, for: source,
            children: [
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 90
                ),
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 100, durationMinutes: 20
                )
            ],
            decidedBy: ActorId()
        )

        let evidenceAfter = try fixture.decompositionEvidenceRepository.fetchAll(forSource: source.externalPlanningSourceId)
        #expect(evidenceAfter.count == 1)
        #expect(evidenceAfter[0].decompositionEvidenceId == evidenceBefore[0].decompositionEvidenceId)
        let childrenAfter = try fixture.decompositionEvidenceRepository.fetchChildren(forEvidence: evidenceAfter[0].decompositionEvidenceId)
        #expect(childrenAfter.map(\.durationMinutes) == [40, 60])
    }

    /// Test requirement 11: a non-recurring event's exact title can
    /// surface a Suggested Split, scoped to the SAME source only.
    /// Test requirement 12: the SAME title from a DIFFERENT source never
    /// reuses that evidence.
    @Test("VX-038: non-recurring exact-title fallback surfaces a Suggested Split only within the same source")
    @MainActor
    func nonRecurringTitleFallbackIsScopedToSameSourceOnly() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let otherSource = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-other", displayName: "Other"
        )
        try fixture.coordinationService.setSourceEnabled(otherSource.externalPlanningSourceId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.classifyAndImportSplit(
            item, for: source,
            children: [
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
                ),
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
                )
            ],
            decidedBy: ActorId()
        )

        // Same source, different (non-recurring) event, same exact title
        // -> Suggested Split via the title fallback.
        let laterEvent = ExternalCalendarEvent(
            eventIdentifier: "evt-2", calendarIdentifier: "cal-familie", title: "Hockey training",
            startDate: start.addingTimeInterval(7 * 24 * 3600), endDate: nil, isAllDay: false, isRecurring: false
        )
        let suggestedSameSource = try fixture.coordinationService.suggestedSplit(for: laterEvent, source: source)
        #expect(suggestedSameSource?.children.count == 2)

        // Same exact title, DIFFERENT source -> no reuse.
        let suggestedOtherSource = try fixture.coordinationService.suggestedSplit(for: laterEvent, source: otherSource)
        #expect(suggestedOtherSource == nil)
    }

    /// Test requirement 14 (existing exact/similar classification
    /// behavior unregressed): decomposition evidence for one event never
    /// interferes with the UNRELATED exact-remembered-classification
    /// evidence `historicalTitleClassifications(for:)` already provides
    /// for a different, ordinarily-imported title.
    @Test("VX-038: decomposition evidence does not interfere with existing exact-title classification evidence")
    @MainActor
    func decompositionEvidenceDoesNotInterfereWithExistingClassificationEvidence() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-split", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-ordinary", calendarIdentifier: "cal-familie", title: "Swim practice",
                startDate: start.addingTimeInterval(10800), endDate: start.addingTimeInterval(14400), isAllDay: false, isRecurring: false
            )
        ]
        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        let splitItem = try #require(queue.first { $0.event.eventIdentifier == "evt-split" })
        let ordinaryItem = try #require(queue.first { $0.event.eventIdentifier == "evt-ordinary" })

        try fixture.coordinationService.classifyAndImportSplit(
            splitItem, for: source,
            children: [
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
                ),
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
                )
            ],
            decidedBy: ActorId()
        )
        _ = try fixture.coordinationService.classifyAndImport(
            ordinaryItem, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        let historicalTitles = try fixture.coordinationService.historicalTitleClassifications(for: source)
        // The ORDINARY import remains valid single-activity
        // classification evidence...
        #expect(historicalTitles.contains { $0.normalizedTitle == "swim practice" })
        // ...but the DECOMPOSED decision's title must NEVER surface as
        // single-activity classification evidence, even though it still
        // mirrors its first child's athlete/sport/activityType/
        // plannedActivityId on the `CalendarImportDecision` itself (Lead
        // Review follow-up, Blocker 1) — a decision carrying
        // `DecomposedActivityLink` rows is structurally excluded.
        #expect(!historicalTitles.contains { $0.normalizedTitle == "hockey training" })
        let rememberedTitles = try fixture.coordinationService.rememberedClassifications(for: source)
        #expect(rememberedTitles["hockey training"] == nil)
        #expect(rememberedTitles["swim practice"] != nil)

        // Decomposition evidence is a SEPARATE, canonical record for the
        // split title — unaffected by its exclusion from single-activity
        // classification evidence, and still produces a Suggested Split
        // for a later matching (same source, same exact title) event.
        let laterHockeyEvent = ExternalCalendarEvent(
            eventIdentifier: "evt-split-2", calendarIdentifier: "cal-familie", title: "Hockey training",
            startDate: start.addingTimeInterval(7 * 24 * 3600), endDate: nil, isAllDay: false, isRecurring: false
        )
        let suggested = try fixture.coordinationService.suggestedSplit(for: laterHockeyEvent, source: source)
        #expect(suggested?.children.count == 2)
    }

    /// Test requirement 15: decomposition evidence for one title never
    /// suppresses or interferes with a genuine Suggested Ignore
    /// candidate — a DIFFERENT title, explicitly ignored, still
    /// surfaces via `historicalIgnoredTitles(for:)` unchanged.
    @Test("VX-038: decomposition evidence does not regress existing Suggested Ignore evidence")
    @MainActor
    func decompositionEvidenceDoesNotRegressSuggestedIgnoreEvidence() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-split", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-ignored", calendarIdentifier: "cal-familie", title: "Team meeting",
                startDate: start.addingTimeInterval(10800), endDate: start.addingTimeInterval(14400), isAllDay: false, isRecurring: false
            )
        ]
        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        let splitItem = try #require(queue.first { $0.event.eventIdentifier == "evt-split" })
        let ignoredItem = try #require(queue.first { $0.event.eventIdentifier == "evt-ignored" })

        try fixture.coordinationService.classifyAndImportSplit(
            splitItem, for: source,
            children: [
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
                ),
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
                )
            ],
            decidedBy: ActorId()
        )
        _ = try fixture.coordinationService.ignore(ignoredItem, for: source, decidedBy: ActorId())

        let ignoredTitles = try fixture.coordinationService.historicalIgnoredTitles(for: source)
        #expect(ignoredTitles == ["Team meeting"])
    }

    /// Test requirement 16: `classifyAndImportSplit` respects the exact
    /// same disabled/disconnected source boundary every other mutating
    /// action already enforces — no PlannedActivity, CalendarImportDecision,
    /// or DecompositionEvidence is created.
    @Test("VX-038: classifyAndImportSplit throws sourceDisabled for a disabled or disconnected source, creating no activities/decision/evidence")
    @MainActor
    func splitRespectsDisabledAndDisconnectedSourceBoundary() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-hockey", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let children = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
            )
        ]

        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: false)
        #expect(throws: CalendarPlanningCoordinationError.sourceDisabled) {
            try fixture.coordinationService.classifyAndImportSplit(item, for: source, children: children, decidedBy: ActorId())
        }

        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        try fixture.coordinationService.disconnectSource(source.externalPlanningSourceId)
        #expect(throws: CalendarPlanningCoordinationError.sourceDisabled) {
            try fixture.coordinationService.classifyAndImportSplit(item, for: source, children: children, decidedBy: ActorId())
        }

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey) == nil)
        #expect(try fixture.decompositionEvidenceRepository.fetchAll(forSource: source.externalPlanningSourceId).isEmpty)
    }

    /// Lead Review follow-up (split semantics — minimum two children):
    /// zero or exactly one child both throw
    /// `.splitRequiresAtLeastTwoChildren` and create nothing at all —
    /// the ordinary `classifyAndImport` path already owns the
    /// one-activity case.
    @Test("VX-038 Lead Review follow-up: classifyAndImportSplit requires at least two children")
    @MainActor
    func splitRequiresAtLeastTwoChildren() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let oneChild = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
            )
        ]

        #expect(throws: CalendarPlanningCoordinationError.splitRequiresAtLeastTwoChildren) {
            try fixture.coordinationService.classifyAndImportSplit(item, for: source, children: [], decidedBy: ActorId())
        }
        #expect(throws: CalendarPlanningCoordinationError.splitRequiresAtLeastTwoChildren) {
            try fixture.coordinationService.classifyAndImportSplit(item, for: source, children: oneChild, decidedBy: ActorId())
        }

        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).isEmpty)
        #expect(try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey) == nil)
    }

    /// Test requirement 6: a completed split has exactly ONE
    /// `CalendarImportDecision` and exactly ONE `DecomposedActivityLink`
    /// per created `PlannedActivity` — the normalized provenance model
    /// this feature is built on, never comma-separated IDs or duplicated
    /// decision rows.
    @Test("VX-038: a completed split persists exactly one decision and exactly one link per created PlannedActivity")
    @MainActor
    func completedSplitHasExactlyOneDecisionAndOneLinkPerChild() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-hockey", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let children = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
            ),
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
            )
        ]
        let created = try fixture.coordinationService.classifyAndImportSplit(item, for: source, children: children, decidedBy: ActorId())

        let allDecisions = try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId)
        #expect(allDecisions.count == 1)
        let decision = try #require(allDecisions.first)

        let links = try fixture.decomposedActivityLinkRepository.fetchAll(forDecision: decision.calendarImportDecisionId)
        #expect(links.count == created.count)
        #expect(Set(links.map(\.plannedActivityId)) == Set(created.map { $0.plannedActivityId.rawValue }))
    }

    /// Test requirement 7: calling `classifyAndImportSplit` again for the
    /// SAME already-completed split (same `externalEventKey`) is a safe,
    /// idempotent no-op — returns every original child, in order, and
    /// creates NO additional `PlannedActivity`/decision/link.
    @Test("VX-038: retry of a fully completed split remains idempotent and returns every child")
    @MainActor
    func retryOfCompletedSplitIsIdempotent() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-hockey", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let children = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
            ),
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
            )
        ]
        let firstAttempt = try fixture.coordinationService.classifyAndImportSplit(item, for: source, children: children, decidedBy: ActorId())

        // Retry — same item, same (or even different) children input;
        // the existing decision's own coherent link set wins.
        let retryAttempt = try fixture.coordinationService.classifyAndImportSplit(item, for: source, children: children, decidedBy: ActorId())

        #expect(retryAttempt.map(\.plannedActivityId) == firstAttempt.map(\.plannedActivityId))
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId).count == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 2)
    }

    /// Test requirement 5 & 8 (Lead Review follow-up, Blocker 2): this
    /// codebase's repositories are concrete SwiftData types with no
    /// fault-injection seam (see `classifyAndImportSplit`'s own "CORE
    /// CONSISTENCY" doc note), so a genuine mid-write failure cannot be
    /// triggered from a black-box test without inventing a new
    /// protocol/mock abstraction — out of this fix's bounded scope. This
    /// test instead directly reproduces the EXACT critical failure mode
    /// described in the review (2 `PlannedActivity` rows already exist,
    /// an `.imported` `CalendarImportDecision` exists, but only ONE
    /// `DecomposedActivityLink` row exists — precisely what a prior
    /// `classifyAndImportSplit` call interrupted between its decision
    /// insert and its second link insert, before this fix's own
    /// rollback existed, would have left behind) and proves a retry
    /// against that state fails safely with `.splitProvenanceIncomplete`
    /// rather than silently returning the 1-activity subset as a
    /// successful import.
    @Test("VX-038 Lead Review follow-up: retry against a decomposed decision with an incomplete link set fails safely rather than returning a subset")
    @MainActor
    func retryAgainstIncompleteSplitProvenanceFailsSafely() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-hockey", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let children = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
            ),
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
            )
        ]

        // Reproduce the exact partial state directly, bypassing
        // classifyAndImportSplit entirely (which, after this fix, would
        // never leave this state behind on its own).
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: fixture.athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 1).startOfWeek)
        let firstActivity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: "Hockey training", localDate: LocalDate(year: 2026, month: 1, day: 2),
            timeZoneId: Self.timeZoneId, startLocalTime: LocalTime(hour: 2, minute: 0), plannedDurationMinutes: 40,
            externalSourceId: item.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        let secondActivity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .teamTraining,
            title: "Hockey training", localDate: LocalDate(year: 2026, month: 1, day: 2),
            timeZoneId: Self.timeZoneId, startLocalTime: LocalTime(hour: 3, minute: 10), plannedDurationMinutes: 60,
            externalSourceId: item.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        let decision = try fixture.importDecisionRepository.insert(
            sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey, status: .imported,
            athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining,
            plannedActivityId: firstActivity.plannedActivityId, decidedBy: ActorId()
        )
        // Only ONE of the two intended links — the exact partial state
        // a mid-write interruption would leave.
        try fixture.decomposedActivityLinkRepository.insert(
            calendarImportDecisionId: decision.calendarImportDecisionId, plannedActivityId: firstActivity.plannedActivityId, orderIndex: 0
        )

        #expect(throws: CalendarPlanningCoordinationError.splitProvenanceIncomplete) {
            try fixture.coordinationService.classifyAndImportSplit(item, for: source, children: children, decidedBy: ActorId())
        }

        // The retry attempt never silently "fixed" or extended the
        // corrupt state — still exactly 1 decision, 1 link, and the
        // second, orphaned PlannedActivity remains exactly as it was
        // (never duplicated, never silently linked after the fact).
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId).count == 1)
        #expect(try fixture.decomposedActivityLinkRepository.fetchAll(forDecision: decision.calendarImportDecisionId).count == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 2)
        _ = secondActivity
    }

    /// Lead Review follow-up (evidence correctness), test requirements
    /// 1-4: two DIFFERENT recurring series sharing the exact same title
    /// each learn and resolve their OWN distinct split pattern —
    /// series B's first explicit split creates series-B evidence even
    /// though series A's title-fallback evidence already existed at
    /// that moment (the exact bug: recording used to treat "a
    /// suggestion exists" as "evidence already recorded," silently
    /// discarding B's own explicit pattern forever), and neither
    /// series's own evidence is disturbed by the other's.
    @Test("VX-038 Lead Review follow-up: series A and series B share the exact same title but learn and resolve distinct split patterns")
    @MainActor
    func differentRecurringSeriesWithSameTitleLearnDistinctPatterns() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)

        let seriesAFirst = Self.referenceDate.addingTimeInterval(3600)
        let seriesASecond = seriesAFirst.addingTimeInterval(7 * 24 * 3600)
        let seriesBFirst = Self.referenceDate.addingTimeInterval(2 * 3600)
        let seriesBSecond = seriesBFirst.addingTimeInterval(7 * 24 * 3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series-a", occurrenceDate: seriesAFirst, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: seriesAFirst, endDate: seriesAFirst.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series-a", occurrenceDate: seriesASecond, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: seriesASecond, endDate: seriesASecond.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series-b", occurrenceDate: seriesBFirst, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: seriesBFirst, endDate: seriesBFirst.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series-b", occurrenceDate: seriesBSecond, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: seriesBSecond, endDate: seriesBSecond.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            )
        ]
        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        let seriesAFirstItem = try #require(queue.first { $0.event.eventIdentifier == "evt-series-a" && $0.event.occurrenceDate == seriesAFirst })
        let seriesASecondItem = try #require(queue.first { $0.event.eventIdentifier == "evt-series-a" && $0.event.occurrenceDate == seriesASecond })
        let seriesBFirstItem = try #require(queue.first { $0.event.eventIdentifier == "evt-series-b" && $0.event.occurrenceDate == seriesBFirst })
        let seriesBSecondItem = try #require(queue.first { $0.event.eventIdentifier == "evt-series-b" && $0.event.occurrenceDate == seriesBSecond })

        let patternA = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
            ),
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
            )
        ]
        try fixture.coordinationService.classifyAndImportSplit(seriesAFirstItem, for: source, children: patternA, decidedBy: ActorId())

        // Requirement 2 setup: before series B has ANY evidence of its
        // own, series A's evidence is genuinely reachable for series B
        // via the title fallback.
        let titleFallbackBeforeB = try fixture.coordinationService.suggestedSplit(for: seriesBSecondItem.event, source: source)
        #expect(titleFallbackBeforeB?.children.map(\.durationMinutes) == [40, 60])

        // Requirement 2: series B's own explicit, DIFFERENT split still
        // creates series-B evidence — the title-fallback suggestion
        // that existed a moment ago must never have been mistaken for
        // "evidence already recorded for series B."
        let patternB = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 50
            ),
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .strength, startOffsetMinutes: 60, durationMinutes: 45
            )
        ]
        try fixture.coordinationService.classifyAndImportSplit(seriesBFirstItem, for: source, children: patternB, decidedBy: ActorId())

        // Requirement 1: both patterns are now persisted as SEPARATE
        // evidence rows.
        #expect(try fixture.decompositionEvidenceRepository.fetchAll(forSource: source.externalPlanningSourceId).count == 2)

        // Requirement 3: a later series-B occurrence now resolves B's
        // OWN series-specific pattern, not A's.
        let suggestedForB = try fixture.coordinationService.suggestedSplit(for: seriesBSecondItem.event, source: source)
        #expect(suggestedForB?.children.map(\.durationMinutes) == [50, 45])
        #expect(suggestedForB?.children.map(\.activityType) == [.individualTraining, .strength])

        // Requirement 4: a later series-A occurrence STILL resolves A's
        // own pattern, completely undisturbed by series B's own,
        // separately-learned evidence.
        let suggestedForA = try fixture.coordinationService.suggestedSplit(for: seriesASecondItem.event, source: source)
        #expect(suggestedForA?.children.map(\.durationMinutes) == [40, 60])
        #expect(suggestedForA?.children.map(\.activityType) == [.individualTraining, .teamTraining])
    }

    /// Lead Review follow-up (evidence correctness), test requirement 5:
    /// once series A and series B carry CONFLICTING split shapes under
    /// the same title, the non-recurring/same-title fallback must never
    /// arbitrarily pick one — it returns nil rather than guessing.
    @Test("VX-038 Lead Review follow-up: non-recurring title fallback returns nil when matching evidence rows disagree on split shape")
    @MainActor
    func titleFallbackReturnsNilWhenMatchingEvidenceDisagrees() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let seriesAFirst = Self.referenceDate.addingTimeInterval(3600)
        let seriesBFirst = Self.referenceDate.addingTimeInterval(2 * 3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series-a", occurrenceDate: seriesAFirst, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: seriesAFirst, endDate: seriesAFirst.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series-b", occurrenceDate: seriesBFirst, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: seriesBFirst, endDate: seriesBFirst.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            )
        ]
        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        let seriesAFirstItem = try #require(queue.first { $0.event.eventIdentifier == "evt-series-a" })
        let seriesBFirstItem = try #require(queue.first { $0.event.eventIdentifier == "evt-series-b" })

        try fixture.coordinationService.classifyAndImportSplit(
            seriesAFirstItem, for: source,
            children: [
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
                ),
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
                )
            ],
            decidedBy: ActorId()
        )
        try fixture.coordinationService.classifyAndImportSplit(
            seriesBFirstItem, for: source,
            children: [
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 50
                ),
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .strength, startOffsetMinutes: 60, durationMinutes: 45
                )
            ],
            decidedBy: ActorId()
        )

        // A THIRD, non-recurring event with the SAME title matches
        // neither series's own recurringEventIdentifier, so only the
        // title fallback applies — and it must see the two conflicting
        // shapes and refuse to guess.
        let laterNonRecurringEvent = ExternalCalendarEvent(
            eventIdentifier: "evt-one-off", calendarIdentifier: "cal-familie", title: "Hockey training",
            startDate: Self.referenceDate.addingTimeInterval(14 * 24 * 3600), endDate: nil, isAllDay: false, isRecurring: false
        )
        #expect(try fixture.coordinationService.suggestedSplit(for: laterNonRecurringEvent, source: source) == nil)
    }

    /// Lead Review follow-up (evidence correctness), test requirement 6:
    /// the title fallback still safely returns a suggestion when every
    /// matching evidence row for that title happens to agree on the
    /// exact same split shape — ambiguity handling must not become
    /// over-cautious and break the ordinary, unambiguous case.
    @Test("VX-038 Lead Review follow-up: non-recurring title fallback still succeeds when multiple matching evidence rows agree on the same split shape")
    @MainActor
    func titleFallbackSucceedsWhenMatchingEvidenceAgrees() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let seriesAFirst = Self.referenceDate.addingTimeInterval(3600)
        let seriesBFirst = Self.referenceDate.addingTimeInterval(2 * 3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series-a", occurrenceDate: seriesAFirst, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: seriesAFirst, endDate: seriesAFirst.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series-b", occurrenceDate: seriesBFirst, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: seriesBFirst, endDate: seriesBFirst.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            )
        ]
        let queue = try fixture.coordinationService.fetchReviewQueue(for: source)
        let seriesAFirstItem = try #require(queue.first { $0.event.eventIdentifier == "evt-series-a" })
        let seriesBFirstItem = try #require(queue.first { $0.event.eventIdentifier == "evt-series-b" })

        // Series A and series B happen to be split IDENTICALLY.
        let sameShape = [
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
            ),
            CalendarPlanningCoordinationService.DecomposedChildInput(
                athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
            )
        ]
        try fixture.coordinationService.classifyAndImportSplit(seriesAFirstItem, for: source, children: sameShape, decidedBy: ActorId())
        try fixture.coordinationService.classifyAndImportSplit(seriesBFirstItem, for: source, children: sameShape, decidedBy: ActorId())
        #expect(try fixture.decompositionEvidenceRepository.fetchAll(forSource: source.externalPlanningSourceId).count == 2)

        let laterNonRecurringEvent = ExternalCalendarEvent(
            eventIdentifier: "evt-one-off", calendarIdentifier: "cal-familie", title: "Hockey training",
            startDate: Self.referenceDate.addingTimeInterval(14 * 24 * 3600), endDate: nil, isAllDay: false, isRecurring: false
        )
        let suggested = try fixture.coordinationService.suggestedSplit(for: laterNonRecurringEvent, source: source)
        #expect(suggested?.children.map(\.durationMinutes) == [40, 60])
        #expect(suggested?.children.map(\.activityType) == [.individualTraining, .teamTraining])
    }

    /// Lead Review follow-up (single-activity boundary guard), test
    /// requirement 1: `classifyAndImport` against an `externalEventKey`
    /// that already has a DECOMPOSED decision must never return the
    /// mirrored first child as though it were a successful ordinary
    /// import — it fails safely with `.alreadyDecided`, and creates
    /// nothing.
    @Test("VX-038 Lead Review follow-up: classifyAndImport against an existing decomposed decision throws alreadyDecided rather than returning the first child")
    @MainActor
    func classifyAndImportAgainstDecomposedDecisionThrowsSafely() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-hockey", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.classifyAndImportSplit(
            item, for: source,
            children: [
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
                ),
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
                )
            ],
            decidedBy: ActorId()
        )

        #expect(throws: CalendarPlanningCoordinationError.alreadyDecided) {
            try fixture.coordinationService.classifyAndImport(
                item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
            )
        }

        // Nothing was created, adopted, or reinterpreted — still exactly
        // the split's own 1 decision and 2 activities.
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId).count == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 2)
    }

    /// Lead Review follow-up (single-activity boundary guard), test
    /// requirement 2: an ORDINARY historical one-to-one decision (zero
    /// `DecomposedActivityLink` rows) resolves exactly as before this
    /// guard — a repeat `classifyAndImport` call remains a safe,
    /// idempotent no-op that returns the SAME `PlannedActivity`.
    @Test("VX-038 Lead Review follow-up: classifyAndImport against an ordinary one-to-one decision remains idempotent, unchanged by the decomposed-decision guard")
    @MainActor
    func classifyAndImportOrdinaryDecisionRemainsIdempotent() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-familie", title: "Swim practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        let firstImport = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        let secondImport = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        #expect(secondImport.plannedActivityId == firstImport.plannedActivityId)
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId).count == 1)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 1)
    }

    /// Lead Review follow-up (single-activity boundary guard), test
    /// requirement 3: `classifyAndImport` with NO decision yet but TWO
    /// `PlannedActivity` rows already sharing the exact
    /// `externalEventKey` (a corrupt/partially-rolled-back provenance
    /// state, never a healthy state this path itself could produce)
    /// must never arbitrarily adopt one of them — it fails safely with
    /// `.existingActivityConflict`, adopting neither and creating no
    /// `CalendarImportDecision`.
    @Test("VX-038 Lead Review follow-up: classifyAndImport with no decision but two matching PlannedActivities adopts neither and creates no decision")
    @MainActor
    func classifyAndImportWithTwoMatchingActivitiesAdoptsNeither() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-hockey", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)

        // Directly reproduce a corrupt/partial state: two PlannedActivity
        // rows sharing this exact externalEventKey, but NO decision at
        // all (never producible by this path itself, which always
        // writes at most one such row before a decision exists).
        let today = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: fixture.athleteId, weekStart: today)
        _ = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: "Hockey training", localDate: today, timeZoneId: Self.timeZoneId,
            externalSourceId: item.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        _ = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .teamTraining,
            title: "Hockey training", localDate: today, timeZoneId: Self.timeZoneId,
            externalSourceId: item.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )

        #expect(throws: CalendarPlanningCoordinationError.existingActivityConflict) {
            try fixture.coordinationService.classifyAndImport(
                item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
            )
        }

        #expect(try fixture.importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId).isEmpty)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 2)
    }

    /// Lead Review follow-up (single-activity boundary guard), test
    /// requirement 4: EXACTLY one matching, classification-compatible
    /// `PlannedActivity` (the pre-existing "legacy adoption" case)
    /// preserves this path's existing adoption behavior, unchanged by
    /// the new `count <= 1` guard.
    @Test("VX-038 Lead Review follow-up: classifyAndImport with exactly one matching PlannedActivity preserves existing adoption behavior")
    @MainActor
    func classifyAndImportWithExactlyOneMatchingActivityStillAdopts() throws {
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
        let today = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: fixture.athleteId, weekStart: today)
        let legacyActivity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: "Team Practice", localDate: today, timeZoneId: Self.timeZoneId,
            externalSourceId: item.externalEventKey, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )

        let adopted = try fixture.coordinationService.classifyAndImport(
            item, for: source, athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, decidedBy: ActorId()
        )

        #expect(adopted.plannedActivityId == legacyActivity.plannedActivityId)
        #expect(try fixture.planningService.fetchPlannedActivities(externalSourceType: CalendarPlanningCoordinationService.externalSourceType).count == 1)
        let decision = try fixture.importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey)
        #expect(decision?.plannedActivityId == legacyActivity.plannedActivityId.rawValue)
    }

    /// Lead Review follow-up (runtime diagnostics): `hasDecompositionEvidence(for:)`
    /// is the smallest existence check the ViewModel's own bounded
    /// Suggested Split diagnostics rely on — never itself a matching/
    /// business decision.
    @Test("VX-038 Lead Review follow-up: hasDecompositionEvidence(for:) reflects whether any decomposition evidence exists for a source")
    @MainActor
    func hasDecompositionEvidenceReflectsSourceState() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            forWorkspace: fixture.workspaceId, providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        try fixture.coordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: true)
        #expect(try fixture.coordinationService.hasDecompositionEvidence(for: source) == false)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-hockey", calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: start, endDate: start.addingTimeInterval(7200), isAllDay: false, isRecurring: false
            )
        ]
        let item = try #require(try fixture.coordinationService.fetchReviewQueue(for: source).first)
        try fixture.coordinationService.classifyAndImportSplit(
            item, for: source,
            children: [
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .individualTraining, startOffsetMinutes: 0, durationMinutes: 40
                ),
                CalendarPlanningCoordinationService.DecomposedChildInput(
                    athleteId: fixture.athleteId, sportId: nil, activityType: .teamTraining, startOffsetMinutes: 70, durationMinutes: 60
                )
            ],
            decidedBy: ActorId()
        )

        #expect(try fixture.coordinationService.hasDecompositionEvidence(for: source) == true)
    }

    // MARK: - VX-038 TestFlight follow-up (Part 5): production-realistic persistence lifecycle

    /// Runtime follow-up (Part 5 — production-realistic persistence):
    /// every earlier Suggested Split test reused the SAME
    /// `CalendarPlanningCoordinationService`/`CalendarImportReviewViewModel`
    /// instance (or, at most, a fresh ViewModel against a
    /// `ModelContainer` that was never actually closed) for both the
    /// split import and the later Suggested Split read — never proving
    /// the pattern survives the lifecycle TestFlight actually crosses
    /// (app quit/relaunch, a fresh `ModelContainer` reopened from the
    /// SAME on-disk store). This test goes through a genuinely CLOSED
    /// and REOPENED `ModelContainer` against a temp on-disk store — the
    /// exact pattern `PersistenceRecoveryTests` already establishes for
    /// fresh-install/restart coverage — plus a completely fresh
    /// `CalendarPlanningCoordinationService` AND a fresh
    /// `CalendarImportReviewViewModel` built against the reopened store.
    @Test("VX-038 TestFlight follow-up test 17/18: Suggested Split survives a genuinely closed-and-reopened ModelContainer, with a fresh CalendarPlanningCoordinationService and a fresh CalendarImportReviewViewModel")
    @MainActor
    func suggestedSplitSurvivesClosedAndReopenedStore() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("vx038-persistence-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: AppSchemaV10.self)

        var workspaceId: WorkspaceId!
        var athleteId: AthleteId!
        var sourceId: ExternalPlanningSourceId!
        let calendarProvider = FakeCalendarEventProvider()
        let firstOccurrenceStart = Self.referenceDate.addingTimeInterval(3600)
        let secondOccurrenceStart = firstOccurrenceStart.addingTimeInterval(7 * 24 * 3600)
        calendarProvider.eventsByCalendar["cal-familie"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: firstOccurrenceStart, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: firstOccurrenceStart, endDate: firstOccurrenceStart.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: secondOccurrenceStart, calendarIdentifier: "cal-familie", title: "Hockey training",
                startDate: secondOccurrenceStart, endDate: secondOccurrenceStart.addingTimeInterval(7200), isAllDay: false, isRecurring: true
            )
        ]

        // Steps 1-3: persisted source/events, first coordination service +
        // first ViewModel, configure and import an explicit split.
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
                athleteRepository: athleteRepository,
                sportRepository: sportRepository,
                source: source,
                actorId: ActorId()
            )
            viewModel.load()
            let firstItem = try #require(viewModel.reviewQueue.first { $0.event.occurrenceDate == firstOccurrenceStart })

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
        // Step 4: the first ViewModel, coordination service, repositories,
        // and their whole ModelContainer all go out of scope here —
        // genuinely closed, not merely discarded while still reachable.

        // Steps 5-9: a fresh CalendarPlanningCoordinationService and a
        // fresh CalendarImportReviewViewModel, against the SAME store,
        // reopened from disk.
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
        #expect(try reopenedCoordinationService.hasDecompositionEvidence(for: reopenedSource) == true)

        let reopenedViewModel = CalendarImportReviewViewModel(
            calendarPlanningCoordinationService: reopenedCoordinationService,
            athleteRepository: reopenedAthleteRepository,
            sportRepository: reopenedSportRepository,
            source: reopenedSource,
            actorId: ActorId()
        )
        reopenedViewModel.load()
        let secondItem = try #require(reopenedViewModel.reviewQueue.first { $0.event.occurrenceDate == secondOccurrenceStart })

        let staged = reopenedViewModel.stagedClassification(for: secondItem.externalEventKey)
        #expect(staged.isSplitEnabled)
        #expect(staged.isSuggestedSplitPrefill)
        #expect(staged.splitAthleteId == athleteId)
        #expect(staged.splitChildren.map(\.durationMinutes) == [30, 60])
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
