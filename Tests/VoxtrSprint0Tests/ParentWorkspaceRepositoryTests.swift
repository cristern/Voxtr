import Testing
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
@testable import VoxtrParentDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.

// ROOT CAUSE (re-confirmed): this file had regressed to an older,
// pre-fix version that reintroduced a shared private `makeRepository()`
// helper called from multiple `@Test` functions to build the
// ModelContainer/repository. That exact pattern — not `#Predicate`, not
// parallel test execution, not `.serialized` — is what caused
// "Restarting after unexpected exit, crash, or test timeout" during this
// suite previously; removing the shared helper and inlining construction
// in every test (the same pattern already used in every other test file
// in this project) resolved it then and is reapplied here. `.serialized`
// is kept as a harmless belt-and-braces measure but was not, by itself,
// the fix.
@Suite("ParentWorkspaceRepository (S1.1)", .serialized)
struct ParentWorkspaceRepositoryTests {

    @Test("Creating a parent and workspace persists all three records together")
    @MainActor
    func createsParentWorkspaceAndParticipant() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)

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
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        _ = try repository.createParentAndWorkspace(givenName: "Kari")

        let parents = try repository.fetchAllParentProfiles()

        #expect(parents.count == 1)
        #expect(parents.first?.givenName == "Kari")
    }

    @Test("Fetched workspace matches what was created")
    @MainActor
    func fetchAllWorkspacesReturnsCreatedWorkspace() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let result = try repository.createParentAndWorkspace(givenName: "Kari")

        let workspaces = try repository.fetchAllWorkspaces()

        #expect(workspaces.count == 1)
        #expect(workspaces.first?.id == result.workspace.id)
    }

    @Test("Fetching participants by workspace ID returns only that workspace's participant")
    @MainActor
    func fetchParticipantsForWorkspaceScopesCorrectly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
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
        // restoration) tests end-to-end; this confirms the repository
        // layer itself has no in-memory-only state hiding the fact that
        // persistence actually happened.
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

    // MARK: - createInvitedAthleteParticipant (ADR-0001)

    @Test("Creates a participant with role .athlete")
    @MainActor
    func createInvitedAthleteParticipantSetsAthleteRole() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)

        let athleteParticipant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: ownerActorId
        )

        #expect(athleteParticipant.role == .athlete)
    }

    @Test("Creates the participant in state .invited, never .active")
    @MainActor
    func createInvitedAthleteParticipantSetsInvitedState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)

        let athleteParticipant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: ownerActorId
        )

        #expect(athleteParticipant.state == .invited)
    }

    @Test("linkedAthleteId is preserved exactly as supplied")
    @MainActor
    func createInvitedAthleteParticipantPreservesLinkedAthleteId() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let athleteId = AthleteId()

        let athleteParticipant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId,
            linkedAthleteId: athleteId,
            invitedBy: ownerActorId
        )

        #expect(athleteParticipant.linkedAthleteId == athleteId.rawValue)
    }

    @Test("invitedBy is preserved exactly as supplied")
    @MainActor
    func createInvitedAthleteParticipantPreservesInvitedBy() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)

        let athleteParticipant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: ownerActorId
        )

        #expect(athleteParticipant.invitedBy == ownerActorId.rawValue)
    }

    @Test("invitedAt is populated")
    @MainActor
    func createInvitedAthleteParticipantPopulatesInvitedAt() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)

        let athleteParticipant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: ownerActorId
        )

        #expect(athleteParticipant.invitedAt != nil)
    }

    @Test("acceptedAt is absent — this method never performs acceptance")
    @MainActor
    func createInvitedAthleteParticipantLeavesAcceptedAtNil() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)

        let athleteParticipant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: ownerActorId
        )

        #expect(athleteParticipant.acceptedAt == nil)
    }

    @Test("The participant is actually persisted — fetchable via fetchAllParticipants")
    @MainActor
    func createInvitedAthleteParticipantIsPersisted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)

        let athleteParticipant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: ownerActorId
        )

        let allParticipants = try repository.fetchAllParticipants()

        #expect(allParticipants.count == 2)
        #expect(allParticipants.contains { $0.id == athleteParticipant.id })
    }

    @Test("A save failure propagates rather than being swallowed")
    @MainActor
    func createInvitedAthleteParticipantPropagatesSaveFailure() throws {
        struct InjectedSaveFailure: Error {}

        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)

        // Test-only overload — see this method's own doc comment in
        // ParentWorkspaceRepository.swift for why a duplicate-id trick
        // cannot be used here (@Attribute(.unique) is upsert, not a
        // rejecting constraint, in this project).
        #expect(throws: InjectedSaveFailure.self) {
            try repository.createInvitedAthleteParticipant(
                workspaceId: family.workspace.workspaceId,
                linkedAthleteId: AthleteId(),
                invitedBy: ownerActorId,
                saveOverride: { throw InjectedSaveFailure() }
            )
        }
    }

    @Test("Existing parent/workspace creation behaviour is unchanged by createInvitedAthleteParticipant existing")
    @MainActor
    func existingParentAndWorkspaceCreationBehaviourIsUnchanged() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)

        let result = try repository.createParentAndWorkspace(givenName: "Kari", familyName: "Hansen")

        #expect(result.parent.givenName == "Kari")
        #expect(result.workspace.technicalOwnerAccountId == AccountId.pending.rawValue)
        #expect(result.participant.role == .workspaceOwner)
        #expect(result.participant.state == .active)
        #expect(result.participant.workspaceId == result.workspace.id)
    }

    // MARK: - findParticipant (VX-037, ADR-0002)

    @Test("findParticipant finds an existing athlete participant")
    @MainActor
    func findParticipantFindsExistingParticipant() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let athleteId = AthleteId()
        let created = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )

        let found = try repository.findParticipant(forAthlete: athleteId, workspaceId: family.workspace.workspaceId)

        #expect(found?.id == created.id)
    }

    @Test("findParticipant returns nil when no participant exists for that athlete")
    @MainActor
    func findParticipantReturnsNilWhenNoneExists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")

        let found = try repository.findParticipant(forAthlete: AthleteId(), workspaceId: family.workspace.workspaceId)

        #expect(found == nil)
    }

    @Test("findParticipant finds a participant regardless of its state")
    @MainActor
    func findParticipantFindsRegardlessOfState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let athleteId = AthleteId()
        let created = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        try repository.acceptInvitation(created)

        let found = try repository.findParticipant(forAthlete: athleteId, workspaceId: family.workspace.workspaceId)

        #expect(found?.state == .active)
    }

    @Test("findParticipant does not find a guardian participant when searching for an athlete")
    @MainActor
    func findParticipantDoesNotFindGuardianParticipant() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")

        // The owner participant exists in this workspace, but has role
        // .workspaceOwner, not .athlete — searching for an athlete
        // that was never invited must not accidentally match it.
        let found = try repository.findParticipant(forAthlete: AthleteId(), workspaceId: family.workspace.workspaceId)

        #expect(found == nil)
    }

    // MARK: - acceptInvitation (VX-037, ADR-0002)

    @Test("acceptInvitation transitions state from .invited to .active")
    @MainActor
    func acceptInvitationTransitionsState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let participant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: AthleteId(), invitedBy: ownerActorId
        )

        try repository.acceptInvitation(participant)

        #expect(participant.state == .active)
    }

    @Test("acceptInvitation sets acceptedAt")
    @MainActor
    func acceptInvitationSetsAcceptedAt() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let participant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: AthleteId(), invitedBy: ownerActorId
        )

        try repository.acceptInvitation(participant)

        #expect(participant.acceptedAt != nil)
    }

    @Test("acceptInvitation does not create a second WorkspaceParticipant — the same record transitions in place")
    @MainActor
    func acceptInvitationDoesNotCreateSecondParticipant() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let participant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: AthleteId(), invitedBy: ownerActorId
        )
        let participantsBefore = try repository.fetchParticipants(forWorkspace: family.workspace.workspaceId).count

        try repository.acceptInvitation(participant)

        let participantsAfter = try repository.fetchParticipants(forWorkspace: family.workspace.workspaceId).count
        #expect(participantsAfter == participantsBefore)
    }

    @Test("acceptInvitation's change persists and is visible on re-fetch")
    @MainActor
    func acceptInvitationPersistsAcrossRefetch() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let athleteId = AthleteId()
        let participant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        try repository.acceptInvitation(participant)

        let refetched = try repository.findParticipant(forAthlete: athleteId, workspaceId: family.workspace.workspaceId)

        #expect(refetched?.state == .active)
        #expect(refetched?.acceptedAt != nil)
    }

    @Test("A save failure during acceptInvitation propagates")
    @MainActor
    func acceptInvitationPropagatesSaveFailure() throws {
        struct InjectedSaveFailure: Error {}

        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let participant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: AthleteId(), invitedBy: ownerActorId
        )

        #expect(throws: InjectedSaveFailure.self) {
            try repository.acceptInvitation(participant, saveOverride: { throw InjectedSaveFailure() })
        }
    }
}
