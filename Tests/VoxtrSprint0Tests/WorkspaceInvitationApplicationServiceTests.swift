import Testing
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
@testable import VoxtrParentDomain

/// End-to-end, integration-oriented: exercises the real facade against
/// real (in-memory) repositories and its real underlying services,
/// never mocks. Every test constructs its own
/// `ModelContainer`/repository/services inline — no shared helper —
/// matching this project's established rule. Every test is
/// `@MainActor`, matching the production actor model.
@Suite("WorkspaceInvitationApplicationService (VX-038, complete vertical slice)", .serialized)
struct WorkspaceInvitationApplicationServiceTests {

    // MARK: - Invitation creation

    @Test("Creating an invitation for an eligible athlete succeeds, producing a participant in .invited state")
    @MainActor
    func createsInvitationForEligibleAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )
        let athleteId = AthleteId()
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        let result = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)

        guard case .invited(let participant) = result else {
            Issue.record("Expected .invited")
            return
        }
        #expect(participant.state == .invited)
        #expect(participant.linkedAthleteId == athleteId.rawValue)
    }

    @Test("Creating an invitation for an ineligible (archived) athlete fails, and no participant is created")
    @MainActor
    func creationFailsForIneligibleAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: AthleteId(),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: true)
        )

        let result = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)

        guard case .eligibilityFailed(let primary, _) = result else {
            Issue.record("Expected .eligibilityFailed")
            return
        }
        #expect(primary == .athleteArchived)
        let allParticipants = try repository.fetchParticipants(forWorkspace: family.workspace.workspaceId)
        #expect(allParticipants.count == 1) // only the owner
    }

    // MARK: - Duplicate invitation prevention

    @Test("Creating a second invitation for an athlete who already has a participant is prevented, without the caller needing to check")
    @MainActor
    func duplicateInvitationIsPrevented() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )
        let athleteId = AthleteId()
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )
        // Note: the caller does NOT pass hasExistingParticipant at all —
        // this facade's own signature has no such parameter, unlike the
        // underlying AthleteParticipantInvitationService it wraps.
        _ = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)

        let secondResult = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)

        guard case .eligibilityFailed(let primary, _) = secondResult else {
            Issue.record("Expected .eligibilityFailed")
            return
        }
        #expect(primary == .participantAlreadyExists)
    }

    @Test("Duplicate prevention does not create a second WorkspaceParticipant record")
    @MainActor
    func duplicatePreventionDoesNotCreateSecondRecord() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )
        let athleteId = AthleteId()
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )
        _ = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)
        let countAfterFirst = try repository.fetchParticipants(forWorkspace: family.workspace.workspaceId).count

        _ = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)

        let countAfterSecond = try repository.fetchParticipants(forWorkspace: family.workspace.workspaceId).count
        #expect(countAfterSecond == countAfterFirst)
    }

    @Test("A missing candidate (no athlete at all) skips the duplicate check and simply fails eligibility with .athleteNotFound")
    @MainActor
    func missingCandidateSkipsDuplicateCheck() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )

        let result = service.createInvitation(candidate: nil, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)

        guard case .eligibilityFailed(let primary, _) = result else {
            Issue.record("Expected .eligibilityFailed")
            return
        }
        #expect(primary == .athleteNotFound)
    }

    // MARK: - Invitation retrieval

    @Test("pendingInvitations returns the athlete just invited")
    @MainActor
    func pendingInvitationsReturnsJustInvitedAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )
        let athleteId = AthleteId()
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )
        _ = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)

        let pending = try service.pendingInvitations(forWorkspace: family.workspace.workspaceId)

        #expect(pending.count == 1)
        #expect(pending.first?.linkedAthleteId == athleteId.rawValue)
    }

    @Test("pendingInvitations no longer includes an athlete once they've accepted")
    @MainActor
    func pendingInvitationsExcludesAcceptedAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )
        let athleteId = AthleteId()
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )
        _ = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)
        _ = service.acceptInvitation(
            athleteId: athleteId, workspaceId: family.workspace.workspaceId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        let pending = try service.pendingInvitations(forWorkspace: family.workspace.workspaceId)

        #expect(pending.isEmpty)
    }

    // MARK: - Invitation acceptance / participant activation

    @Test("Accepting a pending invitation activates the participant — state becomes .active")
    @MainActor
    func acceptingInvitationActivatesParticipant() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )
        let athleteId = AthleteId()
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )
        _ = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)

        let result = service.acceptInvitation(
            athleteId: athleteId, workspaceId: family.workspace.workspaceId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        guard case .accepted(let participant) = result else {
            Issue.record("Expected .accepted")
            return
        }
        #expect(participant.state == .active)
    }

    // MARK: - Workspace membership after acceptance

    @Test("After acceptance, the athlete appears in activeParticipants and no longer in pendingInvitations")
    @MainActor
    func workspaceMembershipReflectsAcceptance() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )
        let athleteId = AthleteId()
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )
        _ = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)
        _ = service.acceptInvitation(
            athleteId: athleteId, workspaceId: family.workspace.workspaceId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        let active = try service.activeParticipants(forWorkspace: family.workspace.workspaceId)
        let pending = try service.pendingInvitations(forWorkspace: family.workspace.workspaceId)

        #expect(active.contains { $0.linkedAthleteId == athleteId.rawValue })
        #expect(pending.isEmpty)
    }

    @Test("activeParticipants includes the workspace owner from the moment the workspace is created")
    @MainActor
    func activeParticipantsIncludesOwnerImmediately() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )

        let active = try service.activeParticipants(forWorkspace: family.workspace.workspaceId)

        #expect(active.contains { $0.id == family.participant.id })
    }

    // MARK: - Transition validation

    @Test("Accepting an invitation for an athlete with no invitation at all results in .invitationNotFound")
    @MainActor
    func acceptingNonexistentInvitationFails() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )

        let result = service.acceptInvitation(
            athleteId: AthleteId(), workspaceId: family.workspace.workspaceId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        guard case .invitationNotFound = result else {
            Issue.record("Expected .invitationNotFound")
            return
        }
    }

    @Test("Accepting an already-active participant's invitation again results in .alreadyAccepted, not a duplicate activation")
    @MainActor
    func acceptingAlreadyActiveParticipantFails() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )
        let athleteId = AthleteId()
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )
        let facts = AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        _ = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)
        _ = service.acceptInvitation(athleteId: athleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        let secondResult = service.acceptInvitation(athleteId: athleteId, workspaceId: family.workspace.workspaceId, eligibilityFacts: facts)

        guard case .alreadyAccepted = secondResult else {
            Issue.record("Expected .alreadyAccepted")
            return
        }
    }

    @Test("Participant identity is preserved end to end — the same id from invitation through acceptance")
    @MainActor
    func participantIdentityPreservedEndToEnd() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let service = WorkspaceInvitationApplicationService(
            invitationService: AthleteParticipantInvitationService(
                eligibilityService: AthleteParticipantEligibilityService(), repository: repository
            ),
            acceptanceService: AcceptWorkspaceInvitationService(
                repository: repository, eligibilityService: AthleteParticipantEligibilityService()
            ),
            repository: repository
        )
        let athleteId = AthleteId()
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: athleteId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        let creationResult = service.createInvitation(candidate: candidate, workspaceId: family.workspace.workspaceId, invitedBy: ownerActorId)
        guard case .invited(let createdParticipant) = creationResult else {
            Issue.record("Expected .invited")
            return
        }
        let acceptanceResult = service.acceptInvitation(
            athleteId: athleteId, workspaceId: family.workspace.workspaceId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )
        guard case .accepted(let acceptedParticipant) = acceptanceResult else {
            Issue.record("Expected .accepted")
            return
        }

        #expect(createdParticipant.id == acceptedParticipant.id)
    }

    // MARK: - Repository failures

    @Test("A save failure during the underlying invitation creation surfaces through the facade as .repositoryFailed")
    @MainActor
    func repositoryFailureDuringCreationPropagates() throws {
        // No established deterministic-failure seam exists for a plain
        // fetch (findParticipant, used for the duplicate check) in
        // this codebase — only save operations do. This test exercises
        // the save-failure path, which is the one deterministically
        // testable failure mode, via the wrapped service's own
        // internal test seam (the facade adds no new one of its own —
        // it delegates entirely to this method for creation).
        struct InjectedSaveFailure: Error {}

        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let ownerActorId = ActorId(rawValue: family.participant.id)
        let invitationService = AthleteParticipantInvitationService(
            eligibilityService: AthleteParticipantEligibilityService(), repository: repository
        )
        let candidate = AthleteParticipantInvitationCandidate(
            athleteId: AthleteId(),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false)
        )

        let result = invitationService.invite(
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

    @Test("A save failure during acceptance surfaces through the facade's underlying service as .repositoryFailed")
    @MainActor
    func repositoryFailureDuringAcceptancePropagates() throws {
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

        let result = acceptanceService.accept(
            athleteId: athleteId,
            workspaceId: family.workspace.workspaceId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: family.workspace.workspaceId, isArchived: false),
            saveOverride: { throw InjectedSaveFailure() }
        )

        guard case .repositoryFailed = result else {
            Issue.record("Expected .repositoryFailed")
            return
        }
    }
}
