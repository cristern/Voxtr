import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrParentDomain
import VoxtrAthleteDomain

// NOTE: like the other persistence-backed tests in this suite (see
// `AthleteConnectionIdentityBindingServiceTests.swift`'s own header),
// the one test here that constructs a real `ModelContainer`
// (`realBoundIdentityActivatesSessionAndMutatesNothing`) exercises
// @Model types through actual SwiftData persistence and requires the
// Xcode/macOS SwiftData runtime — written but not executed in this
// sandbox. Every other test below calls `AthleteSessionActivationService
// .resolve(boundIdentity:participants:)` directly — a pure, `nonisolated`
// function with no `ModelContext`/persistence I/O at all. Constructing
// `WorkspaceParticipant` (an `@Model` class) WITHOUT ever inserting it
// into a `ModelContext` is itself just plain Swift object construction —
// no SwiftData runtime involved, matching this project's own
// established "pure value-type test" convention (see
// `CurrentSessionActorTests.swift`). `BoundAthleteIdentity`'s memberwise
// initializer is `internal` (deliberately not `public` — see B2.3's own
// doc comment), so constructing one here requires `@testable import
// VoxtrAppShell`, same reason `AthleteConnectionIdentityBindingService
// .resolve` itself needed it.
@Suite("AthleteSessionActivationService (Athlete Connection Foundation B2.4)", .serialized)
struct AthleteSessionActivationServiceTests {

    // MARK: - Fixture helpers (in-memory, never persisted)

    private static func makeParticipant(
        id: UUID = UUID(),
        workspaceId: UUID,
        role: WorkspaceRole = .athlete,
        state: ParticipantState = .active,
        linkedAthleteId: UUID? = UUID()
    ) -> WorkspaceParticipant {
        WorkspaceParticipant(
            id: id,
            workspaceId: WorkspaceId(rawValue: workspaceId),
            accountId: .pending,
            role: role,
            state: state,
            linkedAthleteId: linkedAthleteId.map { AthleteId(rawValue: $0) },
            invitedAt: .now,
            acceptedAt: state == .active ? .now : nil
        )
    }

    private static func makeBoundIdentity(
        workspaceId: UUID,
        participantId: UUID,
        athleteId: UUID
    ) -> BoundAthleteIdentity {
        BoundAthleteIdentity(
            workspaceId: WorkspaceId(rawValue: workspaceId),
            participantId: participantId,
            athleteId: AthleteId(rawValue: athleteId)
        )
    }

    // MARK: - Pure resolve(boundIdentity:participants:) tests

    @Test("A valid BoundAthleteIdentity whose referenced participant still matches every fact resolves to the canonical CurrentSessionActor for that participant")
    func validBoundIdentityResolvesToCanonicalActor() throws {
        let workspaceId = UUID()
        let athleteId = UUID()
        let participant = Self.makeParticipant(workspaceId: workspaceId, linkedAthleteId: athleteId)
        let boundIdentity = Self.makeBoundIdentity(workspaceId: workspaceId, participantId: participant.id, athleteId: athleteId)

        let actor = try AthleteSessionActivationService.resolve(boundIdentity: boundIdentity, participants: [participant])

        #expect(actor.participantId == participant.id)
        #expect(actor.workspaceId == WorkspaceId(rawValue: workspaceId))
        #expect(actor.role == .athlete)
        #expect(actor.linkedAthleteId == AthleteId(rawValue: athleteId))
    }

    @Test("No WorkspaceParticipant with the bound participantId exists fails with participantNotFound")
    func participantMissingFailsExplicitly() {
        let workspaceId = UUID()
        let athleteId = UUID()
        let boundIdentity = Self.makeBoundIdentity(workspaceId: workspaceId, participantId: UUID(), athleteId: athleteId)

        #expect(throws: AthleteSessionActivationError.participantNotFound) {
            try AthleteSessionActivationService.resolve(boundIdentity: boundIdentity, participants: [])
        }
    }

    @Test("Two WorkspaceParticipant records sharing the bound participantId fail with localIdentityGraphInconsistent rather than silently picking the first match")
    func duplicateParticipantIdFailsExplicitly() {
        let workspaceId = UUID()
        let athleteId = UUID()
        let sharedId = UUID()
        let first = Self.makeParticipant(id: sharedId, workspaceId: workspaceId, linkedAthleteId: athleteId)
        let second = Self.makeParticipant(id: sharedId, workspaceId: workspaceId, linkedAthleteId: athleteId)
        let boundIdentity = Self.makeBoundIdentity(workspaceId: workspaceId, participantId: sharedId, athleteId: athleteId)

        #expect(throws: AthleteSessionActivationError.localIdentityGraphInconsistent) {
            try AthleteSessionActivationService.resolve(boundIdentity: boundIdentity, participants: [first, second])
        }
    }

    @Test("A participant whose current workspaceId no longer matches the bound workspaceId fails with workspaceMismatch")
    func workspaceMismatchFailsExplicitly() {
        let athleteId = UUID()
        let participant = Self.makeParticipant(workspaceId: UUID(), linkedAthleteId: athleteId)
        // Deliberately bound to a DIFFERENT workspaceId than the participant's own.
        let boundIdentity = Self.makeBoundIdentity(workspaceId: UUID(), participantId: participant.id, athleteId: athleteId)

        #expect(throws: AthleteSessionActivationError.workspaceMismatch) {
            try AthleteSessionActivationService.resolve(boundIdentity: boundIdentity, participants: [participant])
        }
    }

    @Test("A participant whose current role is no longer .athlete fails with participantRoleMismatch")
    func roleMismatchFailsExplicitly() {
        let workspaceId = UUID()
        // .workspaceOwner may have a nil linkedAthleteId (unlike .athlete, which cannot).
        let participant = Self.makeParticipant(workspaceId: workspaceId, role: .workspaceOwner, linkedAthleteId: nil)
        let boundIdentity = Self.makeBoundIdentity(workspaceId: workspaceId, participantId: participant.id, athleteId: UUID())

        #expect(throws: AthleteSessionActivationError.participantRoleMismatch) {
            try AthleteSessionActivationService.resolve(boundIdentity: boundIdentity, participants: [participant])
        }
    }

    @Test("A participant that is no longer .active (e.g. reverted to .invited, or .declined/.revoked since binding) fails with participantNotActive rather than being silently activated")
    func notActiveFailsExplicitly() {
        let workspaceId = UUID()
        let athleteId = UUID()
        let states: [ParticipantState] = [.invited, .declined, .revoked]
        for state in states {
            let participant = Self.makeParticipant(workspaceId: workspaceId, state: state, linkedAthleteId: athleteId)
            let boundIdentity = Self.makeBoundIdentity(workspaceId: workspaceId, participantId: participant.id, athleteId: athleteId)

            #expect(throws: AthleteSessionActivationError.participantNotActive) {
                try AthleteSessionActivationService.resolve(boundIdentity: boundIdentity, participants: [participant])
            }
        }
    }

    @Test("A participant whose current linkedAthleteId no longer matches the bound athleteId fails with athleteLinkMismatch")
    func athleteLinkMismatchFailsExplicitly() {
        let workspaceId = UUID()
        let participant = Self.makeParticipant(workspaceId: workspaceId, linkedAthleteId: UUID())
        // Deliberately bound to a DIFFERENT athleteId than the participant's own current link.
        let boundIdentity = Self.makeBoundIdentity(workspaceId: workspaceId, participantId: participant.id, athleteId: UUID())

        #expect(throws: AthleteSessionActivationError.athleteLinkMismatch) {
            try AthleteSessionActivationService.resolve(boundIdentity: boundIdentity, participants: [participant])
        }
    }

    @Test("resolve(boundIdentity:participants:) is deterministic — repeated calls with identical, unchanged inputs produce an identical CurrentSessionActor")
    func repeatedActivationIsDeterministic() throws {
        let workspaceId = UUID()
        let athleteId = UUID()
        let participant = Self.makeParticipant(workspaceId: workspaceId, linkedAthleteId: athleteId)
        let boundIdentity = Self.makeBoundIdentity(workspaceId: workspaceId, participantId: participant.id, athleteId: athleteId)

        let first = try AthleteSessionActivationService.resolve(boundIdentity: boundIdentity, participants: [participant])
        let second = try AthleteSessionActivationService.resolve(boundIdentity: boundIdentity, participants: [participant])

        #expect(first == second)
    }

    @Test("A successful activation produces exactly what CurrentSessionActor.resolve(from:) itself would produce for that participant — no separate/duplicated actor-resolution logic")
    func activationDelegatesToCanonicalResolver() throws {
        let workspaceId = UUID()
        let athleteId = UUID()
        let participant = Self.makeParticipant(workspaceId: workspaceId, linkedAthleteId: athleteId)
        let boundIdentity = Self.makeBoundIdentity(workspaceId: workspaceId, participantId: participant.id, athleteId: athleteId)

        let activated = try AthleteSessionActivationService.resolve(boundIdentity: boundIdentity, participants: [participant])
        let directlyResolved = CurrentSessionActor.resolve(from: participant)

        #expect(activated == directlyResolved)
    }

    // MARK: - Real persistence integration test

    @Test("A real, canonically-created and bound AthleteApp identity activates to the correct session actor and creates/mutates nothing")
    @MainActor
    func realBoundIdentityActivatesSessionAndMutatesNothing() throws {
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
        let created = try coordinator.createFamily(
            parentGivenName: "Kari",
            athleteGivenName: "Jonas",
            athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
            athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            athleteDevelopmentStage: .parentLed
        )
        let ownerActorId = ActorId(rawValue: created.participant.id)
        _ = try parentWorkspaceRepository.createInvitedAthleteParticipant(
            workspaceId: created.workspace.workspaceId,
            linkedAthleteId: created.athlete.athleteId,
            invitedBy: ownerActorId
        )
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: parentWorkspaceRepository,
            eligibilityService: AthleteParticipantEligibilityService()
        )
        let acceptanceResult = acceptanceService.accept(
            athleteId: created.athlete.athleteId,
            workspaceId: created.workspace.workspaceId,
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: created.workspace.workspaceId, isArchived: false)
        )
        guard case .accepted(let acceptedParticipant) = acceptanceResult else {
            Issue.record("Expected .accepted")
            return
        }

        let restorationService = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let bindingService = AthleteConnectionIdentityBindingService(familyRestorationService: restorationService)
        let boundIdentity = try bindingService.bind(acceptedWorkspaceId: created.workspace.id, intendedParticipantId: acceptedParticipant.id)

        let participantCountBefore = try parentWorkspaceRepository.fetchAllParticipants().count
        let athleteCountBefore = try athleteRepository.fetchAllAthletes().count
        let workspaceCountBefore = try parentWorkspaceRepository.fetchAllWorkspaces().count

        let activationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        let actor = try activationService.activate(boundIdentity: boundIdentity)

        #expect(actor.participantId == acceptedParticipant.id)
        #expect(actor.workspaceId == created.workspace.workspaceId)
        #expect(actor.role == .athlete)
        #expect(actor.linkedAthleteId == created.athlete.athleteId)

        #expect(try parentWorkspaceRepository.fetchAllParticipants().count == participantCountBefore)
        #expect(try athleteRepository.fetchAllAthletes().count == athleteCountBefore)
        #expect(try parentWorkspaceRepository.fetchAllWorkspaces().count == workspaceCountBefore)

        // Re-fetch the persisted participant directly and confirm its
        // own state is unchanged by activation — still exactly what
        // AcceptWorkspaceInvitationService left it as.
        let refetched = try parentWorkspaceRepository.fetchAllParticipants().first { $0.id == acceptedParticipant.id }
        #expect(refetched?.state == .active)
        #expect(refetched?.acceptedAt == acceptedParticipant.acceptedAt)
    }
}
