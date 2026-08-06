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
}
