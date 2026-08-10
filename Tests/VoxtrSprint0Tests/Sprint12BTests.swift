import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
@Suite("Sprint 1.2B: Today read model + multi-weekday recurrence", .serialized)
struct Sprint12BTests {

    // MARK: - Multi-weekday derivation

    /// Item 1: multi-weekday recurring definition derives every
    /// expected date. Monday-Friday camp within a WeekPlan's own
    /// 7-day week must produce exactly 5 occurrences, one per weekday.
    @Test("Monday-Friday recurring definition derives 5 occurrences within one week")
    @MainActor
    func multiWeekdayDefinitionDerivesEveryExpectedDate() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Ice Rink",
            effectiveStartDate: weekStart, effectiveEndDate: weekStart.adding(days: 6)
        )

        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        #expect(suggestions.count == 5)
        let derivedWeekdays = Set(suggestions.map(\.occurrenceDate.weekday))
        #expect(derivedWeekdays == [.monday, .tuesday, .wednesday, .thursday, .friday])
        // Never five hidden separate definitions — one definition, one row.
        let definitions = try planningRepository.fetchRecurringPlannedActivities(forAthlete: athleteId)
        #expect(definitions.count == 1)
    }

    /// Item 2: existing single-weekday recurring behavior remains valid
    /// — a definition with exactly one weekday still derives exactly
    /// one occurrence per week, unchanged from before this package.
    @Test("Single-weekday recurring definition still derives exactly one occurrence per week")
    @MainActor
    func singleWeekdayRegressionRemainsCorrect() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Football Training", activityType: .teamTraining,
            weekdays: [.tuesday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: weekStart, effectiveEndDate: weekStart.adding(days: 6)
        )

        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.occurrenceDate.weekday == .tuesday)
    }

    /// Item 3: date range boundaries are respected — a weekday outside
    /// the definition's own effective date range never derives an
    /// occurrence, even if it matches the weekday set.
    ///
    /// Restored to an explicit assertion: `TrainingPlanningCoordinationService.weekStart()`
    /// now deterministically returns Monday (Vǫxtr's own Monday →
    /// Sunday week, via `LocalDate.startOfWeek` — no longer dependent
    /// on `Calendar.current`'s locale-configured `firstWeekday`). So
    /// `weekStart` is genuinely Monday and `weekStart.adding(days: 2)`
    /// is genuinely Wednesday, regardless of the environment this test
    /// runs in — the earlier, locale-defensive version of this test is
    /// no longer needed. The already-confirmed inclusive
    /// `effectiveStartDate...effectiveEndDate` contract (`<=` on both
    /// ends, unchanged by this fix) is what's being exercised here.
    @Test("Date range boundaries are respected for multi-weekday definitions")
    @MainActor
    func dateRangeBoundariesRespected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        #expect(weekStart.weekday == .monday)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        // Effective range covers only Mon-Wed of this week, even though
        // the definition lists Mon-Fri.
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: weekStart, effectiveEndDate: weekStart.adding(days: 2)
        )

        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        #expect(suggestions.count == 3)
        #expect(Set(suggestions.map(\.occurrenceDate.weekday)) == [.monday, .tuesday, .wednesday])
    }

    /// Item 4/5: athlete identity, location, time, and duration are
    /// preserved for every derived occurrence in a multi-weekday
    /// definition.
    @Test("Athlete identity, location, time, and duration preserved across all derived occurrences")
    @MainActor
    func identityAndFieldsPreservedAcrossOccurrences() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [.monday, .wednesday, .friday], startLocalTime: LocalTime(hour: 9, minute: 0),
            plannedDurationMinutes: 120, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            location: "Ice Rink", effectiveStartDate: weekStart, effectiveEndDate: weekStart.adding(days: 6)
        )

        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        #expect(suggestions.count == 3)
        for suggestion in suggestions {
            #expect(suggestion.athleteId == athleteId)
            #expect(suggestion.location == "Ice Rink")
            #expect(suggestion.startLocalTime?.hour == 9)
            #expect(suggestion.plannedDurationMinutes == 120)
        }
    }

    /// Item 6: Family Schedule's own date-range derivation
    /// (`deriveSuggestions(forAthlete:from:through:)`) receives every
    /// occurrence from a multi-weekday definition, not just some —
    /// confirms it consumes the same, single canonical derivation this
    /// package updated, not a second implementation.
    @Test("Family Schedule receives all occurrences from a multi-weekday definition")
    @MainActor
    func familyScheduleReceivesAllMultiWeekdayOccurrences() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        guard let inThreeDays = Calendar.current.date(byAdding: .day, value: 3, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: inThreeDays)
        let startDate = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        let endDate = startDate.adding(days: 6)

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: startDate, effectiveEndDate: endDate
        )

        let scheduleViewModel = FamilyScheduleViewModel(
            activeAthletes: [oliver],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        scheduleViewModel.loadSchedule()

        let recurringRowCount = scheduleViewModel.dayGroups.reduce(0) { total, group in
            total + group.rows.filter {
                if case .recurringSuggestion = $0 { return true }
                return false
            }.count
        }
        #expect(recurringRowCount == 5)
    }

    // MARK: - Today read model (TodayActivityComposer)

    /// Item 7: today's read model includes an unmaterialized recurring
    /// occurrence when one applies today.
    @Test("TodayActivityComposer includes today's unmaterialized recurring occurrence")
    @MainActor
    func todayComposerIncludesUnmaterializedRecurringOccurrence() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        let composer = TodayActivityComposer(
            planningService: planningService, trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let rows = try composer.todayActivities(forAthlete: athleteId, athleteName: "Oliver")

        let hasRecurring = rows.contains { if case .recurringOccurrence = $0 { return true }; return false }
        #expect(hasRecurring)
    }

    /// Item 8: today's read model includes a genuinely unplanned
    /// LoggedActivity.
    @Test("TodayActivityComposer includes an unplanned logged activity")
    @MainActor
    func todayComposerIncludesUnplannedLoggedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()

        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Spontaneous run",
            startedAt: .now, durationMinutes: 30
        )

        let composer = TodayActivityComposer(
            planningService: planningService, trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let rows = try composer.todayActivities(forAthlete: athleteId, athleteName: "Oliver")

        let unplannedRows = rows.compactMap { row -> LoggedActivity? in
            if case .unplannedLogged(_, _, let logged) = row { return logged }
            return nil
        }
        #expect(unplannedRows.count == 1)
        #expect(unplannedRows.first?.title == "Spontaneous run")
    }

    /// Item 9: a planned activity with a linked logged activity
    /// produces exactly one row — never a second, separate
    /// "unplanned logged" row for the same activity.
    @Test("Planned + logged relationship produces exactly one row, never two")
    @MainActor
    func plannedAndLoggedProducesOneRow() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: "Run", startedAt: .now, durationMinutes: 45
        )

        let composer = TodayActivityComposer(
            planningService: planningService, trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let rows = try composer.todayActivities(forAthlete: athleteId, athleteName: "Oliver")

        let matchingRows = rows.filter { $0.id == activity.plannedActivityId.rawValue.uuidString }
        #expect(matchingRows.count == 1)
        if case .planned(let familyHomeRow) = matchingRows.first {
            #expect(familyHomeRow.isCompleted == true)
        } else {
            Issue.record("Expected a .planned row")
        }
        // No separate .unplannedLogged row for the same underlying log.
        let unplannedCount = rows.filter { if case .unplannedLogged = $0 { return true }; return false }.count
        #expect(unplannedCount == 0)
    }

    /// Item 10: a materialized recurring occurrence produces exactly
    /// one row — never a duplicate recurring-suggestion row alongside
    /// the materialized planned row.
    @Test("Materialized recurring occurrence produces exactly one row, not a duplicate suggestion")
    @MainActor
    func materializedRecurringOccurrenceDoesNotDuplicate() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )
        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let suggestion = try #require(suggestions.first)
        let materialized = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)

        let composer = TodayActivityComposer(
            planningService: planningService, trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let rows = try composer.todayActivities(forAthlete: athleteId, athleteName: "Oliver")

        let recurringSuggestionCount = rows.filter { if case .recurringOccurrence = $0 { return true }; return false }.count
        let plannedCount = rows.filter { $0.id == materialized.plannedActivityId.rawValue.uuidString }.count
        #expect(recurringSuggestionCount == 0)
        #expect(plannedCount == 1)
    }

    /// Item 11: a logged, materialized recurring occurrence still
    /// produces exactly one row (completed), never a third
    /// representation.
    @Test("Logged materialized recurring occurrence still produces one row")
    @MainActor
    func loggedMaterializedRecurringOccurrenceProducesOneRow() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )
        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let suggestion = try #require(suggestions.first)
        let materialized = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: materialized.plannedActivityId,
            activityType: .teamTraining, title: "Hockey Camp", startedAt: .now, durationMinutes: 90
        )

        let composer = TodayActivityComposer(
            planningService: planningService, trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let rows = try composer.todayActivities(forAthlete: athleteId, athleteName: "Oliver")

        let matchingRows = rows.filter { $0.id == materialized.plannedActivityId.rawValue.uuidString }
        #expect(matchingRows.count == 1)
        if case .planned(let familyHomeRow) = matchingRows.first {
            #expect(familyHomeRow.isCompleted == true)
        } else {
            Issue.record("Expected a .planned row")
        }
    }

    /// Item 12: two athletes never cross-link/deduplicate each other's
    /// today activities.
    @Test("Two athletes' today activities never cross-link")
    @MainActor
    func twoAthletesNeverCrossLinkInTodayComposer() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliverId = AthleteId()
        let emmaId = AthleteId()

        _ = try trainingService.logActivity(
            athleteId: oliverId, activityType: .individualTraining, title: "Oliver's run",
            startedAt: .now, durationMinutes: 30
        )

        let composer = TodayActivityComposer(
            planningService: planningService, trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let oliverRows = try composer.todayActivities(forAthlete: oliverId, athleteName: "Oliver")
        let emmaRows = try composer.todayActivities(forAthlete: emmaId, athleteName: "Emma")

        #expect(oliverRows.count == 1)
        #expect(emmaRows.isEmpty)
    }

    /// Item 13: materialization is idempotent — repeated calls to
    /// `materializeOrFetchExisting` for the same suggestion resolve to
    /// the SAME PlannedActivity, never create a second one.
    @Test("Repeated materialization attempts resolve to the same PlannedActivity, never a duplicate")
    @MainActor
    func materializationIsIdempotent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )
        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let suggestion = try #require(suggestions.first)

        let first = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
        let second = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
        let third = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)

        #expect(first.plannedActivityId == second.plannedActivityId)
        #expect(second.plannedActivityId == third.plannedActivityId)

        let allActivities = try planningRepository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        #expect(allActivities.count == 1)
    }

    /// Item 14: existing duplicate-log protection remains intact after
    /// all this package's changes.
    @Test("Existing duplicate-PlannedActivity-log protection remains intact")
    @MainActor
    func existingDuplicateLogProtectionRemainsIntact() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: "Run", startedAt: .now, durationMinutes: 45
        )

        #expect(throws: TrainingServiceError.plannedActivityAlreadyLinked) {
            try trainingService.logActivity(
                athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
                activityType: .individualTraining, title: "Run", startedAt: .now, durationMinutes: 45
            )
        }
    }

    // MARK: - Locale-independence regression (deterministic Monday->Sunday week)

    /// `LocalDate.startOfWeek` itself takes no `Calendar` parameter —
    /// it's built purely from `weekday` (already locale-independent).
    /// Confirms every day of a known week maps to the same Monday,
    /// proving the canonical rule directly rather than only indirectly
    /// through a caller.
    @Test("LocalDate.startOfWeek is deterministically Monday for every day of the week")
    func startOfWeekIsDeterministicallyMonday() throws {
        // A known Monday: 2026-08-10.
        let monday = LocalDate(year: 2026, month: 8, day: 10)
        let weekDates = (0..<7).map { monday.adding(days: $0) }
        for date in weekDates {
            #expect(date.startOfWeek == monday)
        }
        // The following Monday must NOT collapse into the same week.
        let nextMonday = monday.adding(days: 7)
        #expect(nextMonday.startOfWeek == nextMonday)
    }

    /// Regression guard for the actual bug found in this package:
    /// `TrainingPlanningCoordinationService.weekStart(referenceDate:calendar:)`
    /// must return the SAME Monday regardless of the passed calendar's
    /// own `firstWeekday` — proving the fix without mutating global
    /// process locale (which would be brittle/order-dependent across a
    /// test suite); passing explicit, differently-configured `Calendar`
    /// values is the direct, non-brittle way to exercise this. Calls
    /// `TrainingPlanningCoordinationService.weekStart` directly (not
    /// `LocalDate.startOfWeek` alone) because that's the only function
    /// that even accepts a `Calendar` parameter to vary — `startOfWeek`
    /// has none, so it can't exercise this specific claim.
    /// `@MainActor` here because `TrainingPlanningCoordinationService`
    /// is itself `@MainActor`-isolated — matches every other test in
    /// this suite that calls it.
    @Test("weekStart is identical regardless of the calendar's own firstWeekday configuration")
    @MainActor
    func weekStartIgnoresCalendarFirstWeekday() throws {
        // A known Wednesday: 2026-08-12. Its Monday is 2026-08-10.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let referenceDate = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 12)) ?? .now

        var sundayFirstCalendar = utcCalendar
        sundayFirstCalendar.firstWeekday = 1 // Sunday — e.g. a US locale.
        var mondayFirstCalendar = utcCalendar
        mondayFirstCalendar.firstWeekday = 2 // Monday — e.g. many European locales.

        let expectedMonday = LocalDate(year: 2026, month: 8, day: 10)
        let resultWithSundayFirst = TrainingPlanningCoordinationService.weekStart(referenceDate: referenceDate, calendar: sundayFirstCalendar)
        let resultWithMondayFirst = TrainingPlanningCoordinationService.weekStart(referenceDate: referenceDate, calendar: mondayFirstCalendar)

        #expect(resultWithSundayFirst == expectedMonday)
        #expect(resultWithMondayFirst == expectedMonday)
        #expect(resultWithSundayFirst == resultWithMondayFirst)
    }
}
