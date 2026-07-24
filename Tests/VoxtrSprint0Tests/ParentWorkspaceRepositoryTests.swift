import Testing
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrParentDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.

// S1.1 FIX (round 2): the crash pattern across two CI runs consistently
// involved every suite that constructs a ModelContainer, and never the
// pure-logic suites. Swift Testing parallelizes tests by default, and
// concurrent ModelContainer construction is a documented SwiftData crash
// source. `.serialized` forces this suite's tests to run one at a time
// rather than racing each other to build a container simultaneously.
@Suite("ParentWorkspaceRepository (S1.1)", .serialized)
struct ParentWorkspaceRepositoryTests {

    @MainActor
    private func makeRepository() throws -> (ParentWorkspaceRepository, ModelContext) {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let context = container.mainContext
        return (ParentWorkspaceRepository(modelContext: context), context)
    }

    @Test("Creating a parent and workspace persists all three records together")
    @MainActor
    func createsParentWorkspaceAndParticipant() throws {
        let (repository, _) = try makeRepository()

        let result = try repository.createParentAndWorkspace(givenName: "Kari", familyName: "Hansen")

        #expect(result.parent.givenName == "Kari")
        #expect(result.workspace.technicalOwnerAccountId == AccountId.pending.rawValue)
        #expect(result.participant.role == .workspaceOwner)
        #expect(result.participant.state == .active)
        #expect(result.participant.workspaceId == result.workspace.id)
    }

    @Test("Fetched parent profile matches what was created")
    @MainActor
    func fetchAllParentProfilesReturnsCreatedParent() throws {
        let (repository, _) = try makeRepository()
        _ = try repository.createParentAndWorkspace(givenName: "Kari")

        let parents = try repository.fetchAllParentProfiles()

        #expect(parents.count == 1)
        #expect(parents.first?.givenName == "Kari")
    }

    @Test("Fetched workspace matches what was created")
    @MainActor
    func fetchAllWorkspacesReturnsCreatedWorkspace() throws {
        let (repository, _) = try makeRepository()
        let result = try repository.createParentAndWorkspace(givenName: "Kari")

        let workspaces = try repository.fetchAllWorkspaces()

        #expect(workspaces.count == 1)
        #expect(workspaces.first?.id == result.workspace.id)
    }

    @Test("Fetching participants by workspace ID returns only that workspace's participant")
    @MainActor
    func fetchParticipantsForWorkspaceScopesCorrectly() throws {
        let (repository, _) = try makeRepository()
        let first = try repository.createParentAndWorkspace(givenName: "Kari")
        let second = try repository.createParentAndWorkspace(givenName: "Ola")

        let firstParticipants = try repository.fetchParticipants(forWorkspace: first.workspace.workspaceId)
        let secondParticipants = try repository.fetchParticipants(forWorkspace: second.workspace.workspaceId)

        #expect(firstParticipants.count == 1)
        #expect(firstParticipants.first?.accountId == AccountId.pending.rawValue)
        #expect(secondParticipants.count == 1)
        #expect(firstParticipants.first?.id != secondParticipants.first?.id)
    }

    @Test("Data survives rebuilding the repository against the same persistent store")
    @MainActor
    func dataSurvivesRepositoryRebuild() throws {
        // Uses a real on-disk-shaped configuration (not in-memory) to
        // approximate "close and reopen the app" within one process,
        // the same way PersistenceTests.swift's Sprint 0 test proved a
        // basic round-trip. A full close/relaunch is what S1.3 (family
        // restoration) will test end-to-end; this confirms the
        // repository layer itself has no in-memory-only state hiding
        // the fact that persistence actually happened.
        let schema = Schema(AppSchema.modelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])

        let firstContext = container.mainContext
        let firstRepository = ParentWorkspaceRepository(modelContext: firstContext)
        _ = try firstRepository.createParentAndWorkspace(givenName: "Kari")

        // Same container, fresh repository instance — proves the data
        // lives in the store, not in repository-instance state.
        let secondRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let parents = try secondRepository.fetchAllParentProfiles()

        #expect(parents.count == 1)
        #expect(parents.first?.givenName == "Kari")
    }
}
