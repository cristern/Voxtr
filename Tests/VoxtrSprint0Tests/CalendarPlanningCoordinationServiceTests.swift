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

@Suite("CalendarPlanningCoordinationService (Family-Owned Calendar Sources V1)", .serialized)
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
        let athlete = try athleteRepository.createAthlete(
            workspaceId: WorkspaceId(),
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
            athleteId: athlete.athleteId
        )
    }

    @discardableResult
    private func addSecondAthlete(_ fixture: Fixture, name: String = "Sibling") throws -> AthleteId {
        let athlete = try fixture.athleteRepository.createAthlete(
            workspaceId: WorkspaceId(),
            givenName: name,
            birthDate: LocalDate(year: 2014, month: 5, day: 12),
            timeZoneId: Self.timeZoneId,
            developmentStage: .parentLed
        )
        return athlete.athleteId
    }

    // 1. external calendar/source is family-owned, not athlete-owned
    @Test("ExternalPlanningSource carries no athleteId — creating one requires no athlete at all, and the same source works for every athlete")
    @MainActor
    func sourceIsFamilyOwnedNotAthleteOwned() throws {
        let fixture = try makeFixture()
        // No athleteId parameter exists on createSource at all — this
        // compiling is itself part of the proof; the runtime assertions
        // below confirm the created row carries no per-athlete default.
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        #expect(source.externalContainerIdentifier == "cal-familie")
        #expect(source.isEnabled == false)

        let sources = try fixture.coordinationService.fetchSources()
        #expect(sources.count == 1)
        #expect(sources.first?.externalPlanningSourceId == source.externalPlanningSourceId)
    }

    // 12. one family source setup replaces duplicate per-athlete setup
    // semantics — connecting the SAME calendar a second time is rejected
    // regardless of athlete, since there is no athlete dimension to the
    // uniqueness check at all (unlike the legacy per-(calendar,athlete)
    // mapping, which allowed the same calendar to be configured
    // separately for each athlete).
    @Test("Creating a source for an already-connected calendar throws duplicateSource — one connection covers every athlete, never one per athlete")
    @MainActor
    func duplicateSourceRejected() throws {
        let fixture = try makeFixture()
        _ = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
        )
        #expect(throws: CalendarPlanningCoordinationError.duplicateSource) {
            try fixture.coordinationService.createSource(
                providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie (renamed)"
            )
        }
    }

    // 2. same source can provide events that are classified to different
    // athletes; 4. Parent-classified event creates PlannedActivity with
    // selected athlete/sport/type
    @Test("The SAME source's events can be classified to different athletes, each with its own explicit Sport/Activity Type")
    @MainActor
    func sameSourceClassifiesToDifferentAthletes() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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

    // 3. unclassified event does not create PlannedActivity
    @Test("An unclassified event never becomes a PlannedActivity — reconcile() never creates, only fetchReviewQueue() surfaces it")
    @MainActor
    func unclassifiedEventNeverBecomesPlannedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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

    // 5. ignored event does not create PlannedActivity
    @Test("Ignoring an event never creates a PlannedActivity, and it never reappears in the review queue")
    @MainActor
    func ignoredEventNeverBecomesPlannedActivityAndNeverResurfaces() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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

        // Even a fresh fetch (simulating the Parent reopening Review
        // later) never resurfaces an ignored event.
        let outcome = try fixture.coordinationService.reconcile(source)
        #expect(outcome.updated == 0)
        #expect(try fixture.coordinationService.fetchReviewQueue(for: source).isEmpty)
    }

    // 6. repeated sync does not duplicate imported activity
    @Test("Calling reconcile() repeatedly after an event is imported never creates a second PlannedActivity")
    @MainActor
    func repeatedSyncNeverDuplicatesImportedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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

    // 7. previously classified/imported event reconciles source-owned
    // title/time changes
    @Test("reconcile() refreshes an already-imported PlannedActivity's source-owned title/time, preserving its identity and Parent-chosen Sport/Activity Type")
    @MainActor
    func reconcileRefreshesSourceOwnedFieldsOnAlreadyImportedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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

    // 8. source deletion preserves LoggedActivity truth
    @Test("Deleting a source never touches its already-imported PlannedActivity or LoggedActivity truth")
    @MainActor
    func sourceDeletionPreservesLoggedActivityTruth() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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

        try fixture.coordinationService.deleteSource(source.externalPlanningSourceId)

        #expect(try fixture.coordinationService.fetchSources().isEmpty)
        #expect(try fixture.planningService.fetchPlannedActivity(byId: imported.plannedActivityId) != nil)
        #expect(try fixture.trainingService.fetchLoggedActivities(forPlannedActivity: imported.plannedActivityId).count == 1)
    }

    // 14. unavailable EventKit calendar cannot mass-delete
    @Test("An UNAVAILABLE calendar does NOT cancel a previously-imported unperformed future PlannedActivity")
    @MainActor
    func unavailableCalendarCannotMassDelete() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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

    // 15. recurring/detached identity behavior remains covered
    @Test("Recurring occurrences sharing one eventIdentifier are classified as distinct PlannedActivities, and moving one occurrence updates only that occurrence")
    @MainActor
    func recurringOccurrenceIdentityRemainsCorrect() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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

    // 13. migration from current schema opens safely and does not
    // silently auto-classify future events using legacy athlete/sport/
    // type values
    @Test("migrateLegacySourcesIfNeeded() creates one disabled ExternalPlanningSource per distinct legacy calendarIdentifier, dropping athlete/sport/activityType, and creates no CalendarImportDecision")
    @MainActor
    func migrateLegacySourcesIfNeededDropsClassificationDefaults() throws {
        let fixture = try makeFixture()
        let secondAthleteId = try addSecondAthlete(fixture)
        // Two legacy mappings for the SAME calendar, two different
        // athletes/sports/activity types — simulating exactly the real
        // evidence this migration exists for (one Spond "Familie"
        // calendar, previously mapped once per child).
        _ = try fixture.legacyMappingRepository.insert(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-familie",
            calendarTitle: "Familie", activityType: .individualTraining, sportId: nil
        )
        _ = try fixture.legacyMappingRepository.insert(
            athleteId: secondAthleteId, calendarIdentifier: "cal-familie",
            calendarTitle: "Familie", activityType: .teamTraining, sportId: nil
        )

        let created = try fixture.coordinationService.migrateLegacySourcesIfNeeded()
        #expect(created.count == 1)
        #expect(created.first?.externalContainerIdentifier == "cal-familie")
        #expect(created.first?.displayName == "Familie")
        #expect(created.first?.isEnabled == false)

        let sources = try fixture.coordinationService.fetchSources()
        #expect(sources.count == 1)
        // No CalendarImportDecision was fabricated from the legacy
        // athlete/sport/activityType values — migration seeds ONLY the
        // container.
        #expect(try fixture.importDecisionRepository.fetchAll(forSource: sources[0].externalPlanningSourceId).isEmpty)

        // Idempotent: calling again is a safe no-op, never a second
        // source for the same calendar.
        let secondRun = try fixture.coordinationService.migrateLegacySourcesIfNeeded()
        #expect(secondRun.isEmpty)
        #expect(try fixture.coordinationService.fetchSources().count == 1)
    }

    // MARK: - Recovery (adapted from Calendar Planning Source V1's PR #40)

    // 9. cleanup still preserves manual activities
    @Test("removeImportedActivities never touches a manually-created PlannedActivity (no externalSourceType)")
    @MainActor
    func cleanupPreservesManuallyCreatedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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

    // 10. cleanup still preserves historical Planning
    @Test("removeImportedActivities never reopens or deletes activities in a historical week, committed or draft")
    @MainActor
    func cleanupPreservesHistoricalPlanning() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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

    // 11. cleanup still preserves LoggedActivity
    @Test("removeImportedActivities never removes an imported activity that already has a LoggedActivity")
    @MainActor
    func cleanupPreservesLoggedActivity() throws {
        let fixture = try makeFixture()
        let source = try fixture.coordinationService.createSource(
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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
            providerKind: .eventKit, externalContainerIdentifier: "cal-familie", displayName: "Familie"
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
