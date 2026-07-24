import Testing
import SwiftData
import VoxtrCore
import VoxtrAppShell
import VoxtrCoreContracts
import VoxtrAthleteDomain

// NOTE: like the domain model tests, these exercise @Model types and
// therefore require the Xcode/macOS SwiftData runtime to actually run —
// written but not executed in this sandbox.

// S1.1 FIX (round 2): same reasoning as ParentWorkspaceRepositoryTests —
// see the comment there. This suite also constructs a ModelContainer
// per test and was involved in the same crash pattern.
@Suite("Local persistence", .serialized)
struct PersistenceTests {

    @Test("Writing and fetching an AppDiagnosticsRecord round-trips locally")
    @MainActor
    func persistenceRoundTrip() throws {
        let controller = InMemoryPersistenceController()
        let container = try controller.makeModelContainer()
        let context = container.mainContext

        let record = AppDiagnosticsRecord(schemaVersion: "sprint0-test")
        context.insert(record)
        try context.save()

        let descriptor = FetchDescriptor<AppDiagnosticsRecord>()
        let fetched = try context.fetch(descriptor)

        #expect(fetched.count == 1)
        #expect(fetched.first?.schemaVersion == "sprint0-test")
    }

    @Test("S1.0: the composed Sprint 1 schema (AppSchema) round-trips a real domain entity, not just AppDiagnosticsRecord")
    @MainActor
    func sprint1SchemaRoundTrip() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let context = container.mainContext

        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .sharedOwnership
        )
        context.insert(athlete)
        try context.save()

        let descriptor = FetchDescriptor<AthleteProfile>()
        let fetched = try context.fetch(descriptor)

        #expect(fetched.count == 1)
        #expect(fetched.first?.givenName == "Jonas")
        #expect(fetched.first?.revision == 1)
    }
}
