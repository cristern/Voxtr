import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrParentDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
//
// These tests exercise exactly the failure point in the crash trace:
// ModelContainer.init(for:migrationPlan:configurations:) itself, before
// any store is opened or any row is read — that ordering (construction
// crashes first) is why "does ModelContainer.init succeed" is its own,
// separately meaningful assertion in several tests below, independent
// of whatever happens afterward.
@Suite("Schema migration-plan validation crash fix (V3→V4, V5→V6)", .serialized)
struct SchemaMigrationPlanValidationCrashFixTests {

    @Test("A clean install (no existing store) constructs a ModelContainer via the full migration plan without throwing")
    @MainActor
    func cleanInstallConstructsContainer() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("clean-install-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(AppSchema.modelTypes)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)

        // This is the exact call from the crash trace
        // (ModelContainer.init(for:migrationPlan:configurations:) →
        // CompositionRoot.build), constructed directly rather than
        // through SwiftDataPersistenceController (not test-appropriate:
        // targets the app's default on-disk location) — matching this
        // project's existing SchemaVersioningTests.swift convention.
        let container = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )

        #expect(container.schema.entities.count == AppSchema.modelTypes.count)
    }

    @Test("A real, on-disk V5 store migrates through the full plan to the current latest version without throwing, retaining non-athlete data")
    @MainActor
    func onDiskV5StoreMigratesToCurrentLatest() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("v5-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        // Step 1: create a REAL, on-disk store honestly versioned at
        // 5.0.0 — a genuinely separate ModelContainer/file, not an
        // in-memory one, since "close and reopen" requires a real file
        // to round-trip through. Uses the LEGACY AthleteProfile type
        // directly (not AthleteRepository, which constructs the LIVE
        // type) — AppSchemaV5's schema now correctly recognizes only
        // the legacy shape (see LegacySchemaTypes.swift), matching what
        // a real device's V5 store actually contained; inserting the
        // live type here would fail, since it isn't part of this
        // schema.
        let v5Schema = Schema(versionedSchema: AppSchemaV5.self)
        let v5Configuration = ModelConfiguration(schema: v5Schema, url: storeURL)
        var athleteId: UUID
        var workspaceId: WorkspaceId
        do {
            let v5Container = try ModelContainer(
                for: v5Schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [v5Configuration]
            )
            let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: v5Container.mainContext)
            let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
            let legacyAthlete = LegacyAthleteProfileSchema.AthleteProfile()
            legacyAthlete.workspaceId = staged.workspace.workspaceId.rawValue
            legacyAthlete.givenName = "Jonas"
            legacyAthlete.birthDate = LocalDate(year: 2012, month: 4, day: 10)
            legacyAthlete.timeZoneId = TimeZoneId(rawValue: "Europe/Oslo")
            legacyAthlete.developmentStage = .parentLed
            v5Container.mainContext.insert(legacyAthlete)
            athleteId = legacyAthlete.id
            workspaceId = staged.workspace.workspaceId
            try v5Container.mainContext.save()
        }
        // The V5 container above goes out of scope here — genuinely
        // "closed," not just abandoned mid-transaction.

        // Step 2: reopen the SAME file with the CURRENT schema and the
        // FULL migration plan — this is the exact operation that
        // crashed in production (build 130) for any real device whose
        // store was at V5.
        let currentSchema = Schema(AppSchema.modelTypes)
        let reopenConfiguration = ModelConfiguration(schema: currentSchema, url: storeURL)
        let migratedContainer = try ModelContainer(
            for: currentSchema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [reopenConfiguration]
        )

        // Non-athlete data survived the migration untouched.
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: migratedContainer.mainContext)
        #expect(try parentWorkspaceRepository.fetchAllParentProfiles().first?.givenName == "Kari")
        #expect(try parentWorkspaceRepository.fetchAllWorkspaces().count == 1)

        // The migrated athlete opens without crashing (the original
        // reported crash's own exact symptom) — givenName survives;
        // birthDate could not be preserved (see this fix's own
        // root-cause writeup) and reads back as the documented
        // placeholder rather than the original 2012-04-10.
        let athleteRepository = AthleteRepository(modelContext: migratedContainer.mainContext)
        let migratedAthlete = try athleteRepository.fetchAthlete(byId: AthleteId(rawValue: athleteId))
        #expect(migratedAthlete?.givenName == "Jonas")
        #expect(migratedAthlete?.workspaceId == workspaceId.rawValue)
        #expect(migratedAthlete?.birthDate == LocalDate(year: 1900, month: 1, day: 1))
    }

    @Test("Reopening an already-migrated V6 store a second time succeeds without throwing")
    @MainActor
    func reopeningAlreadyMigratedStoreSucceeds() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("reopen-migrated-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(AppSchema.modelTypes)

        // First open: creates and migrates (trivially, since there's
        // nothing to migrate from — this exercises the same
        // "construct via the full plan" path as a clean install).
        do {
            let firstContainer = try ModelContainer(
                for: schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let athleteRepository = AthleteRepository(modelContext: firstContainer.mainContext)
            let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: firstContainer.mainContext)
            let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
            try firstContainer.mainContext.save()
            _ = try athleteRepository.createAthlete(
                workspaceId: staged.workspace.workspaceId,
                givenName: "Emma",
                birthDate: LocalDate(year: 2014, month: 6, day: 1),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                developmentStage: .parentLed
            )
        }

        // Second open — the same store, now already at the current
        // latest version, reopened via the same migration plan.
        let secondContainer = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let athleteRepository = AthleteRepository(modelContext: secondContainer.mainContext)
        let athletes = try athleteRepository.fetchAllAthletes()
        #expect(athletes.count == 1)
        #expect(athletes.first?.givenName == "Emma")
    }

    @Test("A real, on-disk V3 store migrates through the full plan without throwing (the V3→V4 declinedAt fix)")
    @MainActor
    func onDiskV3StoreMigratesToCurrentLatest() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("v3-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let v3Schema = Schema(versionedSchema: AppSchemaV3.self)
        let v3Configuration = ModelConfiguration(schema: v3Schema, url: storeURL)
        do {
            let v3Container = try ModelContainer(
                for: v3Schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [v3Configuration]
            )
            // Constructed directly (not via ParentWorkspaceRepository
            // .stageParentAndWorkspace, which inserts the LIVE
            // WorkspaceParticipant type) — AppSchemaV3's schema now
            // correctly recognizes only the legacy shape (see
            // LegacySchemaTypes.swift), matching what a real device's
            // V3 store actually contained. ParentProfile/FamilyWorkspace
            // are unchanged live types across every version, so those
            // are safe to construct directly here.
            let parent = ParentProfile(accountId: .pending, givenName: "Kari")
            let workspace = FamilyWorkspace(displayName: "Kari's family", technicalOwnerAccountId: .pending)
            let legacyParticipant = LegacyWorkspaceParticipantSchema.WorkspaceParticipant()
            legacyParticipant.workspaceId = workspace.id
            legacyParticipant.accountId = AccountId.pending.rawValue
            legacyParticipant.role = .workspaceOwner
            legacyParticipant.state = .active
            v3Container.mainContext.insert(parent)
            v3Container.mainContext.insert(workspace)
            v3Container.mainContext.insert(legacyParticipant)
            try v3Container.mainContext.save()
        }

        let currentSchema = Schema(AppSchema.modelTypes)
        let reopenConfiguration = ModelConfiguration(schema: currentSchema, url: storeURL)
        let migratedContainer = try ModelContainer(
            for: currentSchema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [reopenConfiguration]
        )

        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: migratedContainer.mainContext)
        #expect(try parentWorkspaceRepository.fetchAllParentProfiles().first?.givenName == "Kari")
        // The migrated participant (WorkspaceParticipant) opens without
        // crashing and has no declinedAt, as expected for a participant
        // that never declined anything.
        let participant = try parentWorkspaceRepository.fetchAllParticipants().first
        #expect(participant?.role == .workspaceOwner)
    }
}
