import Testing
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrParentDomain
import VoxtrAthleteDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("FamilyRestorationService (S1.3)", .serialized)
struct FamilyRestorationServiceTests {

    @Test("An empty store restores to noExistingFamily")
    @MainActor
    func emptyStoreRestoresToNoExistingFamily() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let service = FamilyRestorationService(
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )

        let state = try service.restoreState()

        guard case .noExistingFamily = state else {
            Issue.record("Expected .noExistingFamily, got \(state)")
            return
        }
    }

    @Test("A fully created family restores to existingFamily with matching data")
    @MainActor
    func completeFamilyRestoresToExistingFamily() throws {
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
        _ = try coordinator.createFamily(
            parentGivenName: "Kari",
            athleteGivenName: "Jonas",
            athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
            athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            athleteDevelopmentStage: .parentLed
        )

        let service = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let state = try service.restoreState()

        guard case .existingFamily(let restored) = state else {
            Issue.record("Expected .existingFamily, got \(state)")
            return
        }
        #expect(restored.parent.givenName == "Kari")
        #expect(restored.athlete.givenName == "Jonas")
        #expect(restored.participant.role == .workspaceOwner)
        #expect(restored.grant.canViewSchedule)
    }

    @Test("Restoration does not create any new records")
    @MainActor
    func restorationCreatesNoNewRecords() throws {
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
        _ = try coordinator.createFamily(
            parentGivenName: "Kari",
            athleteGivenName: "Jonas",
            athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
            athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            athleteDevelopmentStage: .parentLed
        )

        let service = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        // Call restoreState() twice — if it ever created records as a
        // side effect, the second call would see doubled counts.
        _ = try service.restoreState()
        _ = try service.restoreState()

        #expect(try container.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<FamilyWorkspace>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<WorkspaceParticipant>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteAccessGrant>()).count == 1)
    }

    @Test("Parent, workspace, and participant with no athlete or grant is inconsistentGraph, not silently treated as valid or empty")
    @MainActor
    func partialGraphMissingAthleteIsInconsistent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        // Use the standalone create method directly (not the atomic
        // coordinator) to deliberately produce a partial graph — this
        // simulates what an older write path, a bug, or manual store
        // tampering could leave behind, which is exactly what
        // requirement 6 asks restoration to handle without crashing.
        _ = try parentWorkspaceRepository.createParentAndWorkspace(givenName: "Kari")

        let service = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )
        let state = try service.restoreState()

        guard case .inconsistentGraph(let reason) = state else {
            Issue.record("Expected .inconsistentGraph, got \(state)")
            return
        }
        #expect(reason.contains("0 athlete"))
    }

    @Test("An athlete whose workspaceId doesn't match any workspace is inconsistentGraph")
    @MainActor
    func mismatchedWorkspaceReferenceIsInconsistent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)

        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        // Deliberately reference a DIFFERENT, nonexistent workspace ID —
        // simulating a corrupted or mismatched record.
        let athlete = athleteRepository.stageAthlete(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )
        _ = athleteAccessGrantRepository.stageFullAccessGrant(
            workspaceId: staged.workspace.workspaceId,
            participantId: staged.participant.id,
            athleteId: athlete.athleteId
        )
        try container.mainContext.save()

        let service = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let state = try service.restoreState()

        guard case .inconsistentGraph(let reason) = state else {
            Issue.record("Expected .inconsistentGraph, got \(state)")
            return
        }
        #expect(reason.contains("AthleteProfile.workspaceId"))
    }
}
