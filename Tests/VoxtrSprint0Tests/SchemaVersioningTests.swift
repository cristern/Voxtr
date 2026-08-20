import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrAthleteDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// These tests exercise AppCurrentSchema/AppSchemaMigrationPlan directly
// via Schema(versionedSchema:)/ModelContainer(migrationPlan:) — the
// same real SwiftData API SwiftDataPersistenceController's versioned
// initializer wraps — rather than going through
// SwiftDataPersistenceController itself, whose real makeModelContainer()
// targets the app's default on-disk location (not test-appropriate: no
// isolation between test runs).
//
// Critical persistence recovery: after collapsing the schema history to
// a single AppCurrentSchema (see AppSchemaVersioning.swift's own doc
// comment for why), all three tests here now reference that one schema
// — there is no longer an "old version" vs. "current version" split to
// exercise separately.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.

@Suite("Schema versioning", .serialized)
struct SchemaVersioningTests {

    @Test("A versioned model container can be created from AppCurrentSchema + AppSchemaMigrationPlan")
    @MainActor
    func versionedModelContainerCanBeCreated() throws {
        let schema = Schema(versionedSchema: AppCurrentSchema.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        let container = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )

        #expect(container.schema.entities.count == AppCurrentSchema.models.count)
    }

    @Test("Current entities can still be written and fetched through the versioned schema")
    @MainActor
    func currentEntitiesCanStillBeWrittenAndFetched() throws {
        let schema = Schema(versionedSchema: AppCurrentSchema.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )

        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )
        container.mainContext.insert(athlete)
        try container.mainContext.save()

        let fetched = try container.mainContext.fetch(FetchDescriptor<AthleteProfile>())

        #expect(fetched.count == 1)
        #expect(fetched.first?.givenName == "Jonas")
    }

    @Test("Persistence survives the ModelContainer itself being discarded and recreated against the same on-disk store, via the migration plan")
    @MainActor
    func persistenceSurvivesContainerRecreation() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("schema-versioning-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: AppCurrentSchema.self)

        let firstConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let firstContainer = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [firstConfiguration]
        )
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Kari",
            birthDate: LocalDate(year: 2011, month: 9, day: 2),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )
        firstContainer.mainContext.insert(athlete)
        try firstContainer.mainContext.save()

        // A genuinely new ModelContainer, built the same way a real app
        // relaunch would — same versioned schema, same migration plan,
        // same on-disk file.
        let secondConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let secondContainer = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [secondConfiguration]
        )

        let fetched = try secondContainer.mainContext.fetch(FetchDescriptor<AthleteProfile>())

        #expect(fetched.count == 1)
        #expect(fetched.first?.givenName == "Kari")
    }

    @Test("Persisted V3 store with physicalTraining activities migrates cleanly to V4 with legacy activityType preserved")
    @MainActor
    func v3StoreWithPhysicalTrainingMigratesToV4() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("v3-v4-physical-training-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let v3Schema = Schema(versionedSchema: AppSchemaV3.self)
        let v3Configuration = ModelConfiguration(schema: v3Schema, url: storeURL)
        let v3Container = try ModelContainer(
            for: v3Schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [v3Configuration]
        )

        let athleteId = AthleteId()
        let weekPlanId = WeekPlanId()
        let plannedId = PlannedActivityId()
        let loggedId = LoggedActivityId()
        let recurringId = RecurringPlannedActivityId()

        let originalDate = LocalDate(year: 2026, month: 3, day: 4)
        let originalTitle = "Wednesday Gym Session"

        // 1. PlannedActivity with physicalTraining
        let planned = PlannedActivity(
            plannedActivityId: plannedId,
            weekPlanId: weekPlanId,
            athleteId: athleteId,
            activityType: .physicalTraining,
            title: originalTitle,
            localDate: originalDate,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            plannedDurationMinutes: 60
        )
        v3Container.mainContext.insert(planned)

        // 2. LoggedActivity with physicalTraining
        let startedAt = Date()
        let logged = LoggedActivity(
            loggedActivityId: loggedId,
            athleteId: athleteId,
            plannedActivityId: plannedId,
            activityType: .physicalTraining,
            title: originalTitle,
            startedAt: startedAt,
            durationMinutes: 60,
            status: .completed,
            source: "manual"
        )
        v3Container.mainContext.insert(logged)

        // 3. RecurringPlannedActivity with physicalTraining
        let recurring = RecurringPlannedActivity(
            recurringPlannedActivityId: recurringId,
            athleteId: athleteId,
            title: originalTitle,
            activityType: .physicalTraining,
            weekdays: [.wednesday],
            plannedDurationMinutes: 60,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: originalDate,
            effectiveEndDate: originalDate.adding(days: 30)
        )
        v3Container.mainContext.insert(recurring)

        try v3Container.mainContext.save()

        // Discard v3Container and migrate to V4 using the same on-disk file
        let v4Schema = Schema(versionedSchema: AppSchemaV4.self)
        let v4Configuration = ModelConfiguration(schema: v4Schema, url: storeURL)
        let v4Container = try ModelContainer(
            for: v4Schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [v4Configuration]
        )

        // Verify PlannedActivity
        let fetchedPlanned = try v4Container.mainContext.fetch(FetchDescriptor<PlannedActivity>())
        #expect(fetchedPlanned.count == 1)
        let migratedPlanned = try #require(fetchedPlanned.first)
        #expect(migratedPlanned.plannedActivityId == plannedId)
        #expect(migratedPlanned.athleteId == athleteId.rawValue)
        #expect(migratedPlanned.title == originalTitle)
        #expect(migratedPlanned.sportId == nil)
        #expect(migratedPlanned.plannedDurationMinutes == 60)
        #expect(migratedPlanned.localDate == originalDate)
        #expect(migratedPlanned.activityType == .physicalTraining)

        // Verify LoggedActivity
        let fetchedLogged = try v4Container.mainContext.fetch(FetchDescriptor<LoggedActivity>())
        #expect(fetchedLogged.count == 1)
        let migratedLogged = try #require(fetchedLogged.first)
        #expect(migratedLogged.loggedActivityId == loggedId)
        #expect(migratedLogged.athleteId == athleteId.rawValue)
        #expect(migratedLogged.title == originalTitle)
        #expect(migratedLogged.sportId == nil)
        #expect(migratedLogged.durationMinutes == 60)
        #expect(migratedLogged.startedAt == startedAt)
        #expect(migratedLogged.source == "manual")
        #expect(migratedLogged.activityType == .physicalTraining)

        // Verify RecurringPlannedActivity
        let fetchedRecurring = try v4Container.mainContext.fetch(FetchDescriptor<RecurringPlannedActivity>())
        #expect(fetchedRecurring.count == 1)
        let migratedRecurring = try #require(fetchedRecurring.first)
        #expect(migratedRecurring.recurringPlannedActivityId == recurringId)
        #expect(migratedRecurring.athleteId == athleteId.rawValue)
        #expect(migratedRecurring.title == originalTitle)
        #expect(migratedRecurring.sportId == nil)
        #expect(migratedRecurring.plannedDurationMinutes == 60)
        #expect(migratedRecurring.weekdays == [.wednesday])
        #expect(migratedRecurring.activityType == .physicalTraining)
    }
}
