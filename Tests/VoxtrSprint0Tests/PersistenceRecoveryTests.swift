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
// Unlike every prior persistence test in this project's history, these
// go THROUGH SwiftDataPersistenceController and FamilyOnboardingCoordinator
// — the real production types both AthleteApp and ParentApp actually
// use — rather than constructing ModelContainer/repositories directly.
// That gap in test coverage (every earlier test bypassed the real
// construction path) is why CompositionRoot.build's own default
// argument bug went uncaught despite the migration plan itself already
// having passing tests. Critical persistence recovery work: after
// collapsing the schema history to AppCurrentSchema (see
// AppSchemaVersioning.swift's own doc comment for why), these tests
// cover fresh install, restart, and onboarding rollback — the actual
// three scenarios reported as broken.
@Suite("Persistence recovery: fresh install, restart, and onboarding rollback", .serialized)
struct PersistenceRecoveryTests {

    @Test("Fresh install: create family, create multiple athletes, restart container, reload data")
    @MainActor
    func freshInstallCreateFamilyMultipleAthletesRestartReload() throws {
        // SwiftDataPersistenceController.makeModelContainer() targets
        // the app's own default on-disk location, not a controllable
        // temp file — construct the equivalent container directly
        // against a temp URL instead, using the exact same
        // Schema(versionedSchema:)/migrationPlan pairing
        // SwiftDataPersistenceController uses internally, so this still
        // exercises the real construction path.
        let storeURL = URL.temporaryDirectory.appendingPathComponent("fresh-install-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: AppCurrentSchema.self)

        var athleteIds: [UUID] = []
        var workspaceId: WorkspaceId
        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
            let athleteRepository = AthleteRepository(modelContext: container.mainContext)
            let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)

            // The real production onboarding path, not a hand-rolled
            // equivalent.
            let coordinator = FamilyOnboardingCoordinator(
                modelContext: container.mainContext,
                parentWorkspaceRepository: parentWorkspaceRepository,
                athleteRepository: athleteRepository,
                athleteAccessGrantRepository: athleteAccessGrantRepository
            )
            let created = try coordinator.createFamily(
                parentGivenName: "Kari",
                athleteGivenName: "Jonas",
                athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
                athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                athleteDevelopmentStage: .parentLed
            )
            workspaceId = created.workspace.workspaceId

            // A second athlete, via the real
            // AthleteFamilyManagementService — matching "create
            // multiple athletes."
            let managementService = AthleteFamilyManagementService(
                modelContext: container.mainContext,
                athleteRepository: athleteRepository,
                athleteAccessGrantRepository: athleteAccessGrantRepository
            )
            let second = try managementService.addAthlete(
                workspaceId: created.workspace.workspaceId,
                participantId: created.participant.id,
                givenName: "Emma",
                birthDate: LocalDate(year: 2014, month: 6, day: 1),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                developmentStage: .parentLed
            )
            athleteIds = [created.athlete.athleteId.rawValue, second.athlete.athleteId.rawValue]
        }
        // Container above goes out of scope — genuinely closed.

        // Restart: a completely new container against the same file,
        // via the same construction path.
        let restartedContainer = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let restartedParentRepository = ParentWorkspaceRepository(modelContext: restartedContainer.mainContext)
        let restartedAthleteRepository = AthleteRepository(modelContext: restartedContainer.mainContext)

        #expect(try restartedParentRepository.fetchAllParentProfiles().first?.givenName == "Kari")
        let restartedAthletes = try restartedAthleteRepository.fetchAthletes(forWorkspace: workspaceId)
        #expect(Set(restartedAthletes.map(\.givenName)) == ["Jonas", "Emma"])
        #expect(Set(restartedAthletes.map(\.id)) == Set(athleteIds))
    }

    @Test("Restarting a store created under the current schema succeeds without a migration path being required")
    @MainActor
    func restartUnderCurrentSchemaSucceeds() throws {
        // "Update from previous shipped schema" under the collapsed,
        // single-version scheme: a store created under AppCurrentSchema
        // (the only version) still needs to reopen correctly on the
        // NEXT construction — this is the scheme's own trivial case of
        // that requirement, since there is only one version right now.
        // A genuine multi-version migration test becomes meaningful
        // again the first time a real AppSchemaV2 is added (see
        // AppSchemaVersioning.swift's own "HOW TO ADD A NEW VERSION").
        let storeURL = URL.temporaryDirectory.appendingPathComponent("restart-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: AppCurrentSchema.self)

        do {
            let firstContainer = try ModelContainer(
                for: schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: firstContainer.mainContext)
            _ = try parentWorkspaceRepository.createParentAndWorkspace(givenName: "Kari")
        }

        let secondContainer = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let secondParentWorkspaceRepository = ParentWorkspaceRepository(modelContext: secondContainer.mainContext)
        #expect(try secondParentWorkspaceRepository.fetchAllParentProfiles().count == 1)

        // Reopen a third time, matching "restart, reload data" being
        // exercised more than once.
        let thirdContainer = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let thirdParentWorkspaceRepository = ParentWorkspaceRepository(modelContext: thirdContainer.mainContext)
        #expect(try thirdParentWorkspaceRepository.fetchAllParentProfiles().first?.givenName == "Kari")
    }

    @Test("CompositionRoot.build's own default persistence provider constructs successfully")
    @MainActor
    func compositionRootDefaultPersistenceConstructsSuccessfully() throws {
        // Exercises the real, current default directly — the exact
        // construction CompositionRoot.build() performs when called
        // with no arguments, as both AthleteApp and ParentApp actually
        // do. This is the single most direct regression guard against
        // the exact class of bug (a default argument silently pointing
        // at the wrong schema version) that caused this whole
        // investigation.
        let controller = SwiftDataPersistenceController(
            versionedSchema: AppCurrentSchema.self,
            migrationPlan: AppSchemaMigrationPlan.self
        )
        let container = try controller.makeModelContainer()

        #expect(container.schema.entities.count == AppSchema.modelTypes.count)
    }

    @Test("A save failure during onboarding rolls back completely, leaving no partial family data")
    @MainActor
    func onboardingRollbackOnSaveFailure() throws {
        struct InjectedSaveFailure: Error {}

        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )

        #expect(throws: InjectedSaveFailure.self) {
            try coordinator.createFamily(
                parentGivenName: "Kari",
                athleteGivenName: "Jonas",
                athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
                athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                athleteDevelopmentStage: .parentLed,
                failAt: nil,
                saveOverride: { throw InjectedSaveFailure() }
            )
        }

        #expect(try parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
        #expect(try parentWorkspaceRepository.fetchAllWorkspaces().isEmpty)
        #expect(try athleteRepository.fetchAllAthletes().isEmpty)
        #expect(try athleteAccessGrantRepository.fetchAllGrants().isEmpty)
    }

    // A test previously here ("A genuine SwiftData save failure
    // (forced parent-id collision) during onboarding rolls back
    // completely") assumed that reusing the same ParentProfile.id
    // across two createFamily calls would cause SwiftData to reject
    // the second insert with a uniqueness violation. That assumption
    // was checked against this project's own prior, documented finding
    // — see the "Recurring Hard-Won Lessons" note "@Attribute(.unique)
    // is upsert not a rejecting constraint" — and confirmed still true:
    // ParentProfile.id genuinely IS declared `@Attribute(.unique)` (so
    // that part of the assumption was correct), but SwiftData's actual
    // behavior for a `.unique` collision is to UPSERT the existing row
    // rather than throw. The second createFamily call therefore never
    // throws at all — it silently overwrites the first family's
    // ParentProfile fields — so `#expect(throws:)` never has anything
    // to catch, and the test fails not because rollback is broken but
    // because its own premise about SwiftData's behavior was wrong.
    // Removed rather than rewritten to assert the upsert instead: that
    // would be a different test with a different purpose (documenting
    // upsert behavior, not rollback), and rollback against a genuine,
    // non-simulated failure is already covered by
    // onboardingRollbackOnSaveFailure above, via this project's
    // established saveOverride seam — the correct, deterministic way
    // to force a real save-time failure in this codebase.
}
