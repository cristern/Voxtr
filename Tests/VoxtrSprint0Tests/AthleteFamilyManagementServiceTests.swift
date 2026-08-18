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

    /// TestFlight IA correction (Athlete configuration hub): the hub's
    /// read-only Profile card shows values read directly off the same
    /// `AthleteProfile` reference it was handed — no separate ViewModel
    /// copy of Name/Family name/Birth date to go stale. This proves the
    /// mechanism that claim depends on: `editAthlete` fetches by id and
    /// mutates that fetched object in place (`applyMutation`), and
    /// returns that SAME instance — never a detached copy — so any
    /// caller still holding the pre-edit reference sees the update with
    /// no manual reload.
    @Test("editAthlete mutates the SAME AthleteProfile instance in place, not a detached copy")
    @MainActor
    func editAthleteMutatesSameInstanceInPlace() throws {
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
        let originalInstance = added.athlete

        let updated = try service.editAthlete(
            added.athlete.athleteId, expectedRevision: added.athlete.revision,
            givenName: "Jonas Updated", familyName: "Nygren", preferredName: nil,
            birthDate: added.athlete.birthDate, timeZoneId: added.athlete.timeZoneId,
            developmentStage: added.athlete.developmentStage
        )

        #expect(updated === originalInstance)
        #expect(originalInstance.givenName == "Jonas Updated")
        #expect(originalInstance.familyName == "Nygren")
    }

    /// Preferred name simplification round: `AthleteProfile.preferredName`
    /// is a persisted field the Edit Athlete UI no longer displays or
    /// edits — but `AthleteFamilyManagementViewModel.prefill(from:)`
    /// still captures an existing athlete's `preferredName` into its
    /// own form state, and `editAthlete` still resubmits whatever that
    /// state holds. This test proves the resulting round trip an edit
    /// with no preferredName control actually performs: an existing
    /// persisted preferredName survives an edit of the OTHER fields
    /// completely unchanged — this simplification never silently
    /// erases previously stored data.
    @Test("Editing an athlete's other fields, with preferredName resubmitted unchanged, preserves its existing persisted value")
    @MainActor
    func editingProfileWithoutTouchingPreferredNamePreservesIt() throws {
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
            givenName: "Jonas", preferredName: "Jon",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        #expect(added.athlete.preferredName == "Jon")

        _ = try service.editAthlete(
            added.athlete.athleteId, expectedRevision: added.athlete.revision,
            givenName: "Jonas Updated", familyName: nil, preferredName: "Jon",
            birthDate: added.athlete.birthDate, timeZoneId: added.athlete.timeZoneId,
            developmentStage: added.athlete.developmentStage
        )

        let refetched = try athleteRepository.fetchAthlete(byId: added.athlete.athleteId)
        #expect(refetched?.preferredName == "Jon")
        #expect(refetched?.givenName == "Jonas Updated")
    }

    /// TestFlight IA correction: `AthleteBirthDateFormatter` is the one
    /// new pure formatting function this round adds, for the
    /// configuration hub's read-only Profile card — deterministic, no
    /// persistence/UI needed to verify it directly.
    @Test("AthleteBirthDateFormatter formats a birth date as 'D Month YYYY'")
    func birthDateFormatterProducesDayMonthYear() {
        #expect(AthleteBirthDateFormatter.label(for: LocalDate(year: 2013, month: 5, day: 12)) == "12 May 2013")
        #expect(AthleteBirthDateFormatter.label(for: LocalDate(year: 2020, month: 1, day: 1)) == "1 January 2020")
        #expect(AthleteBirthDateFormatter.label(for: LocalDate(year: 2019, month: 12, day: 31)) == "31 December 2019")
    }
}
