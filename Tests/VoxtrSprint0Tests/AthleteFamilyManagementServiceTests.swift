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

    // MARK: - Archive / Reactivate lifecycle

    /// Guarantees 1, 2, 3, 4: an active athlete can be archived; the
    /// archived row remains fetchable by its stable `AthleteId`; it is
    /// excluded from the canonical active-athlete roster (the same
    /// `!isArchived` filter `FamilyHomeViewModel.refreshActiveAthletes()`/
    /// `ParentTabShellView`'s tab roots/`AthleteFamilyManagementViewModel.loadAthletes()`
    /// all apply over `fetchAthletes(forWorkspace:)`); and it remains
    /// present in the full/manage-athletes query (`fetchAthletes(forWorkspace:)`
    /// itself, unfiltered).
    @Test("An active athlete can be archived; the archived row is fetchable by id, excluded from the active-roster filter, and still present in the full roster")
    @MainActor
    func archivedAthleteIsFetchableExcludedFromActiveIncludedInFullRoster() throws {
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
        #expect(added.athlete.isArchived == false)

        _ = try service.archiveAthlete(added.athlete.athleteId, expectedRevision: added.athlete.revision)

        let fetchedById = try athleteRepository.fetchAthlete(byId: added.athlete.athleteId)
        #expect(fetchedById?.isArchived == true)

        let fullRoster = try athleteRepository.fetchAthletes(forWorkspace: staged.workspace.workspaceId)
        #expect(fullRoster.contains { $0.athleteId == added.athlete.athleteId })

        let activeRoster = fullRoster.filter { !$0.isArchived }
        #expect(!activeRoster.contains { $0.athleteId == added.athlete.athleteId })
    }

    /// Guarantees 5, 6, 7, 10: an archived athlete can be reactivated;
    /// the SAME stable `AthleteId` is preserved across the archive/
    /// reactivate cycle; the reactivated athlete returns to the
    /// canonical active-athlete roster filter; and no duplicate
    /// `AthleteProfile` row is ever created (the roster count is
    /// unchanged throughout).
    @Test("An archived athlete can be reactivated, preserving the same AthleteId, returning to the active-roster filter, with no duplicate row created")
    @MainActor
    func reactivateAthleteRestoresActiveRosterMembershipWithoutDuplication() throws {
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
        let originalAthleteId = added.athlete.athleteId
        let archived = try service.archiveAthlete(originalAthleteId, expectedRevision: added.athlete.revision)
        #expect(try athleteRepository.fetchAllAthletes().count == 1)

        let reactivated = try service.reactivateAthlete(originalAthleteId, expectedRevision: archived.revision)

        #expect(reactivated.athleteId == originalAthleteId)
        #expect(reactivated.isArchived == false)
        #expect(try athleteRepository.fetchAllAthletes().count == 1)
        let activeRoster = try athleteRepository.fetchAthletes(forWorkspace: staged.workspace.workspaceId)
            .filter { !$0.isArchived }
        #expect(activeRoster.map(\.athleteId) == [originalAthleteId])
    }

    /// Guarantee 9 (extended to the full archive/reactivate cycle):
    /// archiving and reactivating one athlete never touches a sibling
    /// athlete's `isArchived` state.
    @Test("Archiving and reactivating one athlete does not affect a sibling athlete")
    @MainActor
    func archiveAndReactivateDoesNotAffectSibling() throws {
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

        let archivedFirst = try service.archiveAthlete(first.athlete.athleteId, expectedRevision: first.athlete.revision)
        _ = try service.reactivateAthlete(first.athlete.athleteId, expectedRevision: archivedFirst.revision)

        let refetchedSecond = try athleteRepository.fetchAthlete(byId: second.athlete.athleteId)
        #expect(refetchedSecond?.isArchived == false)
        #expect(refetchedSecond?.revision == 1)
    }

    /// Guarantee 11: the archive/reactivate mutation changes only
    /// `isArchived` (plus the required `revision`/`updatedAt` lifecycle
    /// metadata `applyMutation` always advances) — every other profile
    /// field, and the athlete's own `AthleteSettings` row (Sleep
    /// tracking, preferred Color), survive completely untouched. This is
    /// the data-safety guarantee for historical/linked configuration:
    /// archive/reactivate never reads or writes any table other than
    /// this one `AthleteProfile` row.
    @Test("archiveAthlete/reactivateAthlete change only isArchived and lifecycle metadata, leaving every other profile field and the athlete's AthleteSettings untouched")
    @MainActor
    func archiveAndReactivateChangeOnlyLifecycleFieldsAndPreserveSettings() throws {
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
            givenName: "Jonas", familyName: "Nygren", preferredName: "Jon",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .sharedOwnership
        )
        try athleteRepository.setSleepTrackingEnabled(athleteId: added.athlete.athleteId, enabled: false)
        try athleteRepository.setPreferredColor(athleteId: added.athlete.athleteId, color: .rose)
        let originalRevision = added.athlete.revision

        let archived = try service.archiveAthlete(added.athlete.athleteId, expectedRevision: originalRevision)
        #expect(archived.revision == originalRevision + 1)
        _ = try service.reactivateAthlete(added.athlete.athleteId, expectedRevision: archived.revision)

        let refetched = try athleteRepository.fetchAthlete(byId: added.athlete.athleteId)
        #expect(refetched?.isArchived == false)
        #expect(refetched?.revision == originalRevision + 2)
        #expect(refetched?.givenName == "Jonas")
        #expect(refetched?.familyName == "Nygren")
        #expect(refetched?.preferredName == "Jon")
        #expect(refetched?.birthDate == LocalDate(year: 2012, month: 4, day: 10))
        #expect(refetched?.developmentStage == .sharedOwnership)

        let settings = try athleteRepository.fetchAthleteSettings(forAthlete: added.athlete.athleteId)
        #expect(settings?.sleepTrackingEnabled == false)
        #expect(settings?.preferredColor == .rose)
    }

    @Test("reactivateAthlete rejects a nonexistent athlete")
    @MainActor
    func reactivateAthleteRejectsMissingAthlete() throws {
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
            try service.reactivateAthlete(AthleteId(), expectedRevision: 1)
        }
    }

    @Test("reactivateAthlete rejects a stale revision without mutating the athlete")
    @MainActor
    func reactivateAthleteRejectsStaleRevision() throws {
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
        let archived = try service.archiveAthlete(added.athlete.athleteId, expectedRevision: added.athlete.revision)

        #expect(throws: AthleteProfileConflictError.staleRevision(expected: 99, actual: archived.revision)) {
            try service.reactivateAthlete(added.athlete.athleteId, expectedRevision: 99)
        }
        let refetched = try athleteRepository.fetchAthlete(byId: added.athlete.athleteId)
        #expect(refetched?.isArchived == true)
    }

    /// `AthleteFamilyManagementViewModel.reactivateAthlete(_:)` mirrors
    /// `archiveAthlete(_:)`'s own established shape exactly (see that
    /// method's test above via `viewModelResolvedColorPrefersExplicitOverFallback`'s
    /// ViewModel-construction pattern) — this proves the ViewModel-level
    /// call reaches the same canonical service mutation and refreshes
    /// `athletes` from persistence afterward, the same "re-fetch on
    /// mutation" freshness this screen's own `loadAthletes()` already
    /// establishes for every other mutation.
    @Test("AthleteFamilyManagementViewModel.reactivateAthlete(_:) reactivates through the canonical service path and refreshes athletes")
    @MainActor
    func viewModelReactivateAthleteReachesCanonicalServiceAndRefreshesList() throws {
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
        let viewModel = AthleteFamilyManagementViewModel(
            workspaceId: staged.workspace.workspaceId,
            participantId: staged.participant.id,
            athleteRepository: athleteRepository,
            athleteFamilyManagementService: service
        )
        viewModel.archiveAthlete(added.athlete)
        #expect(viewModel.errorMessage == nil)
        let archivedAthlete = try #require(viewModel.athletes.first { $0.athleteId == added.athlete.athleteId })
        #expect(archivedAthlete.isArchived == true)

        viewModel.reactivateAthlete(archivedAthlete)

        #expect(viewModel.errorMessage == nil)
        let reactivatedAthlete = try #require(viewModel.athletes.first { $0.athleteId == added.athlete.athleteId })
        #expect(reactivatedAthlete.isArchived == false)
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

    /// TestFlight correctness fix (Athlete settings Development Stage):
    /// proves the narrow `setDevelopmentStage` mutation updates only
    /// the targeted athlete's `developmentStage`, leaving every other
    /// profile field on that same athlete untouched — the exact
    /// property the old `editAthlete`-based path could NOT guarantee,
    /// since it resubmitted the whole shared form (including
    /// `givenName`, which is what produced the reported
    /// `"givenName must be 1-80 characters"` runtime error whenever
    /// that shared form state was empty/stale).
    @Test("setDevelopmentStage updates only developmentStage, leaving givenName/familyName/birthDate/preferredName unchanged")
    @MainActor
    func setDevelopmentStageChangesOnlyThatField() throws {
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
            givenName: "Jonas", familyName: "Nygren", preferredName: "Jon",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        let updated = try service.setDevelopmentStage(
            added.athlete.athleteId, expectedRevision: added.athlete.revision,
            developmentStage: .sharedOwnership
        )

        #expect(updated.developmentStage == .sharedOwnership)
        let refetched = try athleteRepository.fetchAthlete(byId: added.athlete.athleteId)
        #expect(refetched?.developmentStage == .sharedOwnership)
        #expect(refetched?.givenName == "Jonas")
        #expect(refetched?.familyName == "Nygren")
        #expect(refetched?.preferredName == "Jon")
        #expect(refetched?.birthDate == LocalDate(year: 2012, month: 4, day: 10))
    }

    /// Proves `setDevelopmentStage` needs no valid local Profile form
    /// state at all — unlike `editAthlete`, which throws
    /// `.invalidField` for an empty `givenName`, an empty/blank
    /// `givenName` string is never even a parameter to this call, so
    /// there is nothing for it to validate or reject.
    @Test("setDevelopmentStage does not require or accept any givenName parameter, and cannot trigger givenName validation")
    @MainActor
    func setDevelopmentStageRequiresNoProfileFormState() throws {
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

        // No givenName is ever supplied here — the old bug required a
        // valid shared-form givenName to reach this far at all. If this
        // throws, the test itself fails (the function is `throws`) —
        // matching this file's own established pattern of calling a
        // success-expected mutation directly with `try`, with no
        // `#expect(throws:)` wrapper.
        let updated = try service.setDevelopmentStage(
            added.athlete.athleteId, expectedRevision: added.athlete.revision,
            developmentStage: .athleteLed
        )
        #expect(updated.developmentStage == .athleteLed)
    }

    @Test("setDevelopmentStage changes only the targeted athlete, leaving another athlete's developmentStage unchanged")
    @MainActor
    func setDevelopmentStageDoesNotAffectAnotherAthlete() throws {
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

        _ = try service.setDevelopmentStage(
            first.athlete.athleteId, expectedRevision: first.athlete.revision,
            developmentStage: .guidedIndependence
        )

        let refetchedFirst = try athleteRepository.fetchAthlete(byId: first.athlete.athleteId)
        let refetchedSecond = try athleteRepository.fetchAthlete(byId: second.athlete.athleteId)
        #expect(refetchedFirst?.developmentStage == .guidedIndependence)
        #expect(refetchedSecond?.developmentStage == .parentLed)
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

    // MARK: - Athlete Color canonical preference (Design Foundation V0.1)

    /// Requirement 1: saving an explicit athlete colour persists for
    /// the correct athlete. Goes straight through
    /// `AthleteRepository.setPreferredColor(athleteId:color:)` — the
    /// same narrow mutation `AthleteFamilyManagementViewModel.setPreferredColor(for:to:)`
    /// calls — and reads back via `fetchAthleteSettings`, mirroring
    /// this file's own established repository-level test shape for
    /// `setDevelopmentStage` above.
    @Test("setPreferredColor persists the explicit colour for the targeted athlete")
    @MainActor
    func setPreferredColorPersistsForTargetedAthlete() throws {
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

        try athleteRepository.setPreferredColor(athleteId: added.athlete.athleteId, color: .rose)

        let settings = try athleteRepository.fetchAthleteSettings(forAthlete: added.athlete.athleteId)
        #expect(settings?.preferredColor == .rose)
    }

    /// Requirement 2: another athlete is unaffected.
    @Test("setPreferredColor changes only the targeted athlete's AthleteSettings, leaving another athlete's colour unaffected")
    @MainActor
    func setPreferredColorDoesNotAffectAnotherAthlete() throws {
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

        try athleteRepository.setPreferredColor(athleteId: first.athlete.athleteId, color: .amber)

        let firstSettings = try athleteRepository.fetchAthleteSettings(forAthlete: first.athlete.athleteId)
        let secondSettings = try athleteRepository.fetchAthleteSettings(forAthlete: second.athlete.athleteId)
        #expect(firstSettings?.preferredColor == .amber)
        // Second athlete has never had any setting touched — no
        // AthleteSettings row exists for them at all yet, same "no row
        // = no explicit preference" shape `sleepTrackingEnabled`
        // already establishes.
        #expect(secondSettings == nil)
    }

    /// Requirement 8: a narrow colour-setting mutation changes only
    /// that setting — proves `setPreferredColor` never touches
    /// `sleepTrackingEnabled` on the SAME `AthleteSettings` row (set
    /// first, via the already-established `setSleepTrackingEnabled`
    /// narrow mutation), and that mutating colour again reuses that
    /// SAME row rather than creating a second one for the athlete (at
    /// most one `AthleteSettings` row per athlete, per this file's own
    /// established invariant for Sleep).
    @Test("setPreferredColor mutates the existing AthleteSettings row in place and never touches sleepTrackingEnabled")
    @MainActor
    func setPreferredColorMutatesExistingRowAndLeavesSleepTrackingUntouched() throws {
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

        try athleteRepository.setSleepTrackingEnabled(athleteId: added.athlete.athleteId, enabled: false)
        try athleteRepository.setPreferredColor(athleteId: added.athlete.athleteId, color: .green)

        let settings = try athleteRepository.fetchAthleteSettings(forAthlete: added.athlete.athleteId)
        #expect(settings?.preferredColor == .green)
        // Sleep tracking, set to Off before colour was ever touched,
        // survives the colour mutation completely unchanged.
        #expect(settings?.sleepTrackingEnabled == false)
        // Exactly one AthleteSettings row exists for this athlete —
        // the colour mutation reused the same row Sleep already
        // created, never inserted a second one.
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteSettings>()).count == 1)

        // And the reverse: mutating Sleep tracking again afterward
        // never resets the colour just set.
        try athleteRepository.setSleepTrackingEnabled(athleteId: added.athlete.athleteId, enabled: true)
        let refetched = try athleteRepository.fetchAthleteSettings(forAthlete: added.athlete.athleteId)
        #expect(refetched?.preferredColor == .green)
        #expect(refetched?.sleepTrackingEnabled == true)
    }

    /// Requirements 3 and 4: `AthleteFamilyManagementViewModel.resolvedColor(for:)`
    /// — explicit preference wins when set, and a `nil`/unset
    /// preference resolves through the stable `AthleteId`-derived
    /// fallback (`AthleteColor.forAthleteId(_:)`), never a hard-coded
    /// default.
    @Test("AthleteFamilyManagementViewModel.resolvedColor(for:) returns the explicit preference when set, otherwise the stable AthleteId fallback")
    @MainActor
    func viewModelResolvedColorPrefersExplicitOverFallback() throws {
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
        // Design Foundation extension round: a second athlete, never
        // given an explicit preference — proves `resolvedColor(for:)`
        // resolves each athlete independently rather than caching or
        // leaking one athlete's explicit choice onto another, now that
        // Manage Athletes' own row marker calls this method directly
        // for every athlete in the roster.
        let secondAdded = try service.addAthlete(
            workspaceId: staged.workspace.workspaceId, participantId: staged.participant.id,
            givenName: "Emma", birthDate: LocalDate(year: 2014, month: 6, day: 2),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let viewModel = AthleteFamilyManagementViewModel(
            workspaceId: staged.workspace.workspaceId,
            participantId: staged.participant.id,
            athleteRepository: athleteRepository,
            athleteFamilyManagementService: service
        )

        // No explicit preference has ever been set for this athlete —
        // resolves through the same deterministic fallback
        // `AthleteColor.forAthleteId(_:)` computes directly.
        #expect(viewModel.resolvedColor(for: added.athlete) == AthleteColor.forAthleteId(added.athlete.athleteId))

        // Explicit preference now wins, even when it differs from the
        // fallback this athlete's id would otherwise resolve to.
        let fallback = AthleteColor.forAthleteId(added.athlete.athleteId)
        let explicit: AthleteColor = AthleteColor.allCases.first { $0 != fallback } ?? .blue
        viewModel.setPreferredColor(for: added.athlete, to: explicit)
        #expect(viewModel.resolvedColor(for: added.athlete) == explicit)

        // Athlete isolation: the second athlete's own resolution is
        // untouched by the first athlete's explicit preference — still
        // resolves to its own stable fallback.
        #expect(viewModel.resolvedColor(for: secondAdded.athlete) == AthleteColor.forAthleteId(secondAdded.athlete.athleteId))
    }
}
