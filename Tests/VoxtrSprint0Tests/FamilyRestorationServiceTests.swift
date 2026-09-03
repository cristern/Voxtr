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
        #expect(restored.athletes.first?.givenName == "Jonas")
        #expect(restored.participant.role == .workspaceOwner)
        #expect(restored.grants.first?.canViewSchedule == true)
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

    @Test("Parent, workspace, and participant with zero athletes restores to existingFamily with an empty athletes array — Multi-Athlete Family Foundation's own required behavior, not an error")
    @MainActor
    func zeroAthletesRestoresToExistingFamilyWithEmptyAthletes() throws {
        // Before Multi-Athlete Family Foundation, this exact scenario
        // (parent/workspace/participant present, zero athletes) was
        // asserted as .inconsistentGraph — that assertion embodied the
        // single-athlete assumption this work package explicitly
        // corrects. "The family must never become locked" requires
        // this to be a valid, working .existingFamily state instead —
        // e.g. every athlete has been archived and deleted, or the
        // parent has not added one yet.
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        _ = try parentWorkspaceRepository.createParentAndWorkspace(givenName: "Kari")

        let service = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )
        let state = try service.restoreState()

        guard case .existingFamily(let restored) = state else {
            Issue.record("Expected .existingFamily, got \(state)")
            return
        }
        #expect(restored.athletes.isEmpty)
        #expect(restored.activeAthletes.isEmpty)
        #expect(restored.grants.isEmpty)
    }

    @Test("A family with multiple athletes restores to existingFamily with every athlete and its matching grant")
    @MainActor
    func multipleAthletesRestoreToExistingFamily() throws {
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
        let managementService = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        _ = try managementService.addAthlete(
            workspaceId: created.workspace.workspaceId,
            participantId: created.participant.id,
            givenName: "Emma",
            birthDate: LocalDate(year: 2014, month: 6, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
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
        #expect(restored.athletes.count == 2)
        #expect(restored.activeAthletes.count == 2)
        #expect(restored.grants.count == 2)
        #expect(Set(restored.athletes.map(\.givenName)) == ["Jonas", "Emma"])
    }

    @Test("Athletes restore in a deterministic order (createdAt, then id as a tiebreaker) across repeated restoration calls")
    @MainActor
    func athletesRestoreInDeterministicOrder() throws {
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
        let managementService = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        _ = try managementService.addAthlete(
            workspaceId: created.workspace.workspaceId, participantId: created.participant.id,
            givenName: "Emma", birthDate: LocalDate(year: 2014, month: 6, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        _ = try managementService.addAthlete(
            workspaceId: created.workspace.workspaceId, participantId: created.participant.id,
            givenName: "Oliver", birthDate: LocalDate(year: 2016, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        let service = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        guard case .existingFamily(let first) = try service.restoreState(),
              case .existingFamily(let second) = try service.restoreState() else {
            Issue.record("Expected .existingFamily on both calls")
            return
        }

        #expect(first.athletes.map(\.givenName) == ["Jonas", "Emma", "Oliver"])
        #expect(first.athletes.map(\.id) == second.athletes.map(\.id))
    }

    @Test("An athlete missing its grant (grant/athlete count mismatch) is inconsistentGraph")
    @MainActor
    func athleteMissingGrantIsInconsistent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)

        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        // An athlete with no corresponding grant at all.
        _ = athleteRepository.stageAthlete(
            workspaceId: staged.workspace.workspaceId,
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
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
        #expect(reason.contains("AthleteAccessGrant per AthleteProfile"))
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

    // MARK: - Athlete Connection Foundation A: multi-participant restoration

    @Test("A family with one active Athlete participant restores successfully, exposing it via athleteParticipants while the workspace-owner participant is unchanged")
    @MainActor
    func familyWithOneActiveAthleteParticipantRestoresSuccessfully() throws {
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
        let athleteParticipant = try parentWorkspaceRepository.createInvitedAthleteParticipant(
            workspaceId: created.workspace.workspaceId,
            linkedAthleteId: created.athlete.athleteId,
            invitedBy: ActorId(rawValue: created.participant.id)
        )
        try parentWorkspaceRepository.acceptInvitation(athleteParticipant)

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
        #expect(restored.participant.role == .workspaceOwner)
        #expect(restored.athleteParticipants.count == 1)
        #expect(restored.athleteParticipants.first?.role == .athlete)
        #expect(restored.athleteParticipants.first?.linkedAthleteId == created.athlete.id)
        #expect(restored.athleteParticipants.first?.state == .active)
    }

    @Test("A family with multiple AthleteProfiles but only some connected to an Athlete participant restores successfully")
    @MainActor
    func familyWithPartiallyConnectedAthletesRestoresSuccessfully() throws {
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
        let managementService = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        // Emma has NO Athlete participant — a Parent-only athlete
        // coexisting with a connected one in the same family.
        _ = try managementService.addAthlete(
            workspaceId: created.workspace.workspaceId, participantId: created.participant.id,
            givenName: "Emma", birthDate: LocalDate(year: 2014, month: 6, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        // Jonas IS connected.
        let athleteParticipant = try parentWorkspaceRepository.createInvitedAthleteParticipant(
            workspaceId: created.workspace.workspaceId,
            linkedAthleteId: created.athlete.athleteId,
            invitedBy: ActorId(rawValue: created.participant.id)
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
        #expect(restored.athletes.count == 2)
        #expect(restored.athleteParticipants.count == 1)
        #expect(restored.athleteParticipants.first?.id == athleteParticipant.id)
        // Emma's own AthleteProfile is present but has no participant
        // representing her — a valid Parent-only athlete.
        let emma = restored.athletes.first { $0.givenName == "Emma" }
        #expect(emma != nil)
        #expect(!restored.athleteParticipants.contains { $0.linkedAthleteId == emma?.id })
    }

    @Test("An Athlete participant linked to a nonexistent AthleteProfile is inconsistentGraph")
    @MainActor
    func athleteParticipantLinkedToNonexistentProfileIsInconsistent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)

        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        // linkedAthleteId points at an AthleteProfile that was never created.
        _ = try parentWorkspaceRepository.createInvitedAthleteParticipant(
            workspaceId: staged.workspace.workspaceId,
            linkedAthleteId: AthleteId(),
            invitedBy: ActorId(rawValue: staged.participant.id)
        )

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
        #expect(reason.contains("linkedAthleteId does not match any AthleteProfile"))
    }

    @Test("An Athlete participant linked to an AthleteProfile in a different workspace is inconsistentGraph — caught by the existing AthleteProfile.workspaceId rule, since any such profile is necessarily present in the same unscoped athletes fetch that rule already validates")
    @MainActor
    func athleteParticipantLinkedAcrossWorkspacesIsInconsistent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)

        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        // The athlete belongs to a DIFFERENT, unrelated workspace —
        // simulating a corrupted or cross-family record.
        let athlete = athleteRepository.stageAthlete(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )
        try container.mainContext.save()
        _ = try parentWorkspaceRepository.createInvitedAthleteParticipant(
            workspaceId: staged.workspace.workspaceId,
            linkedAthleteId: athlete.athleteId,
            invitedBy: ActorId(rawValue: staged.participant.id)
        )

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

    @Test("Two workspace-owner participants (a corrupted graph) is inconsistentGraph, never silently accepted")
    @MainActor
    func multipleWorkspaceOwnerParticipantsIsInconsistent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)

        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        // A second, corrupted workspaceOwner participant in the SAME workspace.
        let second = WorkspaceParticipant(
            workspaceId: staged.workspace.workspaceId, accountId: .pending,
            role: .workspaceOwner, state: .active, invitedAt: .now, acceptedAt: .now
        )
        container.mainContext.insert(second)
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
        #expect(reason.contains("exactly one workspace-owner participant"))
    }
}
