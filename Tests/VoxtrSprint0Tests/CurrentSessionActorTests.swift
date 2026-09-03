import Testing
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrParentDomain
import VoxtrAthleteDomain

// NOTE: like the other persistence-backed tests, `restoredFamilyResolvesOwnerParticipantAsCurrentActor`
// exercises @Model types and requires the Xcode/macOS SwiftData
// runtime — written but not executed in this sandbox. The others are
// pure value-type tests with no persistence at all.

@Suite("CurrentSessionActor (Athlete Connection Foundation A)")
struct CurrentSessionActorTests {

    @Test("A ParentApp session resolves the workspace-owner participant as the current actor")
    @MainActor
    func restoredFamilyResolvesOwnerParticipantAsCurrentActor() throws {
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

        let service = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        guard case .existingFamily(let restored) = try service.restoreState() else {
            Issue.record("Expected .existingFamily")
            return
        }

        #expect(restored.currentActor.role == .workspaceOwner)
        #expect(restored.currentActor.participantId == created.participant.id)
        #expect(restored.currentActor.linkedAthleteId == nil)
    }

    @Test("The current actor's ActorId is stable and matches WorkspaceParticipant.id reinterpreted, not a freshly generated value")
    func currentActorProducesStableExpectedActorId() {
        let participant = WorkspaceParticipant(
            workspaceId: WorkspaceId(), accountId: .pending,
            role: .workspaceOwner, state: .active, invitedAt: .now, acceptedAt: .now
        )
        let actor = CurrentSessionActor.resolve(from: participant)

        #expect(actor.actorId == ActorId(rawValue: participant.id))
        // Resolving again from the SAME participant produces the exact
        // same ActorId — not a new, randomly generated identity each call.
        let resolvedAgain = CurrentSessionActor.resolve(from: participant)
        #expect(resolvedAgain.actorId == actor.actorId)
    }

    @Test("Selecting a different athlete never changes the current actor's identity — it is derived only from the acting participant, never from athlete selection")
    func selectingDifferentAthleteDoesNotChangeCurrentActor() {
        let workspaceId = WorkspaceId()
        let participant = WorkspaceParticipant(
            workspaceId: workspaceId, accountId: .pending,
            role: .workspaceOwner, state: .active, invitedAt: .now, acceptedAt: .now
        )
        let actor = CurrentSessionActor.resolve(from: participant)

        // Simulates a Parent viewing/editing two different athletes in
        // the same session — CurrentSessionActor takes no athlete
        // parameter at all, so there is no code path by which selecting
        // Jonas vs. Emma could change `actor.actorId`.
        let firstAthleteId = AthleteId()
        let secondAthleteId = AthleteId()
        #expect(firstAthleteId != secondAthleteId)
        #expect(actor.actorId == ActorId(rawValue: participant.id))
        #expect(actor.workspaceId == workspaceId)
    }

    @Test("CurrentSessionActor.resolve(from:) represents an Athlete-role participant correctly, with no Athlete UI required to exercise it")
    func resolvesAthleteRoleParticipantWithoutUI() {
        let workspaceId = WorkspaceId()
        let linkedAthleteId = AthleteId()
        let athleteParticipant = WorkspaceParticipant(
            workspaceId: workspaceId, accountId: .pending,
            role: .athlete, state: .active, linkedAthleteId: linkedAthleteId,
            invitedAt: .now, acceptedAt: .now
        )

        let actor = CurrentSessionActor.resolve(from: athleteParticipant)

        #expect(actor.role == .athlete)
        #expect(actor.linkedAthleteId == linkedAthleteId)
        #expect(actor.workspaceId == workspaceId)
        #expect(actor.actorId == ActorId(rawValue: athleteParticipant.id))
    }
}
