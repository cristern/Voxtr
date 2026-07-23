import Testing
import SwiftData
import VoxtrCore

// NOTE: SwiftData requires an Apple platform runtime. This test cannot
// run in a Linux sandbox (there is no Swift toolchain with SwiftData
// available outside macOS/iOS/etc.) — it must be run from Xcode on
// macOS to be verified. It is included here because it's part of what
// Sprint 0 needs to prove, not because it was executed in this
// environment.

@Suite("Local persistence")
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
}
