import Testing
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
@testable import VoxtrParentDomain

/// Invocation counts ("exactly once" / "never") are verified by
/// checking the real repository's own persisted state after the call,
/// not by a call-counting mock — this proves the side effect actually
/// did or didn't happen, rather than only that a method was called,
/// and avoids introducing a protocol abstraction purely for
/// testability.
///
/// `AthleteParticipantActivationResult` is not `Equatable` (it carries
/// `WorkspaceParticipant`, a `@Model` class with no Equatable
/// conformance of its own), so every assertion here pattern-matches
/// the case directly rather than comparing with `==`.
@Suite("AthleteParticipantActivationService (VX-036)", .serialized)
struct AthleteParticipantActivationServiceTests {

    private static func makeSetup() throws -> (
        repository: ParentWorkspaceRepository,
        activationService: AthleteParticipantActivationService,
        workspaceId: WorkspaceId,
        ownerActorId: ActorId
    ) {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let family = try repository.createParentAndWorkspace(givenName: "Kari")
        let activationService = AthleteParticipantActivationService(
            eligibilityService: AthleteParticipantEligibilityService(),
            repository: repository
        )
        return (repository, activationService, family.workspace.workspaceId, ActorId(rawValue: family.participant.id))
    }

    // MARK: - Successful activation

    @Test("An eligible athlete is activated, producing a participant with role .athlete, state .invited, and the correct linkedAthleteId/invitedBy")
    func successfulActivation() throws {
        let setup = try Self.makeSetup()
        let athleteId = AthleteId()
        let facts = AthleteEligibilityFacts(workspaceId: setup.workspaceId, isArchived: false)

        let result = setup.activationService.activate(
            athlete: facts,
            workspaceId: setup.workspaceId,
            linkedAthleteId: athleteId,
            invitedBy: setup.ownerActorId,
            hasExistingParticipant: false
        )

        guard case .activated(let participant) = result else {
            Issue.record("Expected .activated")
            return
        }
        #expect(participant.role == .athlete)
        #expect(participant.state == .invited)
        #expect(participant.linkedAthleteId == athleteId.rawValue)
        #expect(participant.invitedBy == setup.ownerActorId.rawValue)
    }

    // MARK: - Missing athlete

    @Test("A missing athlete results in .eligibilityFailed with .athleteNotFound")
    func missingAthlete() throws {
        let setup = try Self.makeSetup()

        let result = setup.activationService.activate(
            athlete: nil,
            workspaceId: setup.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: setup.ownerActorId,
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

    @Test("An archived athlete results in .eligibilityFailed with .athleteArchived")
    func archivedAthlete() throws {
        let setup = try Self.makeSetup()
        let facts = AthleteEligibilityFacts(workspaceId: setup.workspaceId, isArchived: true)

        let result = setup.activationService.activate(
            athlete: facts,
            workspaceId: setup.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: setup.ownerActorId,
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

    @Test("An athlete in a different workspace results in .eligibilityFailed with .athleteNotInWorkspace")
    func workspaceMismatch() throws {
        let setup = try Self.makeSetup()
        let facts = AthleteEligibilityFacts(workspaceId: WorkspaceId(), isArchived: false)

        let result = setup.activationService.activate(
            athlete: facts,
            workspaceId: setup.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: setup.ownerActorId,
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

    @Test("An athlete who already has a participant results in .eligibilityFailed with .participantAlreadyExists")
    func duplicateParticipant() throws {
        let setup = try Self.makeSetup()
        let facts = AthleteEligibilityFacts(workspaceId: setup.workspaceId, isArchived: false)

        let result = setup.activationService.activate(
            athlete: facts,
            workspaceId: setup.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: setup.ownerActorId,
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

    @Test("A repository save failure results in .repositoryFailed")
    func repositoryFailure() throws {
        struct InjectedSaveFailure: Error {}

        let setup = try Self.makeSetup()
        let facts = AthleteEligibilityFacts(workspaceId: setup.workspaceId, isArchived: false)

        let result = setup.activationService.activate(
            athlete: facts,
            workspaceId: setup.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: setup.ownerActorId,
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
    func repositoryInvokedExactlyOnceOnSuccess() throws {
        let setup = try Self.makeSetup()
        let facts = AthleteEligibilityFacts(workspaceId: setup.workspaceId, isArchived: false)
        let participantsBefore = try setup.repository.fetchAllParticipants().count

        let result = setup.activationService.activate(
            athlete: facts,
            workspaceId: setup.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: setup.ownerActorId,
            hasExistingParticipant: false
        )

        let participantsAfter = try setup.repository.fetchAllParticipants().count
        #expect(participantsAfter == participantsBefore + 1)
        guard case .activated = result else {
            Issue.record("Expected .activated")
            return
        }
    }

    @Test("The repository is never invoked when eligibility fails")
    func repositoryNeverInvokedWhenEligibilityFails() throws {
        let setup = try Self.makeSetup()
        let facts = AthleteEligibilityFacts(workspaceId: setup.workspaceId, isArchived: true)
        let participantsBefore = try setup.repository.fetchAllParticipants().count

        let result = setup.activationService.activate(
            athlete: facts,
            workspaceId: setup.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: setup.ownerActorId,
            hasExistingParticipant: false
        )

        let participantsAfter = try setup.repository.fetchAllParticipants().count
        #expect(participantsAfter == participantsBefore)
        guard case .eligibilityFailed = result else {
            Issue.record("Expected .eligibilityFailed")
            return
        }
    }
}
