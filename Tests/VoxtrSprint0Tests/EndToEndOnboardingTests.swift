import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrParentDomain
import VoxtrAthleteDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// S1.5: unlike the in-memory tests elsewhere, these use a REAL on-disk
// SQLite store (a temp file, cleaned up after each test) and build a
// SECOND, independent `ModelContainer` pointed at the same file — this
// is what actually proves data survives the container itself being
// discarded and recreated, the way it would across an app relaunch, not
// just proves a fresh repository instance can read from a container
// that never went away.

@Suite("End-to-end onboarding lifecycle (S1.5)", .serialized)
struct EndToEndOnboardingTests {

    @Test("Empty store → create family → persist all five entities → recreate container → restore the same family")
    @MainActor
    func fullOnboardingLifecycleSurvivesContainerRecreation() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(AppSchema.modelTypes)

        // 1. Empty store.
        let firstConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let firstContainer = try ModelContainer(for: schema, configurations: [firstConfiguration])
        let firstRestorationService = FamilyRestorationService(
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: firstContainer.mainContext),
            athleteRepository: AthleteRepository(modelContext: firstContainer.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: firstContainer.mainContext)
        )
        guard case .noExistingFamily = try firstRestorationService.restoreState() else {
            Issue.record("Expected .noExistingFamily on an empty store")
            return
        }

        // 2. Create family.
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: firstContainer.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: firstContainer.mainContext),
            athleteRepository: AthleteRepository(modelContext: firstContainer.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: firstContainer.mainContext)
        )
        _ = try coordinator.createFamily(
            parentGivenName: "Kari",
            athleteGivenName: "Jonas",
            athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
            athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            athleteDevelopmentStage: .parentLed
        )

        // 3. Persist all five entities (checked against the same, still-open container).
        #expect(try firstContainer.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 1)
        #expect(try firstContainer.mainContext.fetch(FetchDescriptor<FamilyWorkspace>()).count == 1)
        #expect(try firstContainer.mainContext.fetch(FetchDescriptor<WorkspaceParticipant>()).count == 1)
        #expect(try firstContainer.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 1)
        #expect(try firstContainer.mainContext.fetch(FetchDescriptor<AthleteAccessGrant>()).count == 1)

        // 4. Recreate persistence/container — a genuinely new
        // ModelContainer instance pointed at the same on-disk file, the
        // way app relaunch would build one.
        let secondConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let secondContainer = try ModelContainer(for: schema, configurations: [secondConfiguration])
        let secondRestorationService = FamilyRestorationService(
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: secondContainer.mainContext),
            athleteRepository: AthleteRepository(modelContext: secondContainer.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: secondContainer.mainContext)
        )

        // 5. Restore the same family.
        guard case .existingFamily(let restored) = try secondRestorationService.restoreState() else {
            Issue.record("Expected .existingFamily after recreating the container")
            return
        }
        #expect(restored.parent.givenName == "Kari")
        #expect(restored.athlete.givenName == "Jonas")
        #expect(restored.participant.role == .workspaceOwner)
        #expect(restored.grant.canViewSchedule)
    }

    @Test("An inconsistent graph persisted before a container recreation restores as inconsistentGraph, not a crash or silent fix")
    @MainActor
    func inconsistentGraphSurvivesContainerRecreationAsInconsistent() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("e2e-inconsistent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(AppSchema.modelTypes)

        // Deliberately use the standalone (non-atomic) repository method
        // to persist only parent+workspace+participant — no athlete, no
        // grant — simulating what an older write path or manual
        // tampering could leave on disk.
        let firstConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let firstContainer = try ModelContainer(for: schema, configurations: [firstConfiguration])
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: firstContainer.mainContext)
        _ = try parentWorkspaceRepository.createParentAndWorkspace(givenName: "Kari")

        // Recreate the container, exactly as the lifecycle test above does.
        let secondConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let secondContainer = try ModelContainer(for: schema, configurations: [secondConfiguration])
        let restorationService = FamilyRestorationService(
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: secondContainer.mainContext),
            athleteRepository: AthleteRepository(modelContext: secondContainer.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: secondContainer.mainContext)
        )

        guard case .inconsistentGraph(let reason) = try restorationService.restoreState() else {
            Issue.record("Expected .inconsistentGraph after recreating the container against a partial graph")
            return
        }
        #expect(reason.contains("0 athlete"))

        // Nothing was silently deleted or "fixed" — the partial data is
        // still exactly what was written.
        #expect(try secondContainer.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 1)
        #expect(try secondContainer.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 0)
    }
}
