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
// These tests exercise AppSchemaV1/AppSchemaMigrationPlan directly via
// Schema(versionedSchema:)/ModelContainer(migrationPlan:) — the same
// real SwiftData API SwiftDataPersistenceController's new versioned
// initializer wraps — rather than going through
// SwiftDataPersistenceController itself, whose real makeModelContainer()
// targets the app's default on-disk location (not test-appropriate: no
// isolation between test runs). This matches the project's existing
// convention (InMemoryPersistenceController/inline ModelContainer
// construction in every other test file); nothing else in this project
// tests a *Controller type directly either.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.

@Suite("Schema versioning (A1)", .serialized)
struct SchemaVersioningTests {

    @Test("A versioned model container can be created from AppSchemaV1 + AppSchemaMigrationPlan")
    @MainActor
    func versionedModelContainerCanBeCreated() throws {
        let schema = Schema(versionedSchema: AppSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        let container = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )

        // Every currently-registered entity is present — none dropped,
        // none added, by construction (AppSchemaV1.models IS
        // AppSchema.modelTypes).
        #expect(container.schema.entities.count == AppSchema.modelTypes.count)
    }

    @Test("Current entities can still be written and fetched through the versioned schema")
    @MainActor
    func currentEntitiesCanStillBeWrittenAndFetched() throws {
        let schema = Schema(versionedSchema: AppSchemaV1.self)
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
        let storeURL = URL.temporaryDirectory.appendingPathComponent("a1-schema-versioning-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: AppSchemaV1.self)

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
