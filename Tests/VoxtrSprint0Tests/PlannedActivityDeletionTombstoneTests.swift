import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrPlanningDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("PlannedActivity deletion tombstones (A2)", .serialized)
struct PlannedActivityDeletionTombstoneTests {

    @Test("Deleting a PlannedActivity creates exactly one tombstone")
    @MainActor
    func deletingCreatesExactlyOneTombstone() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        try service.deletePlannedActivity(
            activity.plannedActivityId,
            expectedWeekPlanId: weekPlan.weekPlanId,
            deletedBy: ActorId()
        )

        #expect(try container.mainContext.fetch(FetchDescriptor<PlannedActivityDeletionTombstone>()).count == 1)
    }

    @Test("The tombstone records the correct entity identity, type, and timestamps")
    @MainActor
    func tombstoneContainsCorrectIdentityAndTimestamps() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let deleter = ActorId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let deletedActivityId = activity.id
        let beforeDeletion = Date.now

        try service.deletePlannedActivity(
            activity.plannedActivityId,
            expectedWeekPlanId: weekPlan.weekPlanId,
            deletedBy: deleter
        )

        let tombstones = try container.mainContext.fetch(FetchDescriptor<PlannedActivityDeletionTombstone>())
        let tombstone = try #require(tombstones.first)

        #expect(tombstone.entityId == deletedActivityId)
        #expect(tombstone.entityType == "PlannedActivity")
        #expect(tombstone.deletedBy == deleter.rawValue)
        #expect(tombstone.deletedAt >= beforeDeletion)
        // v1.3 Section 15.1: default 30 days after deletion.
        let expectedPurgeAfter = Calendar.current.date(byAdding: .day, value: 30, to: tombstone.deletedAt)
        #expect(abs(tombstone.purgeAfter.timeIntervalSince(expectedPurgeAfter ?? tombstone.deletedAt)) < 1)
    }

    @Test("A deleted PlannedActivity is no longer returned by normal planning queries")
    @MainActor
    func deletedActivityExcludedFromNormalQueries() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let keep = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Kept", localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let removed = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Removed", localDate: LocalDate(year: 2026, month: 1, day: 7),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        try service.deletePlannedActivity(
            removed.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, deletedBy: ActorId()
        )

        let remaining = try service.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)

        #expect(remaining.count == 1)
        #expect(remaining.first?.id == keep.id)
    }

    @Test("Repeated deletion of the same PlannedActivity does not create a duplicate tombstone or corrupt state")
    @MainActor
    func repeatedDeletionDoesNotDuplicateOrCorrupt() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = PlanningRepository(modelContext: container.mainContext)
        let service = PlanningService(repository: repository)
        let athleteId = AthleteId()
        let weekPlan = try service.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try service.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        try service.deletePlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, deletedBy: ActorId()
        )

        // Second attempt on the same, now-gone activity — the existing
        // not-found guard (unchanged by A2) rejects it before any
        // tombstone logic runs, which is exactly what prevents a
        // duplicate tombstone here without any new logic being added.
        #expect(throws: PlanningServiceError.self) {
            try service.deletePlannedActivity(
                activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, deletedBy: ActorId()
            )
        }

        #expect(try container.mainContext.fetch(FetchDescriptor<PlannedActivityDeletionTombstone>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<PlannedActivity>()).count == 0)
    }

    @Test("Both the deletion and the tombstone survive the ModelContainer being discarded and recreated")
    @MainActor
    func deletionAndTombstoneSurviveContainerRecreation() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("a2-tombstone-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: AppSchemaV2.self)
        let athleteId = AthleteId()

        let firstConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let firstContainer = try ModelContainer(
            for: schema, migrationPlan: AppSchemaMigrationPlan.self, configurations: [firstConfiguration]
        )
        let firstRepository = PlanningRepository(modelContext: firstContainer.mainContext)
        let firstService = PlanningService(repository: firstRepository)
        let weekPlan = try firstService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 1, day: 5))
        let activity = try firstService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        try firstService.deletePlannedActivity(
            activity.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId, deletedBy: ActorId()
        )

        let secondConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let secondContainer = try ModelContainer(
            for: schema, migrationPlan: AppSchemaMigrationPlan.self, configurations: [secondConfiguration]
        )

        let tombstones = try secondContainer.mainContext.fetch(FetchDescriptor<PlannedActivityDeletionTombstone>())
        let activities = try secondContainer.mainContext.fetch(FetchDescriptor<PlannedActivity>())

        #expect(tombstones.count == 1)
        #expect(tombstones.first?.entityId == activity.id)
        #expect(activities.isEmpty)
    }
}
