import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrNotificationsDomain
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
/// PR #39 review follow-up (Blocker 1): `unavailableCalendars` lets a test
/// simulate the OTHER genuinely distinct failure mode — a source that
/// cannot currently be read at all — as opposed to `eventsByCalendar`
/// returning `[]` for a calendar identifier, which is a genuine,
/// authoritative "read successfully, zero matching events right now."
/// The production `EventKitCalendarEventProvider` never conflates these
/// two (see `CalendarEventProviderError`'s own doc comment); this fake
/// must not either, or Blocker 1's tests would not actually exercise the
/// real contract.
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

@Suite("CalendarPlanningCoordinationService (Calendar Planning Source V1)", .serialized)
struct CalendarPlanningCoordinationServiceTests {

    private static let referenceDate = Date(timeIntervalSince1970: 1_767_312_000)
    private static let timeZoneId = TimeZoneId(rawValue: "Europe/Oslo")

    private struct Fixture {
        let planningService: PlanningService
        let trainingService: TrainingService
        let athleteRepository: AthleteRepository
        let mappingRepository: CalendarPlanningMappingRepository
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
        let mappingRepository = CalendarPlanningMappingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let calendarProvider = FakeCalendarEventProvider()
        let coordinationService = CalendarPlanningCoordinationService(
            mappingRepository: mappingRepository,
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
            mappingRepository: mappingRepository,
            calendarProvider: calendarProvider,
            coordinationService: coordinationService,
            athleteId: athlete.athleteId
        )
    }

    // 1. mapping configuration uses stable canonical athlete/context IDs
    @Test("Creating a mapping stores the athlete's stable AthleteId and canonical SportId, not raw strings")
    @MainActor
    func mappingUsesStableCanonicalIds() throws {
        let fixture = try makeFixture()
        let sportId = SportId()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: sportId
        )

        #expect(mapping.athleteId == fixture.athleteId.rawValue)
        #expect(mapping.sportId == sportId.rawValue)
        #expect(mapping.isEnabled == false)
    }

    @Test("Creating a mapping for an unknown athlete throws athleteNotFound")
    @MainActor
    func mappingRequiresExistingAthlete() throws {
        let fixture = try makeFixture()
        #expect(throws: CalendarPlanningCoordinationError.athleteNotFound) {
            try fixture.coordinationService.createMapping(
                athleteId: AthleteId(),
                calendarIdentifier: "cal-1",
                calendarTitle: "Spond Team",
                activityType: .individualTraining,
                sportId: nil
            )
        }
    }

    // 2. first external event creates one PlannedActivity
    @Test("A qualifying external event creates exactly one PlannedActivity")
    @MainActor
    func firstEventCreatesOnePlannedActivity() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]

        let outcome = try fixture.coordinationService.reconcile(mapping)
        #expect(outcome.created == 1)
        #expect(outcome.updated == 0)

        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.count == 1)
        #expect(activities.first?.title == "Team Practice")
    }

    // 3. repeated reconciliation does NOT duplicate it
    @Test("Reconciling the same unchanged event twice does not duplicate the PlannedActivity")
    @MainActor
    func repeatedReconciliationIsIdempotent() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]

        _ = try fixture.coordinationService.reconcile(mapping)
        let secondOutcome = try fixture.coordinationService.reconcile(mapping)

        #expect(secondOutcome.created == 0)
        #expect(secondOutcome.updated == 1)

        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.count == 1)
    }

    // 4. external title/time change updates the same PlannedActivity identity
    @Test("A changed external title/time updates the SAME PlannedActivity identity, not a new one")
    @MainActor
    func externalChangeUpdatesSameIdentity() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)
        let originalId = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        ).first?.plannedActivityId

        // Same event, different title and later start time — same
        // calendar+eventIdentifier, still within the reconciliation window.
        let newStart = start.addingTimeInterval(1800)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Team Practice (moved)",
                startDate: newStart, endDate: newStart.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let outcome = try fixture.coordinationService.reconcile(mapping)
        #expect(outcome.updated == 1)
        #expect(outcome.created == 0)

        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.count == 1)
        #expect(activities.first?.title == "Team Practice (moved)")
        #expect(activities.first?.plannedActivityId == originalId)
    }

    // PR #39 review follow-up (second round), test 3 of the required
    // ordinary-event set: title changes ALONE (start time untouched)
    // must preserve identity — isolates this from the combined
    // title+time case above.
    @Test("An ordinary event's title-only change preserves its PlannedActivityId")
    @MainActor
    func ordinaryEventTitleOnlyChangePreservesIdentity() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)
        let originalId = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        ).first?.plannedActivityId

        // Same start/end — only the title changes.
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Renamed Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let outcome = try fixture.coordinationService.reconcile(mapping)
        #expect(outcome.created == 0)
        #expect(outcome.updated == 1)

        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.count == 1)
        #expect(activities.first?.title == "Renamed Practice")
        #expect(activities.first?.plannedActivityId == originalId)
    }

    // PR #39 review follow-up (second round), test 4 of the required
    // ordinary-event set: start-time changes ALONE (title untouched)
    // must preserve identity — this is the exact case the unconditional-
    // occurrenceDate regression broke (see ExternalCalendarEvent's own
    // doc comment).
    @Test("An ordinary event's start-time-only change preserves its PlannedActivityId")
    @MainActor
    func ordinaryEventStartTimeOnlyChangePreservesIdentity() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)
        let originalId = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        ).first?.plannedActivityId

        // Same title — only the start (and therefore occurrenceDate,
        // which defaults to startDate) changes.
        let newStart = start.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Team Practice",
                startDate: newStart, endDate: newStart.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let outcome = try fixture.coordinationService.reconcile(mapping)
        #expect(outcome.created == 0)
        #expect(outcome.updated == 1)

        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.count == 1)
        #expect(activities.first?.startLocalTime != nil)
        #expect(activities.first?.plannedActivityId == originalId)
    }

    // PR #39 review follow-up (second round), test 5 of the required
    // ordinary-event set: a move that stays within the SAME Vǫxtr week
    // (as opposed to the known "moved to a different week -> skipped"
    // limitation documented on CalendarPlanningCoordinationService.applyEvent)
    // must still update the existing PlannedActivity normally, including
    // the WeekPlanId it belongs to.
    @Test("An ordinary event moved within the same Vǫxtr week preserves its PlannedActivityId and WeekPlanId")
    @MainActor
    func ordinaryEventMoveWithinSameWeekPreservesIdentity() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        // Self.referenceDate is a Friday (UTC) — moving forward 2 days
        // lands on Sunday, a different calendar day but the SAME
        // Monday-Sunday Vǫxtr week.
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Team Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)
        let before = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        ).first
        let originalId = try #require(before?.plannedActivityId)
        let originalWeekPlanId = try #require(before?.weekPlanId)

        let movedStart = start.addingTimeInterval(2 * 86400)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Team Practice",
                startDate: movedStart, endDate: movedStart.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let outcome = try fixture.coordinationService.reconcile(mapping)
        #expect(outcome.created == 0)
        #expect(outcome.updated == 1)
        #expect(outcome.skipped == 0)

        let after = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        ).first
        #expect(after?.plannedActivityId == originalId)
        #expect(after?.weekPlanId == originalWeekPlanId)
    }

    // 5. two different external events do not collapse into one
    @Test("Two distinct external events create two distinct PlannedActivities")
    @MainActor
    func twoDistinctEventsStayDistinct() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice A",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-2", calendarIdentifier: "cal-1", title: "Practice B",
                startDate: start.addingTimeInterval(7200), endDate: start.addingTimeInterval(10800), isAllDay: false, isRecurring: false
            )
        ]

        let outcome = try fixture.coordinationService.reconcile(mapping)
        #expect(outcome.created == 2)

        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.count == 2)
        #expect(Set(activities.compactMap { $0.title }) == ["Practice A", "Practice B"])
    }

    // 6. same-looking title/time events with different source identity remain distinct
    @Test("Two events with identical title/time but different eventIdentifiers remain distinct PlannedActivities")
    @MainActor
    func sameLookingEventsWithDifferentIdentityStayDistinct() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-2", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]

        let outcome = try fixture.coordinationService.reconcile(mapping)
        #expect(outcome.created == 2)

        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.count == 2)
        #expect(Set(activities.map { $0.externalSourceId }).count == 2)
    }

    // 7. deletion/cancellation behavior for a future unperformed activity
    @Test("An AUTHORITATIVE empty read of the calendar (successfully read, genuinely zero matching events) cancels an unperformed future PlannedActivity that previously came from it")
    @MainActor
    func disappearedEventCancelsUnperformedActivity() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)

        // The event disappears (cancelled/removed) from the calendar —
        // the calendar itself is still perfectly readable, it just has no
        // matching events any more. This is the AUTHORITATIVE-empty case
        // (`eventsByCalendar["cal-1"] = []`, not `unavailableCalendars`).
        fixture.calendarProvider.eventsByCalendar["cal-1"] = []
        let outcome = try fixture.coordinationService.reconcile(mapping)

        #expect(outcome.cancelled == 1)
        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.isEmpty)
    }

    // PR #39 review follow-up (Blocker 1), test 2 of 3: a calendar that
    // cannot currently be read at all must NEVER be treated as evidence
    // that its previously-imported events disappeared.
    @Test("An UNAVAILABLE calendar (cannot currently be read) does NOT cancel a previously-imported unperformed future PlannedActivity")
    @MainActor
    func unavailableCalendarDoesNotCancelExistingActivity() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)
        let beforeActivities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(beforeActivities.count == 1)

        // The calendar itself becomes unresolvable (removed account,
        // store error, etc.) — never an authoritative "no events."
        fixture.calendarProvider.unavailableCalendars.insert("cal-1")
        #expect(throws: CalendarEventProviderError.calendarUnavailable) {
            try fixture.coordinationService.reconcile(mapping)
        }

        let afterActivities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(afterActivities.count == 1)
        #expect(afterActivities.first?.plannedActivityId == beforeActivities.first?.plannedActivityId)
    }

    // PR #39 review follow-up (Blocker 1), test 3 of 3: the audited fix
    // to `reconcileAllEnabledMappings`'s failure-isolation contract.
    @Test("One mapping's calendar being unavailable does not prevent another enabled mapping from reconciling in the same reconcileAllEnabledMappings() run")
    @MainActor
    func oneUnavailableMappingDoesNotBlockAnother() throws {
        let fixture = try makeFixture()
        let athleteB = try fixture.athleteRepository.createAthlete(
            workspaceId: WorkspaceId(),
            givenName: "Second Athlete",
            birthDate: LocalDate(year: 2013, month: 5, day: 1),
            timeZoneId: Self.timeZoneId,
            developmentStage: .parentLed
        )
        let brokenMapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-broken", calendarTitle: "Broken Calendar",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(brokenMapping.calendarPlanningMappingId, isEnabled: true)
        let workingMapping = try fixture.coordinationService.createMapping(
            athleteId: athleteB.athleteId, calendarIdentifier: "cal-working", calendarTitle: "Working Calendar",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(workingMapping.calendarPlanningMappingId, isEnabled: true)

        fixture.calendarProvider.unavailableCalendars.insert("cal-broken")
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-working"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-working", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]

        let results = try fixture.coordinationService.reconcileAllEnabledMappings()

        // The broken mapping contributes no entry — never a fabricated
        // zeroed outcome — but critically does NOT stop the working
        // mapping from reconciling in the same run.
        #expect(results[brokenMapping.calendarPlanningMappingId] == nil)
        #expect(results[workingMapping.calendarPlanningMappingId]?.created == 1)

        let workingActivities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: athleteB.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(workingActivities.count == 1)
    }

    // 8. proven/logged training truth is not erased by external disappearance
    @Test("A disappeared external event never removes a PlannedActivity that already has a LoggedActivity")
    @MainActor
    func provenTrainingTruthIsNotErased() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)
        let activity = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        ).first
        let plannedActivityId = try #require(activity?.plannedActivityId)

        _ = try fixture.trainingService.logActivity(
            athleteId: fixture.athleteId,
            plannedActivityId: plannedActivityId,
            activityType: .individualTraining,
            title: "Practice",
            startedAt: start
        )

        fixture.calendarProvider.eventsByCalendar["cal-1"] = []
        let outcome = try fixture.coordinationService.reconcile(mapping)

        #expect(outcome.cancelled == 0)
        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.count == 1)
        #expect(activities.first?.plannedActivityId == plannedActivityId)
    }

    // 9. recurring external occurrences do not create a Vǫxtr recurrence rule
    //
    // PR #39 review follow-up (Blocker 2): both occurrences below share
    // the SAME `eventIdentifier` ("evt-series") — matching Apple's actual
    // documented EventKit behavior (every concrete occurrence of one
    // recurring series shares its `eventIdentifier`; only
    // `occurrenceDate` differs between them). An earlier version of this
    // test gave each occurrence an artificially unique `eventIdentifier`
    // ("evt-1"/"evt-2"), which validated nothing about real recurring-
    // occurrence identity — see `ExternalCalendarEvent`'s own doc comment.
    @Test("Recurring external occurrences sharing one eventIdentifier import as distinct PlannedActivities and never create a RecurringPlannedActivity")
    @MainActor
    func recurringOccurrencesNeverCreateRecurrenceRule() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let firstOccurrence = Self.referenceDate.addingTimeInterval(3600)
        let secondOccurrence = firstOccurrence.addingTimeInterval(7 * 86400)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: firstOccurrence, calendarIdentifier: "cal-1", title: "Weekly Practice",
                startDate: firstOccurrence, endDate: firstOccurrence.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: secondOccurrence, calendarIdentifier: "cal-1", title: "Weekly Practice",
                startDate: secondOccurrence, endDate: secondOccurrence.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            )
        ]

        let outcome = try fixture.coordinationService.reconcile(mapping)
        #expect(outcome.created == 2)

        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.count == 2)
        #expect(Set(activities.compactMap { $0.externalSourceId }).count == 2)
        // Every imported occurrence is an ordinary PlannedActivity with no
        // RecurringPlannedActivity linkage — confirmed at the repository
        // level: no RecurringPlannedActivity exists for this athlete at
        // all, even though two occurrences of what EventKit reports as a
        // recurring series (sharing one eventIdentifier) were just
        // imported.
        let recurringDefinitions = try fixture.planningService.fetchRecurringPlannedActivities(forAthlete: fixture.athleteId)
        #expect(recurringDefinitions.isEmpty)
    }

    @Test("Reconciling the same shared-eventIdentifier recurring occurrences again is idempotent")
    @MainActor
    func recurringOccurrenceReconciliationIsIdempotent() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let firstOccurrence = Self.referenceDate.addingTimeInterval(3600)
        let secondOccurrence = firstOccurrence.addingTimeInterval(7 * 86400)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: firstOccurrence, calendarIdentifier: "cal-1", title: "Weekly Practice",
                startDate: firstOccurrence, endDate: firstOccurrence.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: secondOccurrence, calendarIdentifier: "cal-1", title: "Weekly Practice",
                startDate: secondOccurrence, endDate: secondOccurrence.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            )
        ]

        _ = try fixture.coordinationService.reconcile(mapping)
        let secondOutcome = try fixture.coordinationService.reconcile(mapping)

        #expect(secondOutcome.created == 0)
        #expect(secondOutcome.updated == 2)
        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.count == 2)
    }

    // PR #39 review follow-up (final EventKit classification round): this
    // is also the neutral-DTO-level model of a DETACHED recurring
    // occurrence — same `eventIdentifier` + `occurrenceDate` as its
    // sibling occurrences, a changed `startDate`, `isRecurring: true`.
    // `EKEvent.hasRecurrenceRules` alone is documented as insufficient to
    // classify a detached instance (it can report `false` on that
    // specific item), so `EventKitCalendarEventProvider` now also
    // consults `EKEvent.isDetached` when assigning `isRecurring` — see
    // that file's own doc comment on the assignment. `ExternalCalendarEvent`
    // has no separate "detached" concept of its own (EventKit-specific
    // detail stays below the provider boundary); this test proves the
    // NEUTRAL behavior every detached occurrence needs once correctly
    // classified `isRecurring: true` at that boundary — occurrence-based
    // identity, preserved across the move, with no cross-contamination
    // of its sibling. A real `EKEvent`/adapter-level test is impractical
    // in this test target (the fake never instantiates `EKEvent`); the
    // adapter's own classification line is covered by manual
    // compile-oriented audit instead.
    @Test("Moving one recurring occurrence (same eventIdentifier + occurrenceDate, new startDate) updates only that occurrence's PlannedActivity, preserving its identity, without collapsing into its sibling — this is also the neutral-DTO model of a detached occurrence")
    @MainActor
    func movingOneRecurringOccurrenceDoesNotCollapseIntoSibling() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let firstOccurrence = Self.referenceDate.addingTimeInterval(3600)
        let secondOccurrence = firstOccurrence.addingTimeInterval(7 * 86400)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: firstOccurrence, calendarIdentifier: "cal-1", title: "Weekly Practice",
                startDate: firstOccurrence, endDate: firstOccurrence.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: secondOccurrence, calendarIdentifier: "cal-1", title: "Weekly Practice",
                startDate: secondOccurrence, endDate: secondOccurrence.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)
        let beforeActivities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(beforeActivities.count == 2)
        // Sorted by localDate: the first occurrence's own PlannedActivity
        // is the earlier one (`firstOccurrence`, `secondOccurrence` are 7
        // days apart), so this ordering is deterministic regardless of
        // fetch order.
        let beforeSorted = beforeActivities.sorted { $0.localDate < $1.localDate }
        let firstBefore = beforeSorted[0]
        let secondBeforeId = beforeSorted[1].plannedActivityId

        // The first occurrence is detached and moved LATER the same day —
        // EventKit reports the SAME eventIdentifier and the SAME
        // occurrenceDate (its stable original scheduled date per Apple's
        // own documented behavior), only startDate changes.
        let movedStart = firstOccurrence.addingTimeInterval(1800)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: firstOccurrence, calendarIdentifier: "cal-1", title: "Weekly Practice (moved)",
                startDate: movedStart, endDate: movedStart.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            ),
            ExternalCalendarEvent(
                eventIdentifier: "evt-series", occurrenceDate: secondOccurrence, calendarIdentifier: "cal-1", title: "Weekly Practice",
                startDate: secondOccurrence, endDate: secondOccurrence.addingTimeInterval(3600), isAllDay: false, isRecurring: true
            )
        ]
        let outcome = try fixture.coordinationService.reconcile(mapping)
        #expect(outcome.created == 0)
        #expect(outcome.updated == 2)

        let afterActivities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(afterActivities.count == 2)
        let movedAfter = try #require(afterActivities.first { $0.plannedActivityId == firstBefore.plannedActivityId })
        let siblingAfter = try #require(afterActivities.first { $0.plannedActivityId == secondBeforeId })
        // Identity preserved for the moved occurrence — same
        // PlannedActivityId, new title/time.
        #expect(movedAfter.title == "Weekly Practice (moved)")
        // The sibling occurrence's own PlannedActivity is untouched by
        // the first one's move — no collapse, no cross-contamination.
        #expect(siblingAfter.title == "Weekly Practice")
    }

    // 10. mapping disabled -> no new import
    @Test("A disabled mapping is never reconciled — no import happens")
    @MainActor
    func disabledMappingImportsNothing() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId,
            calendarIdentifier: "cal-1",
            calendarTitle: "Spond Team",
            activityType: .individualTraining,
            sportId: nil
        )
        // Deliberately never enabled.
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]

        let results = try fixture.coordinationService.reconcileAllEnabledMappings()
        #expect(results[mapping.calendarPlanningMappingId] == nil)

        let activities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activities.isEmpty)
    }

    // 11. permission denial leaves normal Planning functional
    @Test("A denied Calendar permission does not prevent normal Planning mutations")
    @MainActor
    func permissionDenialLeavesPlanningFunctional() throws {
        let fixture = try makeFixture()
        fixture.calendarProvider.authStatus = .denied

        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(
            athleteId: fixture.athleteId, weekStart: Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        )
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: "Manual session", localDate: weekPlan.weekStart, timeZoneId: Self.timeZoneId
        )
        #expect(activity.title == "Manual session")

        // No enabled mapping exists, so reconciliation is a no-op — never
        // an error surfaced to Planning.
        let results = try fixture.coordinationService.reconcileAllEnabledMappings()
        #expect(results.isEmpty)
    }

    // 12. source A and source B cannot accidentally cross-link identities
    @Test("Two different calendars mapped to different athletes never cross-link identities")
    @MainActor
    func differentSourcesNeverCrossLink() throws {
        let fixture = try makeFixture()
        let athleteB = try fixture.athleteRepository.createAthlete(
            workspaceId: WorkspaceId(),
            givenName: "Second Athlete",
            birthDate: LocalDate(year: 2013, month: 5, day: 1),
            timeZoneId: Self.timeZoneId,
            developmentStage: .parentLed
        )

        let mappingA = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-A", calendarTitle: "Calendar A",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mappingA.calendarPlanningMappingId, isEnabled: true)
        let mappingB = try fixture.coordinationService.createMapping(
            athleteId: athleteB.athleteId, calendarIdentifier: "cal-B", calendarTitle: "Calendar B",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mappingB.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        // Deliberately identical eventIdentifier across two different
        // calendars — the composite `calendarIdentifier|eventIdentifier`
        // key must still keep them fully separate.
        fixture.calendarProvider.eventsByCalendar["cal-A"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-shared", calendarIdentifier: "cal-A", title: "A's Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        fixture.calendarProvider.eventsByCalendar["cal-B"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-shared", calendarIdentifier: "cal-B", title: "B's Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]

        _ = try fixture.coordinationService.reconcileAllEnabledMappings()

        let activitiesA = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        let activitiesB = try fixture.planningService.fetchPlannedActivities(
            forAthlete: athleteB.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(activitiesA.count == 1)
        #expect(activitiesB.count == 1)
        #expect(activitiesA.first?.title == "A's Practice")
        #expect(activitiesB.first?.title == "B's Practice")
        #expect(activitiesA.first?.externalSourceId != activitiesB.first?.externalSourceId)
    }

    // 14. imported activity time change preserves existing Planning
    // event/lifecycle behavior needed by Activity Reminders
    @Test("An imported activity's external time change preserves its Activity Reminders (same PlannedActivityId)")
    @MainActor
    func timeChangePreservesActivityReminders() throws {
        // `makeFixture()` does not expose its raw `ModelContext`, and an
        // `ActivityReminderRepository` here needs to be bound to the
        // EXACT same context the rest of this test's stack uses (matching
        // `uses(modelContext:)`'s own "single unit of work" contract other
        // coordination-service tests rely on) — so this test builds its
        // own fixture inline rather than reusing the shared helper.
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let mappingRepository = CalendarPlanningMappingRepository(modelContext: container.mainContext)
        let reminderRepository = ActivityReminderRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let calendarProvider = FakeCalendarEventProvider()
        let coordinationService = CalendarPlanningCoordinationService(
            mappingRepository: mappingRepository,
            calendarEventProvider: calendarProvider,
            planningService: planningService,
            trainingService: trainingService,
            athleteRepository: athleteRepository,
            dateProvider: FixedDateProvider(now: Self.referenceDate)
        )
        let athlete = try athleteRepository.createAthlete(
            workspaceId: WorkspaceId(), givenName: "Runner",
            birthDate: LocalDate(year: 2012, month: 3, day: 1),
            timeZoneId: Self.timeZoneId, developmentStage: .parentLed
        )

        let mapping = try coordinationService.createMapping(
            athleteId: athlete.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Spond Team",
            activityType: .individualTraining, sportId: nil
        )
        try coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try coordinationService.reconcile(mapping)
        let plannedActivityId = try #require(
            try planningService.fetchPlannedActivities(
                forAthlete: athlete.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
            ).first?.plannedActivityId
        )

        _ = try reminderRepository.insert(
            athleteId: athlete.athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: 30
        )

        let newStart = start.addingTimeInterval(1800)
        calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: newStart, endDate: newStart.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        let outcome = try coordinationService.reconcile(mapping)
        #expect(outcome.updated == 1)

        let remindersAfter = try reminderRepository.fetchAll(forPlannedActivity: plannedActivityId)
        #expect(remindersAfter.count == 1)
    }

    // MARK: - removeImportedActivities (Calendar V1 recovery round)

    // 1. cleanup removes eligible Calendar-imported activities for the
    // selected athlete/calendar
    @Test("removeImportedActivities removes an eligible future, unlogged imported activity for the mapping's athlete/calendar")
    @MainActor
    func cleanupRemovesEligibleImportedActivity() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Oliver's Football",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)
        #expect(try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        ).count == 1)

        let outcome = try fixture.coordinationService.removeImportedActivities(for: mapping, removedBy: ActorId())

        #expect(outcome.removed == 1)
        #expect(outcome.preservedLogged == 0)
        #expect(outcome.historicalWeeksSkipped == 0)
        #expect(outcome.failed == 0)
        let remaining = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(remaining.isEmpty)
    }

    // 2. manually-created PlannedActivities remain
    @Test("removeImportedActivities never touches a manually-created PlannedActivity (no externalSourceType)")
    @MainActor
    func cleanupPreservesManuallyCreatedActivity() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)

        let today = Self.referenceDate.startOfWeekLocalDate(timeZoneId: Self.timeZoneId)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: fixture.athleteId, weekStart: today)
        let manual = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: "Manually added session", localDate: today, timeZoneId: Self.timeZoneId
        )

        let outcome = try fixture.coordinationService.removeImportedActivities(for: mapping, removedBy: ActorId())
        #expect(outcome.removed == 0)

        let stillThere = try fixture.planningService.fetchPlannedActivity(byId: manual.plannedActivityId)
        #expect(stillThere != nil)
    }

    // 3. Calendar-imported activities belonging to another athlete remain
    @Test("removeImportedActivities never touches another athlete's activity imported from the SAME calendar")
    @MainActor
    func cleanupPreservesOtherAthletesImportedActivity() throws {
        let fixture = try makeFixture()
        let athleteB = try fixture.athleteRepository.createAthlete(
            workspaceId: WorkspaceId(), givenName: "Second Athlete",
            birthDate: LocalDate(year: 2013, month: 5, day: 1), timeZoneId: Self.timeZoneId, developmentStage: .parentLed
        )
        let mappingA = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mappingA.calendarPlanningMappingId, isEnabled: true)
        let mappingB = try fixture.coordinationService.createMapping(
            athleteId: athleteB.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mappingB.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        // Both mappings reference the same real EventKit calendar (the
        // exact mixed-calendar scenario this round exists for) — both
        // reconcile independently, so both athletes end up with their
        // own imported copy.
        _ = try fixture.coordinationService.reconcile(mappingA)
        _ = try fixture.coordinationService.reconcile(mappingB)

        let outcome = try fixture.coordinationService.removeImportedActivities(for: mappingA, removedBy: ActorId())
        #expect(outcome.removed == 1)

        let athleteAActivities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        let athleteBActivities = try fixture.planningService.fetchPlannedActivities(
            forAthlete: athleteB.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(athleteAActivities.isEmpty)
        #expect(athleteBActivities.count == 1)
    }

    // 4. activities imported from another calendar remain
    @Test("removeImportedActivities never touches the SAME athlete's activity imported from a DIFFERENT calendar")
    @MainActor
    func cleanupPreservesOtherCalendarsImportedActivity() throws {
        let fixture = try makeFixture()
        let mappingA = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-A", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mappingA.calendarPlanningMappingId, isEnabled: true)
        let mappingB = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-B", calendarTitle: "Oliver Football",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mappingB.calendarPlanningMappingId, isEnabled: true)

        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-A"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-A", title: "From A",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        fixture.calendarProvider.eventsByCalendar["cal-B"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-B", title: "From B",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mappingA)
        _ = try fixture.coordinationService.reconcile(mappingB)

        let outcome = try fixture.coordinationService.removeImportedActivities(for: mappingA, removedBy: ActorId())
        #expect(outcome.removed == 1)

        let remaining = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(remaining.count == 1)
        #expect(remaining.first?.title == "From B")
    }

    // 5. logged/proven Training is preserved
    @Test("removeImportedActivities never removes an imported activity that already has a LoggedActivity")
    @MainActor
    func cleanupPreservesLoggedActivity() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)
        let plannedActivityId = try #require(
            try fixture.planningService.fetchPlannedActivities(
                forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
            ).first?.plannedActivityId
        )
        _ = try fixture.trainingService.logActivity(
            athleteId: fixture.athleteId, plannedActivityId: plannedActivityId,
            activityType: .individualTraining, title: "Practice", startedAt: start
        )

        let outcome = try fixture.coordinationService.removeImportedActivities(for: mapping, removedBy: ActorId())

        #expect(outcome.removed == 0)
        #expect(outcome.preservedLogged == 1)
        let remaining = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(remaining.count == 1)
        #expect(remaining.first?.plannedActivityId == plannedActivityId)
    }

    // 6. committed eligible current/future week is handled through
    // canonical Planning semantics
    @Test("removeImportedActivities reopens a committed CURRENT/FUTURE week through PlanningService.reopenWeekPlan, then removes the activity")
    @MainActor
    func cleanupReopensCommittedCurrentWeek() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)
        let activity = try #require(
            try fixture.planningService.fetchPlannedActivities(
                forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
            ).first
        )
        let weekPlanId = WeekPlanId(rawValue: activity.weekPlanId)
        let weekPlan = try #require(try fixture.planningService.fetchWeekPlan(byId: weekPlanId))
        try fixture.planningService.commitWeekPlan(weekPlanId, expectedRevision: weekPlan.revision, committedBy: ActorId())
        #expect(try #require(fixture.planningService.fetchWeekPlan(byId: weekPlanId)).status == .committed)

        let outcome = try fixture.coordinationService.removeImportedActivities(for: mapping, removedBy: ActorId())

        #expect(outcome.removed == 1)
        #expect(outcome.historicalWeeksSkipped == 0)
        #expect(outcome.failed == 0)
        let remaining = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(remaining.isEmpty)
    }

    // 7. historical Planning is never destructively reopened
    @Test("removeImportedActivities never reopens a committed HISTORICAL week — the activity is left in place and counted as historicalWeeksSkipped")
    @MainActor
    func cleanupNeverReopensHistoricalWeek() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        // A historical week (well before Self.referenceDate's own week)
        // seeded directly via the normal Planning mutation path, tagged
        // with this mapping's own calendarIdentifier prefix — simulating
        // an import that was never cleaned up before the week became
        // historical and got committed.
        let historicalWeekStart = LocalDate(year: 2025, month: 12, day: 1)
        let weekPlan = try fixture.planningService.getOrCreateWeekPlan(athleteId: fixture.athleteId, weekStart: historicalWeekStart)
        let activity = try fixture.planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: fixture.athleteId, activityType: .individualTraining,
            title: "Old Practice", localDate: historicalWeekStart, timeZoneId: Self.timeZoneId,
            externalSourceId: "cal-1|evt-old", externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        try fixture.planningService.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: weekPlan.revision, committedBy: ActorId())

        let outcome = try fixture.coordinationService.removeImportedActivities(for: mapping, removedBy: ActorId())

        #expect(outcome.removed == 0)
        #expect(outcome.historicalWeeksSkipped == 1)
        #expect(outcome.failed == 0)
        let stillCommitted = try #require(try fixture.planningService.fetchWeekPlan(byId: weekPlan.weekPlanId))
        #expect(stillCommitted.status == .committed)
        let remaining = try fixture.planningService.fetchPlannedActivities(
            forAthlete: fixture.athleteId, externalSourceType: CalendarPlanningCoordinationService.externalSourceType
        )
        #expect(remaining.count == 1)
        #expect(remaining.first?.plannedActivityId == activity.plannedActivityId)
    }

    // 8. repeated cleanup is safe/idempotent
    @Test("Calling removeImportedActivities a second time is a safe no-op once everything eligible has already been removed")
    @MainActor
    func cleanupIsIdempotent() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        try fixture.coordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: true)
        let start = Self.referenceDate.addingTimeInterval(3600)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false
            )
        ]
        _ = try fixture.coordinationService.reconcile(mapping)

        let first = try fixture.coordinationService.removeImportedActivities(for: mapping, removedBy: ActorId())
        let second = try fixture.coordinationService.removeImportedActivities(for: mapping, removedBy: ActorId())

        #expect(first.removed == 1)
        #expect(second.removed == 0)
        #expect(second.preservedLogged == 0)
        #expect(second.historicalWeeksSkipped == 0)
        #expect(second.failed == 0)
    }

    // MARK: - Diagnostic metadata inspection (Calendar V1 metadata round)

    // 9. provider maps notes/location/URL correctly when present
    @Test("fetchDiagnosticEvents returns notes/location/URL exactly as the provider supplies them, bounded and sorted, and these fields never affect identity")
    @MainActor
    func diagnosticEventsCarryNotesLocationURL() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        let start = Self.referenceDate.addingTimeInterval(3600)
        let sampleURL = try #require(URL(string: "https://spond.com/group/abc123"))
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Oliver's Football",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false,
                notes: "Group: U10 Boys Football", location: "Main Pitch", url: sampleURL
            )
        ]

        let events = try fixture.coordinationService.fetchDiagnosticEvents(inCalendar: mapping.calendarIdentifier)

        #expect(events.count == 1)
        #expect(events.first?.notes == "Group: U10 Boys Football")
        #expect(events.first?.location == "Main Pitch")
        #expect(events.first?.url == sampleURL)

        // Identity is unaffected by notes/location/URL: an otherwise-
        // identical event with DIFFERENT diagnostic metadata still
        // reconciles as an UPDATE to the same PlannedActivity, never a
        // second one.
        _ = try fixture.coordinationService.reconcile(mapping)
        fixture.calendarProvider.eventsByCalendar["cal-1"] = [
            ExternalCalendarEvent(
                eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Oliver's Football",
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, isRecurring: false,
                notes: "Completely different notes", location: "A different field", url: nil
            )
        ]
        let outcome = try fixture.coordinationService.reconcile(mapping)
        #expect(outcome.created == 0)
        #expect(outcome.updated == 1)
    }

    // 10. missing optional metadata is handled safely
    @Test("fetchDiagnosticEvents handles an event with no notes/location/URL without error, and bounds/sorts results")
    @MainActor
    func diagnosticEventsHandleMissingMetadataAndBounding() throws {
        let fixture = try makeFixture()
        let mapping = try fixture.coordinationService.createMapping(
            athleteId: fixture.athleteId, calendarIdentifier: "cal-1", calendarTitle: "Familie",
            activityType: .individualTraining, sportId: nil
        )
        let start = Self.referenceDate.addingTimeInterval(3600)
        // 12 events, deliberately unsorted and with no notes/location/url
        // — more than diagnosticEventLimit (10), and none carrying the
        // optional metadata at all.
        fixture.calendarProvider.eventsByCalendar["cal-1"] = (0..<12).map { index in
            let eventStart = start.addingTimeInterval(TimeInterval(11 - index) * 3600)
            return ExternalCalendarEvent(
                eventIdentifier: "evt-\(index)", calendarIdentifier: "cal-1", title: "Practice \(index)",
                startDate: eventStart, endDate: eventStart.addingTimeInterval(1800), isAllDay: false, isRecurring: false
            )
        }

        let events = try fixture.coordinationService.fetchDiagnosticEvents(inCalendar: mapping.calendarIdentifier)

        #expect(events.count == CalendarPlanningCoordinationService.diagnosticEventLimit)
        #expect(events.allSatisfy { $0.notes == nil && $0.location == nil && $0.url == nil })
        // Sorted by startDate ascending — the earliest 10 of the 12 are
        // kept.
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
