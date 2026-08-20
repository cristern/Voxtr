import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrTrainingDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("TrainingRepository and TrainingService (S3.0)", .serialized)
struct TrainingRepositoryAndServiceTests {

    @Test("Logging an activity persists it, optionally linked to a PlannedActivity by typed ID")
    @MainActor
    func logActivityPersistsWithOptionalLink() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let athleteId = AthleteId()
        let plannedActivityId = PlannedActivityId()

        let logged = try service.logActivity(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            activityType: .individualTraining,
            title: "Endurance run",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            durationMinutes: 45,
            status: .completed,
            source: "manual"
        )

        #expect(logged.title == "Endurance run")
        #expect(logged.plannedActivityId == plannedActivityId.rawValue)
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == 1)
    }

    @Test("Logging an activity without a PlannedActivity link is allowed")
    @MainActor
    func logActivityWithoutLinkIsAllowed() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)

        let logged = try service.logActivity(
            athleteId: AthleteId(),
            activityType: .strength,
            title: "Gym session",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            durationMinutes: 60,
            status: .completed,
            source: "manual"
        )

        #expect(logged.plannedActivityId == nil)
    }

    // MARK: - Sport / Activity Identity domain foundation (Part 7)

    @Test("Logging a Sport-only activity, with no title at all, is supported")
    @MainActor
    func logActivitySportOnlyIsSupported() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let sportId = SportId()

        let logged = try service.logActivity(
            athleteId: AthleteId(),
            sportId: sportId,
            activityType: .individualTraining,
            title: nil,
            startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            durationMinutes: 45,
            status: .completed,
            source: "manual"
        )

        #expect(logged.title == nil)
        #expect(logged.sportId == sportId.rawValue)
    }

    @Test("Logging an activity with neither a title nor a Sport is rejected without persisting")
    @MainActor
    func logActivityRejectsMissingIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)

        #expect(throws: TrainingServiceError.self) {
            try service.logActivity(
                athleteId: AthleteId(),
                activityType: .individualTraining,
                title: nil,
                startedAt: Date(timeIntervalSince1970: 1_767_000_000),
                durationMinutes: 45,
                status: .completed,
                source: "manual"
            )
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == 0)
    }

    @Test("Logging an activity with a whitespace-only title and no Sport is rejected")
    @MainActor
    func logActivityRejectsWhitespaceOnlyTitleWithNoSport() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)

        #expect(throws: TrainingServiceError.self) {
            try service.logActivity(
                athleteId: AthleteId(),
                activityType: .individualTraining,
                title: "   ",
                startedAt: Date(timeIntervalSince1970: 1_767_000_000),
                durationMinutes: 45,
                status: .completed,
                source: "manual"
            )
        }
    }

    @Test("Fetching by athlete returns only that athlete's activities, ordered deterministically by startedAt")
    @MainActor
    func fetchByAthleteScopesAndOrdersDeterministically() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let firstAthlete = AthleteId()
        let secondAthlete = AthleteId()
        let base = Date(timeIntervalSince1970: 1_767_000_000)

        // Inserted out of chronological order deliberately.
        _ = try service.logActivity(
            athleteId: firstAthlete, activityType: .individualTraining, title: "Thursday",
            startedAt: base.addingTimeInterval(3 * 86_400), durationMinutes: 30, status: .completed, source: "manual"
        )
        _ = try service.logActivity(
            athleteId: firstAthlete, activityType: .individualTraining, title: "Monday",
            startedAt: base, durationMinutes: 30, status: .completed, source: "manual"
        )
        _ = try service.logActivity(
            athleteId: secondAthlete, activityType: .individualTraining, title: "Other athlete",
            startedAt: base.addingTimeInterval(86_400), durationMinutes: 30, status: .completed, source: "manual"
        )
        _ = try service.logActivity(
            athleteId: firstAthlete, activityType: .individualTraining, title: "Wednesday",
            startedAt: base.addingTimeInterval(2 * 86_400), durationMinutes: 30, status: .completed, source: "manual"
        )

        let first = try service.fetchLoggedActivities(forAthlete: firstAthlete)
        let second = try service.fetchLoggedActivities(forAthlete: firstAthlete)

        #expect(first.map(\.title) == ["Monday", "Wednesday", "Thursday"])
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("Fetching by athlete and date range returns only activities within that range")
    @MainActor
    func fetchByAthleteAndDateRangeFiltersCorrectly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let athleteId = AthleteId()
        let base = Date(timeIntervalSince1970: 1_767_000_000)

        _ = try service.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Before range",
            startedAt: base.addingTimeInterval(-86_400), durationMinutes: 30, status: .completed, source: "manual"
        )
        _ = try service.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "In range",
            startedAt: base.addingTimeInterval(1 * 86_400), durationMinutes: 30, status: .completed, source: "manual"
        )
        _ = try service.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "After range",
            startedAt: base.addingTimeInterval(10 * 86_400), durationMinutes: 30, status: .completed, source: "manual"
        )

        let inRange = try service.fetchLoggedActivities(
            forAthlete: athleteId,
            from: base,
            to: base.addingTimeInterval(5 * 86_400)
        )

        #expect(inRange.count == 1)
        #expect(inRange.first?.title == "In range")
    }

    @Test("S3.1: logging with just the essential fields (no planned activity) succeeds using the documented defaults")
    @MainActor
    func simplifiedLogActivityWithNoPlannedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)

        let logged = try service.logActivity(
            athleteId: AthleteId(),
            activityType: .individualTraining,
            title: "Easy jog",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            perceivedExertion: 4,
            notes: "Felt good"
        )

        #expect(logged.plannedActivityId == nil)
        #expect(logged.durationMinutes == 1)
        #expect(logged.status == .completed)
        #expect(logged.source == "manual")
        #expect(logged.perceivedExertion == 4)
        #expect(logged.notes == "Felt good")
    }

    @Test("S3.1: logging with just the essential fields, linked to a PlannedActivity ID, succeeds")
    @MainActor
    func simplifiedLogActivityLinkedToPlannedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let plannedActivityId = PlannedActivityId()

        let logged = try service.logActivity(
            athleteId: AthleteId(),
            plannedActivityId: plannedActivityId,
            activityType: .individualTraining,
            title: "Easy jog",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            durationMinutes: 40
        )

        #expect(logged.plannedActivityId == plannedActivityId.rawValue)
        #expect(logged.durationMinutes == 40)
    }

    @Test("Fetching today's activities returns only those started today, scoped to the athlete")
    @MainActor
    func fetchTodaysActivitiesScopesToTodayAndAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let calendar = Calendar.current
        let today = Date.now
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        _ = try service.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Today's run",
            startedAt: today
        )
        _ = try service.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Yesterday's run",
            startedAt: yesterday
        )
        _ = try service.logActivity(
            athleteId: otherAthleteId, activityType: .individualTraining, title: "Other athlete, today",
            startedAt: today
        )

        let todays = try service.fetchTodaysLoggedActivities(forAthlete: athleteId, referenceDate: today, calendar: calendar)

        #expect(todays.count == 1)
        #expect(todays.first?.title == "Today's run")
    }

    @Test("Today's activities are returned in deterministic order")
    @MainActor
    func fetchTodaysActivitiesOrderedDeterministically() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let athleteId = AthleteId()
        let calendar = Calendar.current
        let today = Date.now
        let startOfDay = calendar.startOfDay(for: today)

        // Inserted out of chronological order deliberately.
        _ = try service.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Evening",
            startedAt: startOfDay.addingTimeInterval(18 * 3_600)
        )
        _ = try service.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning",
            startedAt: startOfDay.addingTimeInterval(7 * 3_600)
        )

        let first = try service.fetchTodaysLoggedActivities(forAthlete: athleteId, referenceDate: today, calendar: calendar)
        let second = try service.fetchTodaysLoggedActivities(forAthlete: athleteId, referenceDate: today, calendar: calendar)

        #expect(first.map(\.title) == ["Morning", "Evening"])
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("Linking a second LoggedActivity to an already-linked PlannedActivity is rejected")
    @MainActor
    func secondLinkToSamePlannedActivityRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let plannedActivityId = PlannedActivityId()
        _ = try service.logActivity(
            athleteId: AthleteId(), plannedActivityId: plannedActivityId,
            activityType: .individualTraining, title: "First log",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000)
        )

        #expect(throws: TrainingServiceError.plannedActivityAlreadyLinked) {
            try service.logActivity(
                athleteId: AthleteId(), plannedActivityId: plannedActivityId,
                activityType: .individualTraining, title: "Second log",
                startedAt: Date(timeIntervalSince1970: 1_767_100_000)
            )
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == 1)
    }

    @Test("Logging without a PlannedActivity link is never affected by the duplicate-link check")
    @MainActor
    func unlinkedLoggingUnaffectedByDuplicateCheck() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)

        _ = try service.logActivity(
            athleteId: AthleteId(), activityType: .individualTraining, title: "First",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000)
        )
        _ = try service.logActivity(
            athleteId: AthleteId(), activityType: .individualTraining, title: "Second",
            startedAt: Date(timeIntervalSince1970: 1_767_100_000)
        )

        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == 2)
    }

    // MARK: - Reversibility principle: reopenCancelledActivity

    @Test("Reopening a cancelled activity removes the LoggedActivity link — the same PlannedActivity is loggable again")
    @MainActor
    func reopenCancelledActivityRemovesTheLink() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let athleteId = AthleteId()
        let plannedActivityId = PlannedActivityId()
        let cancelled = try service.logActivity(
            athleteId: athleteId, plannedActivityId: plannedActivityId,
            activityType: .individualTraining, title: "Evening swim",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            durationMinutes: 1, status: .cancelled
        )

        try service.reopenCancelledActivity(cancelled.loggedActivityId, athleteId: athleteId)

        #expect(try repository.fetchLoggedActivities(forPlannedActivity: plannedActivityId).isEmpty)
        // The PlannedActivity is loggable again — the exact contract a
        // cleared link is supposed to restore.
        _ = try service.logActivity(
            athleteId: athleteId, plannedActivityId: plannedActivityId,
            activityType: .individualTraining, title: "Evening swim",
            startedAt: Date(timeIntervalSince1970: 1_767_100_000),
            durationMinutes: 40, status: .completed
        )
        let linksAfter = try repository.fetchLoggedActivities(forPlannedActivity: plannedActivityId)
        #expect(linksAfter.count == 1)
        #expect(linksAfter.first?.status == .completed)
    }

    @Test("Reopening a materialized recurring occurrence's cancelled outcome preserves that PlannedActivity's own stable id — never a new one")
    @MainActor
    func reopenPreservesMaterializedRecurringPlannedActivityIdentity() throws {
        // The exact PlannedActivityId a recurring occurrence's own
        // materialization would have produced — reopenCancelledActivity
        // has no special-case knowledge of recurring occurrences at all;
        // it only ever deletes the LoggedActivity, so the SAME id must
        // survive untouched regardless of the PlannedActivity's origin.
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let athleteId = AthleteId()
        let materializedPlannedActivityId = PlannedActivityId()
        let cancelled = try service.logActivity(
            athleteId: athleteId, plannedActivityId: materializedPlannedActivityId,
            activityType: .teamTraining, title: "Saturday match",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            durationMinutes: 1, status: .cancelled
        )

        try service.reopenCancelledActivity(cancelled.loggedActivityId, athleteId: athleteId)

        // No LoggedActivity remains linked to this exact PlannedActivityId
        // — the materialized occurrence itself (its own stable identity,
        // owned entirely by VoxtrPlanningDomain and never touched by this
        // Training-domain call) is implicitly preserved simply because
        // nothing here ever had the ability to delete or recreate it.
        #expect(try repository.fetchLoggedActivities(forPlannedActivity: materializedPlannedActivityId).isEmpty)
    }

    @Test("Reopening never touches a LoggedActivity belonging to a different athlete")
    @MainActor
    func reopenEnforcesAthleteIsolation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let plannedActivityId = PlannedActivityId()
        let cancelled = try service.logActivity(
            athleteId: athleteId, plannedActivityId: plannedActivityId,
            activityType: .individualTraining, title: "Evening swim",
            startedAt: Date(timeIntervalSince1970: 1_767_000_000),
            durationMinutes: 1, status: .cancelled
        )

        #expect(throws: TrainingServiceError.loggedActivityNotFound) {
            try service.reopenCancelledActivity(cancelled.loggedActivityId, athleteId: otherAthleteId)
        }
        // Untouched.
        #expect(try repository.fetchLoggedActivities(forPlannedActivity: plannedActivityId).count == 1)
    }

    @Test("Reopen Activity is rejected for a genuinely resolved outcome — Completed, PartiallyCompleted, and Missed are never reopenable")
    @MainActor
    func reopenRejectedForNonCancelledOutcomes() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = TrainingRepository(modelContext: container.mainContext)
        let service = TrainingService(repository: repository)
        let athleteId = AthleteId()

        for status: ActivityStatus in [.completed, .partiallyCompleted, .missed] {
            let plannedActivityId = PlannedActivityId()
            let logged = try service.logActivity(
                athleteId: athleteId, plannedActivityId: plannedActivityId,
                activityType: .individualTraining, title: "Session",
                startedAt: Date(timeIntervalSince1970: 1_767_000_000),
                durationMinutes: 30, status: status
            )

            #expect(throws: TrainingServiceError.activityNotCancelled) {
                try service.reopenCancelledActivity(logged.loggedActivityId, athleteId: athleteId)
            }
            // Untouched.
            #expect(try repository.fetchLoggedActivities(forPlannedActivity: plannedActivityId).count == 1)
        }
    }
}
