import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// These tests exercise the current AppSchemaV4/AppSchemaMigrationPlan directly
// via Schema(versionedSchema:)/ModelContainer(migrationPlan:) — the
// same real SwiftData API SwiftDataPersistenceController's versioned
// initializer wraps — rather than going through
// SwiftDataPersistenceController itself, whose real makeModelContainer()
// targets the app's default on-disk location (not test-appropriate: no
// isolation between test runs).
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.

@Suite("Schema versioning", .serialized)
struct SchemaVersioningTests {

    @Test("AppSchemaV4 registers the live activity domain model types")
    func currentSchemaRegistersLiveActivityDomainTypes() {
        let registeredTypes = Set(AppSchemaV4.models.map { ObjectIdentifier($0) })

        #expect(registeredTypes.contains(ObjectIdentifier(PlannedActivity.self)))
        #expect(registeredTypes.contains(ObjectIdentifier(LoggedActivity.self)))
        #expect(registeredTypes.contains(ObjectIdentifier(RecurringPlannedActivity.self)))
        #expect(!registeredTypes.contains(ObjectIdentifier(AppSchemaV3.PlannedActivity.self)))
        #expect(!registeredTypes.contains(ObjectIdentifier(AppSchemaV3.LoggedActivity.self)))
        #expect(!registeredTypes.contains(ObjectIdentifier(AppSchemaV3.RecurringPlannedActivity.self)))
    }

    @Test("A versioned model container can be created from AppSchemaV4 + AppSchemaMigrationPlan")
    @MainActor
    func versionedModelContainerCanBeCreated() throws {
        let schema = Schema(versionedSchema: AppSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        let container = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )

        #expect(container.schema.entities.count == AppSchemaV4.models.count)
    }

    @Test("Current entities can still be written and fetched through the versioned schema")
    @MainActor
    func currentEntitiesCanStillBeWrittenAndFetched() throws {
        let schema = Schema(versionedSchema: AppSchemaV4.self)
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

    @Test("A current V4 PlannedActivity survives ModelContainer recreation and fetches as the live domain type")
    @MainActor
    func persistenceSurvivesContainerRecreation() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("schema-versioning-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: AppSchemaV4.self)
        let athleteId = AthleteId()
        let activityId = PlannedActivityId()

        do {
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
            let activity = PlannedActivity(
                id: activityId,
                weekPlanId: WeekPlanId(),
                athleteId: athleteId,
                activityType: .individualTraining,
                title: "Endurance run",
                localDate: LocalDate(year: 2026, month: 1, day: 6),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
            firstContainer.mainContext.insert(activity)
            try firstContainer.mainContext.save()
        }

        // The first container is out of scope. A genuinely new
        // ModelContainer is built the same way a real app
        // relaunch would — same versioned schema, same migration plan,
        // same on-disk file.
        let secondConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let secondContainer = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [secondConfiguration]
        )

        let fetched = try secondContainer.mainContext.fetch(FetchDescriptor<AthleteProfile>())
        let fetchedActivities = try secondContainer.mainContext.fetch(FetchDescriptor<PlannedActivity>())

        #expect(fetched.count == 1)
        #expect(fetched.first?.givenName == "Kari")
        #expect(fetchedActivities.count == 1)
        #expect(fetchedActivities.first?.plannedActivityId == activityId)
        #expect(fetchedActivities.first?.title == "Endurance run")
        #expect(fetchedActivities.first?.sportId == nil)
    }

    @Test("Persisted V1 store with physicalTraining activities migrates cleanly through stages to V4 with legacy activityType preserved")
    @MainActor
    func v1StoreWithPhysicalTrainingMigratesToV4() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("v1-v4-physical-training-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let v1Schema = Schema(versionedSchema: AppCurrentSchema.self)
        let v1Configuration = ModelConfiguration(schema: v1Schema, url: storeURL)
        let v1Container = try ModelContainer(
            for: v1Schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [v1Configuration]
        )

        let athleteId = AthleteId()
        let weekPlanId = WeekPlanId()
        let plannedId = PlannedActivityId()
        let loggedId = LoggedActivityId()
        let recurringId = RecurringPlannedActivityId()

        let originalDate = LocalDate(year: 2026, month: 3, day: 4)
        let originalTitle = "V1 Wednesday Gym Session"

        let planned = AppCurrentSchema.PlannedActivity(
            id: plannedId.rawValue,
            weekPlanId: weekPlanId.rawValue,
            athleteId: athleteId.rawValue,
            activityType: .physicalTraining,
            title: originalTitle,
            localDate: originalDate,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            plannedDurationMinutes: 60
        )
        v1Container.mainContext.insert(planned)

        let startedAt = Date()
        let logged = AppCurrentSchema.LoggedActivity(
            id: loggedId.rawValue,
            athleteId: athleteId.rawValue,
            plannedActivityId: plannedId.rawValue,
            activityType: .physicalTraining,
            title: originalTitle,
            startedAt: startedAt,
            durationMinutes: 60,
            status: .completed,
            source: "manual"
        )
        v1Container.mainContext.insert(logged)

        let recurring = AppCurrentSchema.RecurringPlannedActivity(
            id: recurringId.rawValue,
            athleteId: athleteId.rawValue,
            title: originalTitle,
            activityType: .physicalTraining,
            weekdays: [.wednesday],
            plannedDurationMinutes: 60,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: originalDate,
            effectiveEndDate: originalDate.adding(days: 30)
        )
        v1Container.mainContext.insert(recurring)

        try v1Container.mainContext.save()

        // Discard v1Container and migrate to V4 using the same on-disk file
        let v4Schema = Schema(versionedSchema: AppSchemaV4.self)
        let v4Configuration = ModelConfiguration(schema: v4Schema, url: storeURL)
        let v4Container = try ModelContainer(
            for: v4Schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [v4Configuration]
        )

        let fetchedPlanned = try v4Container.mainContext.fetch(FetchDescriptor<PlannedActivity>())
        #expect(fetchedPlanned.count == 1)
        let migratedPlanned = try #require(fetchedPlanned.first)
        #expect(migratedPlanned.plannedActivityId == plannedId)
        #expect(migratedPlanned.athleteId == athleteId.rawValue)
        #expect(migratedPlanned.title == originalTitle)
        #expect(migratedPlanned.activityType == .physicalTraining)

        let fetchedLogged = try v4Container.mainContext.fetch(FetchDescriptor<LoggedActivity>())
        #expect(fetchedLogged.count == 1)
        let migratedLogged = try #require(fetchedLogged.first)
        #expect(migratedLogged.loggedActivityId == loggedId)
        #expect(migratedLogged.activityType == .physicalTraining)

        let fetchedRecurring = try v4Container.mainContext.fetch(FetchDescriptor<RecurringPlannedActivity>())
        #expect(fetchedRecurring.count == 1)
        let migratedRecurring = try #require(fetchedRecurring.first)
        #expect(migratedRecurring.recurringPlannedActivityId == recurringId)
        #expect(migratedRecurring.effectiveStartDate == originalDate)
        #expect(migratedRecurring.effectiveEndDate == originalDate.adding(days: 30))
        #expect(migratedRecurring.activityType == .physicalTraining)
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

        // 1. AppSchemaV3.PlannedActivity with physicalTraining (frozen V3 shape: title is non-optional String)
        let planned = AppSchemaV3.PlannedActivity(
            id: plannedId.rawValue,
            weekPlanId: weekPlanId.rawValue,
            athleteId: athleteId.rawValue,
            activityType: .physicalTraining,
            title: originalTitle,
            localDate: originalDate,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            plannedDurationMinutes: 60
        )
        v3Container.mainContext.insert(planned)

        // 2. AppSchemaV3.LoggedActivity with physicalTraining (frozen V3 shape: title is non-optional String)
        let startedAt = Date()
        let logged = AppSchemaV3.LoggedActivity(
            id: loggedId.rawValue,
            athleteId: athleteId.rawValue,
            plannedActivityId: plannedId.rawValue,
            activityType: .physicalTraining,
            title: originalTitle,
            startedAt: startedAt,
            durationMinutes: 60,
            status: .completed,
            source: "manual"
        )
        v3Container.mainContext.insert(logged)

        // 3. AppSchemaV3.RecurringPlannedActivity with physicalTraining (frozen V3 shape: title is non-optional String)
        let recurring = AppSchemaV3.RecurringPlannedActivity(
            id: recurringId.rawValue,
            athleteId: athleteId.rawValue,
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
        #expect(migratedRecurring.effectiveStartDate == originalDate)
        #expect(migratedRecurring.effectiveEndDate == originalDate.adding(days: 30))
        #expect(migratedRecurring.activityType == .physicalTraining)
    }
}
