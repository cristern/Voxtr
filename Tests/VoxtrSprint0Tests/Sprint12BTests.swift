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
    /// occurrence from a multi-weekday definition that falls inside the
    /// approved rolling window, not just some — confirms it consumes the
    /// same, single canonical derivation this package updated, not a
    /// second implementation.
    ///
    /// Fix: the previous version of this test computed its recurring
    /// definition's effective range from `.now + 3 days`, then asserted
    /// a hardcoded count of 5. Family Schedule's own window is the
    /// approved `today...today+7` rolling range (`FamilyScheduleViewModel.upcomingDayCount`,
    /// inclusive both ends) — not the Monday-Sunday Weekly Planning
    /// week — and `.now + 3 days` through `.now + 9 days` only
    /// coincidentally lined up with that window's 5 weekday slots when
    /// "today" happened to be a Friday when CI ran. On any other
    /// weekday, part of that range falls outside `today...today+7` by
    /// design, so fewer than 5 of the Mon-Fri occurrences land inside
    /// the approved window — that's what produced the flaky 4 vs 5
    /// result, not a production defect. Rewritten with an explicit,
    /// deterministic reference date (`loadSchedule(referenceDate:calendar:)`,
    /// same pattern as `FamilyScheduleAndTomorrowTests`) and a range
    /// that spans exactly one day past the window's boundary, so the
    /// expected occurrence set is derived directly from the explicit
    /// dates rather than asserted as a magic number, and the boundary
    /// itself (included) versus the day just past it (excluded) is
    /// checked explicitly.
    @Test("Family Schedule receives all occurrences from a multi-weekday definition inside the approved today-through-+7 window, and excludes the one just past it")
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

        // Deterministic "today": 2026-01-05, a known Monday (same fixed
        // date already used elsewhere in this suite, e.g.
        // WeeklyReflectionServiceTests). Never dependent on `.now` or
        // the weekday CI happens to run on.
        var referenceComponents = DateComponents()
        referenceComponents.year = 2026; referenceComponents.month = 1; referenceComponents.day = 5
        let calendar = Calendar(identifier: .gregorian)
        guard let referenceDate = calendar.date(from: referenceComponents) else {
            Issue.record("Could not compute reference date"); return
        }
        let today = LocalDate(year: 2026, month: 1, day: 5)
        let windowEnd = today.adding(days: 7) // 2026-01-12 (Monday) — the approved window's inclusive boundary.
        let justPastWindow = windowEnd.adding(days: 1) // 2026-01-13 (Tuesday) — one day beyond it.

        // Mon-Fri definition effective from today through the day after
        // the window's boundary: its raw weekday matches are Jan 5-9
        // (Mon-Fri), Jan 12 (Mon), and Jan 13 (Tue) — spanning both the
        // interior of the approved window and just past it, so this
        // single scenario proves inclusion up to the boundary and
        // exclusion immediately past it.
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday],
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: today, effectiveEndDate: justPastWindow
        )

        let scheduleViewModel = FamilyScheduleViewModel(
            activeAthletes: [oliver],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        scheduleViewModel.loadSchedule(referenceDate: referenceDate, calendar: calendar)

        let recurringDates = scheduleViewModel.dayGroups.reduce(into: Set<LocalDate>()) { dates, group in
            let hasRecurringRow = group.rows.contains {
                if case .recurringSuggestion = $0 { return true }
                return false
            }
            if hasRecurringRow { dates.insert(group.date) }
        }

        // Six weekday occurrences fall inside [today, windowEnd]: the
        // Mon-Fri interior (Jan 5-9) plus the boundary Monday (Jan 12)
        // itself — every one of them must be present.
        #expect(recurringDates == [
            today, today.adding(days: 1), today.adding(days: 2), today.adding(days: 3), today.adding(days: 4),
            windowEnd
        ])
        // The 7th weekday match, Jan 13, sits one day beyond the
        // approved rolling window and must be excluded.
        #expect(!recurringDates.contains(justPastWindow))
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

    /// Sprint 1.2B runtime closeout (P0): the actual root cause fixed
    /// in this package — `materializeOrFetchExisting` previously called
    /// `acceptSuggestion`, which requires `weekPlan.status == .draft`.
    /// A committed WeekPlan (completely ordinary by the time "today"
    /// arrives) made every "Log Activity" tap on a recurring occurrence
    /// throw `.weekPlanNotDraft` — an error the recovery `catch` never
    /// handled, surfacing as "Could not open the activity" in the UI.
    /// Extends the existing idempotency test above rather than adding a
    /// new file, per this package's own test-strategy guidance.
    @Test("Materializing a recurring occurrence succeeds even when the WeekPlan is already committed, and remains idempotent there too")
    @MainActor
    func materializationSucceedsAgainstCommittedWeekPlan() throws {
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

        // Commit the plan BEFORE ever attempting to materialize this
        // occurrence — this is the exact P0 scenario, not a repeat-tap
        // scenario.
        _ = try planningService.commitWeekPlan(weekPlan.weekPlanId, expectedRevision: 1, committedBy: ActorId())

        let first = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
        // A second tap after the first successful materialization must
        // still resolve to the same activity, not fail or duplicate,
        // even though the plan remains committed throughout.
        let second = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)

        #expect(first.plannedActivityId == second.plannedActivityId)
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

    // MARK: - Stale recurring preview fix (RecurringOccurrencePreviewView)

    /// Protects the exact invariant `RecurringOccurrencePreviewView`'s
    /// own `checkForStaleness()` depends on: `fetchMaterializedPlannedActivity`
    /// must return `nil` for a genuinely unmaterialized occurrence, and
    /// the correct `PlannedActivity` once one has been materialized —
    /// but materialization alone (before any actual log) must NOT be
    /// mistaken for completion. This is what lets the preview
    /// distinguish "user cancelled after materializing" (retain normal
    /// navigation) from "user actually logged it" (unwind).
    @Test("fetchMaterializedPlannedActivity distinguishes unmaterialized, materialized-not-logged, and materialized-and-logged")
    @MainActor
    func fetchMaterializedPlannedActivityDistinguishesLifecycleStages() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
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

        // Stage 1: genuinely unmaterialized.
        #expect(try planningService.fetchMaterializedPlannedActivity(for: suggestion) == nil)

        // Stage 2: materialized (the "Log Activity" tap), but not yet
        // logged — the exact "user might still cancel" window.
        let materialized = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
        let stage2 = try planningService.fetchMaterializedPlannedActivity(for: suggestion)
        #expect(stage2?.plannedActivityId == materialized.plannedActivityId)
        #expect(try trainingService.fetchLoggedActivities(forPlannedActivity: materialized.plannedActivityId).isEmpty)

        // Stage 3: actually logged.
        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: materialized.plannedActivityId,
            activityType: .teamTraining, title: "Hockey Camp", startedAt: .now, durationMinutes: 90
        )
        #expect(try !trainingService.fetchLoggedActivities(forPlannedActivity: materialized.plannedActivityId).isEmpty)
    }
}
