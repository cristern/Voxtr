import Testing
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
@testable import VoxtrParentDomain

/// Integration-oriented: exercises the real orchestration service
/// against real (in-memory) repositories, never mocks. Every test
/// constructs its own `ModelContainer`/repository/services inline —
/// no shared helper — matching this project's established rule.
/// `AcceptWorkspaceInvitationResult` is not `Equatable` (it carries
/// `WorkspaceParticipant`), so every assertion pattern-matches the
/// case directly.
@Suite("AcceptWorkspaceInvitationService (VX-037, ADR-0002)", .serialized)
struct AcceptWorkspaceInvitationServiceTests {

    // MARK: - Invitation creation (the separate, reused invite step)

    @Test("Creating an invitation produces a WorkspaceParticipant in .invited state — reusing the existing repository method unchanged")
    @MainActor
    func invitationCreationProducesInvitedParticipant() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)

        let participant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: AthleteId(), invitedBy: ownerActorId
        )

        #expect(participant.role == .athlete)
        #expect(participant.state == .invited)
    }

    // MARK: - Acceptance: invited -> active

    @Test("An invited, eligible participant is accepted and transitions to .active")
    @MainActor
    func invitedEligibleParticipantIsAccepted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let athleteId = AthleteId()
        _ = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)

        let result = acceptanceService.accept(athleteId: athleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        guard case .accepted(let participant) = result else {
            Issue.record("Expected .accepted")
            return
        }
        #expect(participant.state == .active)
        #expect(participant.acceptedAt != nil)
    }

    @Test("The accepted participant's linkedAthleteId matches the athlete accept() was called for")
    @MainActor
    func acceptedParticipantMatchesRequestedAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let athleteId = AthleteId()
        _ = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)

        let result = acceptanceService.accept(athleteId: athleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        guard case .accepted(let participant) = result else {
            Issue.record("Expected .accepted")
            return
        }
        #expect(participant.linkedAthleteId == athleteId.rawValue)
    }

    // MARK: - Already active

    @Test("A participant already .active results in .alreadyAccepted")
    @MainActor
    func alreadyActiveParticipantIsAlreadyAccepted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let athleteId = AthleteId()
        let participant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        try repository.acceptInvitation(participant)
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)

        let result = acceptanceService.accept(athleteId: athleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        guard case .alreadyAccepted = result else {
            Issue.record("Expected .alreadyAccepted")
            return
        }
    }

    // MARK: - Revoked invitation

    @Test("A revoked participant results in .invitationRevoked")
    @MainActor
    func revokedParticipantResultsInInvitationRevoked() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let athleteId = AthleteId()
        let participant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        participant.state = .revoked
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)

        let result = acceptanceService.accept(athleteId: athleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        guard case .invitationRevoked = result else {
            Issue.record("Expected .invitationRevoked")
            return
        }
    }

    // MARK: - Declined invitation

    @Test("A declined participant results in .invitationDeclined")
    @MainActor
    func declinedParticipantResultsInInvitationDeclined() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let athleteId = AthleteId()
        let participant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        participant.state = .declined
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)

        let result = acceptanceService.accept(athleteId: athleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        guard case .invitationDeclined = result else {
            Issue.record("Expected .invitationDeclined")
            return
        }
    }

    // MARK: - Invitation not found

    @Test("No participant at all for the athlete results in .invitationNotFound")
    @MainActor
    func noParticipantResultsInInvitationNotFound() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)

        let result = acceptanceService.accept(athleteId: AthleteId(), workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        guard case .invitationNotFound = result else {
            Issue.record("Expected .invitationNotFound")
            return
        }
    }

    // MARK: - Eligibility failure

    @Test("An archived athlete results in .notEligible(.athleteArchived), and the reason is preserved")
    @MainActor
    func archivedAthleteResultsInNotEligible() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let athleteId = AthleteId()
        _ = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: true)

        let result = acceptanceService.accept(athleteId: athleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        guard case .notEligible(let primary, let additional) = result else {
            Issue.record("Expected .notEligible")
            return
        }
        #expect(primary == .athleteArchived)
        #expect(additional.isEmpty)
    }

    @Test("An ineligible acceptance attempt does not transition the participant's state")
    @MainActor
    func ineligibleAcceptanceDoesNotTransitionState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let athleteId = AthleteId()
        let participant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: true)

        _ = acceptanceService.accept(athleteId: athleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        #expect(participant.state == .invited)
    }

    // MARK: - Repository failure

    @Test("A save failure during the state transition results in .repositoryFailed")
    @MainActor
    func saveFailureResultsInRepositoryFailed() throws {
        struct InjectedSaveFailure: Error {}

        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let athleteId = AthleteId()
        _ = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)

        let result = acceptanceService.accept(
            athleteId: athleteId,
            workspaceId: family.workspace.workspaceId,
            eligibilityFacts: facts,
            saveOverride: { throw InjectedSaveFailure() }
        )

        guard case .repositoryFailed = result else {
            Issue.record("Expected .repositoryFailed")
            return
        }
    }

    // MARK: - State transition integrity

    @Test("Accepting an invitation never creates a second WorkspaceParticipant — the existing one transitions state, single aggregate mutation")
    @MainActor
    func acceptanceNeverCreatesSecondParticipant() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let athleteId = AthleteId()
        let originalParticipant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: athleteId, invitedBy: ownerActorId
        )
        let participantsBefore = try repository.fetchParticipants(forWorkspace: family.workspace.workspaceId).count
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)

        let result = acceptanceService.accept(athleteId: athleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        let participantsAfter = try repository.fetchParticipants(forWorkspace: family.workspace.workspaceId).count
        #expect(participantsAfter == participantsBefore)
        guard case .accepted(let acceptedParticipant) = result else {
            Issue.record("Expected .accepted")
            return
        }
        #expect(acceptedParticipant.id == originalParticipant.id)
    }

    @Test("Two different athletes' invitations transition independently, without affecting one another")
    @MainActor
    func distinctInvitationsTransitionIndependently() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: repository, eligibilityService: AthleteParticipantEligibilityService()
        )
        let firstAthleteId = AthleteId()
        let secondAthleteId = AthleteId()
        _ = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: firstAthleteId, invitedBy: ownerActorId
        )
        let secondParticipant = try repository.createInvitedAthleteParticipant(
            workspaceId: family.workspace.workspaceId, linkedAthleteId: secondAthleteId, invitedBy: ownerActorId
        )
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)

        _ = acceptanceService.accept(athleteId: firstAthleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        #expect(secondParticipant.state == .invited)
    }
}
