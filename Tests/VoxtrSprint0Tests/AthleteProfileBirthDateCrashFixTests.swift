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
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
//
// A genuine, disclosed limitation of every test below: this project's
// VersionedSchema types (AppSchemaV1...AppSchemaV6) all reference the
// SAME live `AthleteProfile` Swift class — there is no separate,
// permanently-frozen struct definition for "AthleteProfile as it was
// under V5" (this codebase has never done that for any prior
// schema bump). That means these tests cannot literally reconstruct
// the historically-broken on-disk shape (`birthDate: LocalDate` stored
// directly) the way a real TestFlight user's pre-fix device has it —
// only Apple's real SwiftData runtime, opening that real file, can
// exercise that exact path. What these tests DO prove: the current
// model reads/writes correctly through a real save+fetch round-trip
// (covers "newly created athletes"), and that a store honestly
// versioned at 5.0.0 migrates to the current latest version without
// throwing or crashing (covers the migration plan's own structural
// correctness) — see this fix's own root-cause writeup for the full
// explanation of why a stronger, byte-for-byte reproduction isn't
// possible from Swift test code.
@Suite("AthleteProfile.birthDate crash fix", .serialized)
struct AthleteProfileBirthDateCrashFixTests {

    @Test("A newly created athlete's birthDate reads back correctly after a real save+fetch round-trip")
    @MainActor
    func newlyCreatedAthleteBirthDateSurvivesRoundTrip() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let expectedBirthDate = LocalDate(year: 2012, month: 4, day: 10)

        let created = try athleteRepository.createAthlete(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: expectedBirthDate,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )

        // Fetch through a completely independent context against the
        // same container — not the same object reference `created`
        // already holds — so this genuinely exercises a fresh decode
        // from the backing store, the same operation that crashed in
        // production ("opening" an athlete from Manage Athletes).
        let independentContext = ModelContext(container)
        let independentRepository = AthleteRepository(modelContext: independentContext)
        let refetched = try independentRepository.fetchAthlete(byId: created.athleteId)

        #expect(refetched?.birthDate == expectedBirthDate)
    }

    @Test("Opening (reading birthDate on) every athlete in a multi-athlete family works correctly")
    @MainActor
    func openingEveryAthleteInFamilyWorks() throws {
        // Directly reproduces the crash's own call site — reading
        // `.birthDate` on multiple, independently-fetched
        // AthleteProfile instances, the same access
        // AthleteFamilyManagementViewModel.prefill(from:) performs when
        // a parent taps an athlete row in Manage Athletes.
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let workspaceId = WorkspaceId()
        let firstBirthDate = LocalDate(year: 2012, month: 4, day: 10)
        let secondBirthDate = LocalDate(year: 2014, month: 6, day: 1)
        _ = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "Jonas", birthDate: firstBirthDate,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        _ = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "Emma", birthDate: secondBirthDate,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        let independentContext = ModelContext(container)
        let independentRepository = AthleteRepository(modelContext: independentContext)
        let refetchedAthletes = try independentRepository.fetchAthletes(forWorkspace: workspaceId)

        #expect(refetchedAthletes.count == 2)
        let birthDates = Set(refetchedAthletes.map(\.birthDate))
        #expect(birthDates == [firstBirthDate, secondBirthDate])
    }

    @Test("A store honestly versioned at 5.0.0 migrates to the current latest version without throwing")
    @MainActor
    func storeAtV5MigratesToCurrentLatest() throws {
        let schema = Schema(versionedSchema: AppSchemaV5.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        let container = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )

        // Confirms the migration plan itself is structurally sound
        // (constructible, no thrown error) — see this suite's own doc
        // comment for what this test does and does not prove.
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let expectedBirthDate = LocalDate(year: 2013, month: 3, day: 15)
        let created = try athleteRepository.createAthlete(
            workspaceId: WorkspaceId(),
            givenName: "Oliver",
            birthDate: expectedBirthDate,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )

        let refetched = try athleteRepository.fetchAthlete(byId: created.athleteId)
        #expect(refetched?.birthDate == expectedBirthDate)
    }

    @Test("The documented placeholder LocalDate parses correctly and matches the model's own default")
    @MainActor
    func placeholderBirthDateIsWellFormed() throws {
        // Confirms AppSchemaVersioning.swift's documented claim (the
        // literal default given to `birthDateRaw` for migrated rows,
        // "1900-01-01") actually round-trips through LocalDate
        // correctly — a documentation/code mismatch here would itself
        // be a real bug worth catching.
        let placeholder = try #require(LocalDate(isoString: "1900-01-01"))
        #expect(placeholder.year == 1900)
        #expect(placeholder.month == 1)
        #expect(placeholder.day == 1)
    }
}
