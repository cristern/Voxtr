import Testing
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
@testable import VoxtrParentDomain

/// Every test constructs its own `ModelContainer`/repository/service
/// inline — no shared helper method — matching this project's own
/// established rule (see `ParentWorkspaceRepositoryTests.swift`)
/// against a private helper shared across `@Test` functions for
/// `ModelContainer`/repository construction.
///
/// Every test is `@MainActor`: `AthleteParticipantActivationService`
/// is `@MainActor` (it wraps `ParentWorkspaceRepository`, which is),
/// so calling `activate(...)` from a non-isolated test context is a
/// compile error — "Call to main actor-isolated instance method
/// 'activate(...)' in a synchronous nonisolated context." This is the
/// production actor model, not a workaround for it.
///
/// Invocation counts ("exactly once" / "never") are verified against
/// the real repository's own persisted state, not a call-counting
/// mock — proving the side effect actually did or didn't happen.
///
/// `AthleteParticipantActivationResult` is not `Equatable` (it carries
/// `WorkspaceParticipant`, a `@Model` class with no Equatable
/// conformance), so every assertion pattern-matches the case directly.
@Suite("AthleteParticipantActivationService (VX-036, revised)", .serialized)
struct AthleteParticipantActivationServiceTests {

    // MARK: - Successful activation

    @Test("An eligible candidate is activated, producing a participant with role .athlete, state .invited, and the correct linkedAthleteId/invitedBy")
    @MainActor
    func successfulActivation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let activationService = AthleteParticipantActivationService(
            eligibilityService: AthleteParticipantEligibilityService(),
            repository: repository
        )
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let athleteId = AthleteId()
        let candidate = AthleteParticipantActivationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        let result = activationService.activate(
            candidate: candidate,
            workspaceId: family.workspace.workspaceId,
            invitedBy: ownerActorId,
            hasExistingParticipant: false
        )

        guard case .activated(let participant) = result else {
            Issue.record("Expected .activated")
            return
        }
        #expect(participant.role == .athlete)
        #expect(participant.state == .invited)
        #expect(participant.linkedAthleteId == athleteId.rawValue)
        #expect(participant.invitedBy == ownerActorId.rawValue)
    }

    // MARK: - Missing athlete

    @Test("A nil candidate results in .eligibilityFailed with .athleteNotFound")
    @MainActor
    func missingAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let activationService = AthleteParticipantActivationService(
            eligibilityService: AthleteParticipantEligibilityService(),
            repository: repository
        )
        let ownerActorId = ActorId(rawValue: family.participant.id)

        let result = activationService.activate(
            candidate: nil,
            workspaceId: family.workspace.workspaceId,
            invitedBy: ownerActorId,
            hasExistingParticipant: false
        )

        guard case .eligibilityFailed(let primary, let additional) = result else {
            Issue.record("Expected .eligibilityFailed")
            return
        }
        #expect(primary == .athleteNotFound)
        #expect(additional.isEmpty)
    }

    // MARK: - Archived athlete

    @Test("An archived candidate results in .eligibilityFailed with .athleteArchived")
    @MainActor
    func archivedAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let activationService = AthleteParticipantActivationService(
            eligibilityService: AthleteParticipantEligibilityService(),
            repository: repository
        )
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let candidate = AthleteParticipantActivationCandidate(
            athleteId: AthleteId(),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: true)
        )

        let result = activationService.activate(
            candidate: candidate,
            workspaceId: family.workspace.workspaceId,
            invitedBy: ownerActorId,
            hasExistingParticipant: false
        )

        guard case .eligibilityFailed(let primary, let additional) = result else {
            Issue.record("Expected .eligibilityFailed")
            return
        }
        #expect(primary == .athleteArchived)
        #expect(additional.isEmpty)
    }

    // MARK: - Workspace mismatch

    @Test("A candidate whose eligibility facts reference a different workspace results in .eligibilityFailed with .athleteNotInWorkspace")
    @MainActor
    func workspaceMismatch() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let activationService = AthleteParticipantActivationService(
            eligibilityService: AthleteParticipantEligibilityService(),
            repository: repository
        )
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let candidate = AthleteParticipantActivationCandidate(
            athleteId: AthleteId(),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: WorkspaceId(), isArchived: false)
        )

        let result = activationService.activate(
            candidate: candidate,
            workspaceId: family.workspace.workspaceId,
            invitedBy: ownerActorId,
            hasExistingParticipant: false
        )

        guard case .eligibilityFailed(let primary, let additional) = result else {
            Issue.record("Expected .eligibilityFailed")
            return
        }
        #expect(primary == .athleteNotInWorkspace)
        #expect(additional.isEmpty)
    }

    // MARK: - Duplicate participant

    @Test("A candidate who already has a participant results in .eligibilityFailed with .participantAlreadyExists")
    @MainActor
    func duplicateParticipant() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let activationService = AthleteParticipantActivationService(
            eligibilityService: AthleteParticipantEligibilityService(),
            repository: repository
        )
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let candidate = AthleteParticipantActivationCandidate(
            athleteId: AthleteId(),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        let result = activationService.activate(
            candidate: candidate,
            workspaceId: family.workspace.workspaceId,
            invitedBy: ownerActorId,
            hasExistingParticipant: true
        )

        guard case .eligibilityFailed(let primary, let additional) = result else {
            Issue.record("Expected .eligibilityFailed")
            return
        }
        #expect(primary == .participantAlreadyExists)
        #expect(additional.isEmpty)
    }

    // MARK: - Repository failure

    @Test("A repository save failure results in .repositoryFailed, with no raw error or string exposed")
    @MainActor
    func repositoryFailure() throws {
        struct InjectedSaveFailure: Error {}

        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let activationService = AthleteParticipantActivationService(
            eligibilityService: AthleteParticipantEligibilityService(),
            repository: repository
        )
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let candidate = AthleteParticipantActivationCandidate(
            athleteId: AthleteId(),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        let result = activationService.activate(
            candidate: candidate,
            workspaceId: family.workspace.workspaceId,
            invitedBy: ownerActorId,
            hasExistingParticipant: false,
            saveOverride: { throw InjectedSaveFailure() }
        )

        guard case .repositoryFailed = result else {
            Issue.record("Expected .repositoryFailed")
            return
        }
    }

    // MARK: - Repository invocation counting

    @Test("The repository is invoked exactly once when activation succeeds")
    @MainActor
    func repositoryInvokedExactlyOnceOnSuccess() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let activationService = AthleteParticipantActivationService(
            eligibilityService: AthleteParticipantEligibilityService(),
            repository: repository
        )
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let candidate = AthleteParticipantActivationCandidate(
            athleteId: AthleteId(),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )
        let participantsBefore = try repository.fetchAllParticipants().count

        let result = activationService.activate(
            candidate: candidate,
            workspaceId: family.workspace.workspaceId,
            invitedBy: ownerActorId,
            hasExistingParticipant: false
        )

        let participantsAfter = try repository.fetchAllParticipants().count
        #expect(participantsAfter == participantsBefore + 1)
        guard case .activated = result else {
            Issue.record("Expected .activated")
            return
        }
    }

    @Test("The repository is never invoked when eligibility fails")
    @MainActor
    func repositoryNeverInvokedWhenEligibilityFails() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let activationService = AthleteParticipantActivationService(
            eligibilityService: AthleteParticipantEligibilityService(),
            repository: repository
        )
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let candidate = AthleteParticipantActivationCandidate(
            athleteId: AthleteId(),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: true)
        )
        let participantsBefore = try repository.fetchAllParticipants().count

        let result = activationService.activate(
            candidate: candidate,
            workspaceId: family.workspace.workspaceId,
            invitedBy: ownerActorId,
            hasExistingParticipant: false
        )

        let participantsAfter = try repository.fetchAllParticipants().count
        #expect(participantsAfter == participantsBefore)
        guard case .eligibilityFailed = result else {
            Issue.record("Expected .eligibilityFailed")
            return
        }
    }

    // MARK: - Candidate identity always matches evaluated eligibility facts

    @Test("The repository always creates the participant using candidate.athleteId, never a separately-supplied id")
    @MainActor
    func repositoryAlwaysUsesCandidateAthleteId() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let activationService = AthleteParticipantActivationService(
            eligibilityService: AthleteParticipantEligibilityService(),
            repository: repository
        )
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let athleteId = AthleteId()
        let candidate = AthleteParticipantActivationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        let result = activationService.activate(
            candidate: candidate,
            workspaceId: family.workspace.workspaceId,
            invitedBy: ownerActorId,
            hasExistingParticipant: false
        )

        guard case .activated(let participant) = result else {
            Issue.record("Expected .activated")
            return
        }
        #expect(participant.linkedAthleteId == athleteId.rawValue)
        #expect(participant.linkedAthleteId == candidate.athleteId.rawValue)
    }
}
