import Testing
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrParentDomain
@testable import VoxtrAppShell

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("AthleteFamilyManagementService (Multi-Athlete Family Foundation)", .serialized)
struct AthleteFamilyManagementServiceTests {

    @Test("addAthlete creates a genuinely new AthleteProfile and its own AthleteAccessGrant")
    @MainActor
    func addAthleteCreatesNewProfileAndGrant() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        let service = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )

        let added = try service.addAthlete(
            workspaceId: staged.workspace.workspaceId,
            participantId: staged.participant.id,
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )

        #expect(added.athlete.givenName == "Jonas")
        #expect(added.grant.athleteId == added.athlete.id)
        #expect(added.grant.participantId == staged.participant.id)
        #expect(try athleteRepository.fetchAllAthletes().count == 1)
    }

    @Test("Adding a second athlete does not affect the first")
    @MainActor
    func addingSecondAthleteDoesNotAffectFirst() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        let service = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let first = try service.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Jonas", birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        let second = try service.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Emma", birthDate: LocalDate(year: 2014, month: 6, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        #expect(first.athlete.id != second.athlete.id)
        let allAthletes = try athleteRepository.fetchAllAthletes()
        #expect(allAthletes.count == 2)
        let refetchedFirst = try athleteRepository.fetchAthlete(byId: first.athlete.athleteId)
        #expect(refetchedFirst?.givenName == "Jonas")
    }

    @Test("editAthlete updates only the targeted athlete, leaving another athlete's fields untouched")
    @MainActor
    func editAthleteDoesNotAffectAnother() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        let service = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let first = try service.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Jonas", birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let second = try service.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Emma", birthDate: LocalDate(year: 2014, month: 6, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        _ = try service.editAthlete(
            first.athlete.athleteId,
            expectedRevision: first.athlete.revision,
            givenName: "Jonas Updated",
            familyName: nil,
            preferredName: nil,
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .sharedOwnership
        )

        let refetchedFirst = try athleteRepository.fetchAthlete(byId: first.athlete.athleteId)
        let refetchedSecond = try athleteRepository.fetchAthlete(byId: second.athlete.athleteId)
        #expect(refetchedFirst?.givenName == "Jonas Updated")
        #expect(refetchedFirst?.developmentStage == .sharedOwnership)
        #expect(refetchedSecond?.givenName == "Emma")
        #expect(refetchedSecond?.developmentStage == .parentLed)
    }

    @Test("archiveAthlete archives only the targeted athlete, leaving another athlete active and unchanged")
    @MainActor
    func archiveAthleteDoesNotAffectAnother() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        let service = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let first = try service.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Jonas", birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let second = try service.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Emma", birthDate: LocalDate(year: 2014, month: 6, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        _ = try service.archiveAthlete(first.athlete.athleteId, expectedRevision: first.athlete.revision)

        let refetchedFirst = try athleteRepository.fetchAthlete(byId: first.athlete.athleteId)
        let refetchedSecond = try athleteRepository.fetchAthlete(byId: second.athlete.athleteId)
        #expect(refetchedFirst?.isArchived == true)
        #expect(refetchedSecond?.isArchived == false)
        // The archived athlete's row and grant both still exist —
        // "delete" never removes anything (see the service's own doc
        // comment for why).
        #expect(try athleteRepository.fetchAllAthletes().count == 2)
        #expect(try athleteAccessGrantRepository.fetchAllGrants().count == 2)
    }

    @Test("A repository/save failure during addAthlete does not report success, and rolls back completely")
    @MainActor
    func repositoryFailureDuringAddAthleteDoesNotReportSuccess() throws {
        struct InjectedSaveFailure: Error {}

        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        let service = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )

        #expect(throws: InjectedSaveFailure.self) {
            try service.addAthlete(
                workspaceId: staged.workspace.workspaceId,
                participantId: staged.participant.id,
                givenName: "Jonas",
                familyName: nil,
                preferredName: nil,
                birthDate: LocalDate(year: 2012, month: 4, day: 10),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                developmentStage: .parentLed,
                saveOverride: { throw InjectedSaveFailure() }
            )
        }
        // Full rollback — no partial athlete or grant left behind.
        #expect(try athleteRepository.fetchAllAthletes().isEmpty)
        #expect(try athleteAccessGrantRepository.fetchAllGrants().isEmpty)
    }

    @Test("editAthlete rejects a stale revision without mutating the athlete")
    @MainActor
    func editAthleteRejectsStaleRevision() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        let service = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let added = try service.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Jonas", birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        #expect(throws: AthleteProfileConflictError.staleRevision(expected: 99, actual: 1)) {
            try service.editAthlete(
                added.athlete.athleteId, expectedRevision: 99, givenName: "Changed",
                familyName: nil, preferredName: nil, birthDate: added.athlete.birthDate,
                timeZoneId: added.athlete.timeZoneId, developmentStage: added.athlete.developmentStage
            )
        }
        let refetched = try athleteRepository.fetchAthlete(byId: added.athlete.athleteId)
        #expect(refetched?.givenName == "Jonas")
    }

    @Test("archiveAthlete rejects a nonexistent athlete")
    @MainActor
    func archiveAthleteRejectsMissingAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let service = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )

        #expect(throws: AthleteFamilyManagementError.athleteNotFound) {
            try service.archiveAthlete(AthleteId(), expectedRevision: 1)
        }
    }

    @Test("addAthlete rejects an invalid givenName and creates nothing")
    @MainActor
    func addAthleteRejectsInvalidGivenName() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let staged = parentWorkspaceRepository.stageParentAndWorkspace(givenName: "Kari")
        try container.mainContext.save()
        let service = AthleteFamilyManagementService(
            modelContext: container.mainContext,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )

        #expect(throws: AthleteFamilyManagementError.self) {
            try service.addAthlete(
                workspaceId: staged.workspace.workspaceId,
                participantId: staged.participant.id,
                givenName: "",
                birthDate: LocalDate(year: 2012, month: 4, day: 10),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                developmentStage: .parentLed
            )
        }
        #expect(try athleteRepository.fetchAllAthletes().isEmpty)
    }
}
