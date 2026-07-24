import Testing
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrParentDomain
import VoxtrAthleteDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following S1.1's lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline,
// matching the pattern already proven to work in CI.

@Suite("AthleteRepository (S1.2)", .serialized)
struct AthleteRepositoryTests {

    @Test("Creating an athlete persists it with the given fields")
    @MainActor
    func createsAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = AthleteRepository(modelContext: container.mainContext)

        let athlete = try repository.createAthlete(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )

        #expect(athlete.givenName == "Jonas")
        #expect(athlete.developmentStage == .parentLed)
        #expect(athlete.revision == 1)
    }

    @Test("Fetching all athletes returns the created athlete")
    @MainActor
    func fetchAllAthletesReturnsCreated() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = AthleteRepository(modelContext: container.mainContext)
        _ = try repository.createAthlete(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )

        let athletes = try repository.fetchAllAthletes()

        #expect(athletes.count == 1)
        #expect(athletes.first?.givenName == "Jonas")
    }
}

@Suite("AthleteAccessGrantRepository (S1.2)", .serialized)
struct AthleteAccessGrantRepositoryTests {

    @Test("Full access grant sets every permission to true")
    @MainActor
    func createFullAccessGrantSetsAllPermissionsTrue() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = AthleteAccessGrantRepository(modelContext: container.mainContext)

        let grant = try repository.createFullAccessGrant(
            workspaceId: WorkspaceId(),
            participantId: UUID(),
            athleteId: AthleteId()
        )

        #expect(grant.canViewSchedule)
        #expect(grant.canEditDraftPlans)
        #expect(grant.canCommitPlans)
        #expect(grant.canViewSharedReflections)
        #expect(grant.canViewDevelopmentInsights)
    }

    @Test("Fetching grants by athlete ID returns only that athlete's grants")
    @MainActor
    func fetchGrantsForAthleteScopesCorrectly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let firstAthleteId = AthleteId()
        let secondAthleteId = AthleteId()
        _ = try repository.createFullAccessGrant(workspaceId: WorkspaceId(), participantId: UUID(), athleteId: firstAthleteId)
        _ = try repository.createFullAccessGrant(workspaceId: WorkspaceId(), participantId: UUID(), athleteId: secondAthleteId)

        let firstGrants = try repository.fetchGrants(forAthlete: firstAthleteId)

        #expect(firstGrants.count == 1)
    }
}

@Suite("FamilyOnboardingCoordinator (S1.2a: atomicity)", .serialized)
struct FamilyOnboardingCoordinatorTests {

    @Test("Successful onboarding persists all five entities")
    @MainActor
    func successfulOnboardingPersistsAllFive() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )

        let result = try coordinator.createFamily(
            parentGivenName: "Kari",
            athleteGivenName: "Jonas",
            athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
            athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            athleteDevelopmentStage: .parentLed
        )

        #expect(result.parent.givenName == "Kari")
        #expect(result.athlete.givenName == "Jonas")
        #expect(result.athlete.workspaceId == result.workspace.id)
        #expect(result.grant.athleteId == result.athlete.id)
        #expect(result.grant.participantId == result.participant.id)
        #expect(result.grant.canViewSchedule)

        #expect(try container.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<FamilyWorkspace>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<WorkspaceParticipant>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteAccessGrant>()).count == 1)
    }

    @Test("No WorkspaceParticipant is created for the athlete — only the parent gets one")
    @MainActor
    func onlyParentGetsWorkspaceParticipant() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )
        _ = try coordinator.createFamily(
            parentGivenName: "Kari",
            athleteGivenName: "Jonas",
            athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
            athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            athleteDevelopmentStage: .parentLed
        )

        let allParticipants = try container.mainContext.fetch(FetchDescriptor<WorkspaceParticipant>())

        #expect(allParticipants.count == 1)
        #expect(allParticipants.first?.role == .workspaceOwner)
    }

    @Test("Failure before athlete insertion leaves zero created entities")
    @MainActor
    func failureBeforeAthleteInsertionLeavesZeroEntities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )

        #expect(throws: FamilyOnboardingCoordinator.SimulatedFailure.self) {
            try coordinator.createFamily(
                parentGivenName: "Kari",
                athleteGivenName: "Jonas",
                athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
                athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                athleteDevelopmentStage: .parentLed,
                failAt: .afterParentAndWorkspaceStaged
            )
        }

        #expect(try container.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<FamilyWorkspace>()).count == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<WorkspaceParticipant>()).count == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteAccessGrant>()).count == 0)
    }

    @Test("Failure before grant insertion leaves zero created entities")
    @MainActor
    func failureBeforeGrantInsertionLeavesZeroEntities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )

        #expect(throws: FamilyOnboardingCoordinator.SimulatedFailure.self) {
            try coordinator.createFamily(
                parentGivenName: "Kari",
                athleteGivenName: "Jonas",
                athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
                athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                athleteDevelopmentStage: .parentLed,
                failAt: .afterAthleteStaged
            )
        }

        #expect(try container.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<FamilyWorkspace>()).count == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<WorkspaceParticipant>()).count == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteAccessGrant>()).count == 0)
    }

    @Test("A genuine save failure (SwiftData uniqueness violation) leaves zero created entities")
    @MainActor
    func genuineSaveFailureLeavesZeroEntities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )

        // Pre-persist a ParentProfile with a known ID, saved and
        // committed on its own — this is NOT part of the operation
        // under test, it exists purely to force a genuine uniqueness
        // collision at the coordinator's save() call below.
        let collidingId = UUID()
        _ = parentWorkspaceRepository.stageParentAndWorkspace(parentId: collidingId, givenName: "Existing")
        try container.mainContext.save()

        #expect(throws: (any Error).self) {
            try coordinator.createFamily(
                parentGivenName: "Kari",
                athleteGivenName: "Jonas",
                athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
                athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                athleteDevelopmentStage: .parentLed,
                failAt: nil,
                forcedParentId: collidingId
            )
        }

        // Only the pre-existing "Existing" parent remains — the
        // coordinator's attempted parent, plus the athlete and grant it
        // would have created, must all have been rolled back.
        let parents = try container.mainContext.fetch(FetchDescriptor<ParentProfile>())
        #expect(parents.count == 1)
        #expect(parents.first?.givenName == "Existing")
        #expect(try container.mainContext.fetch(FetchDescriptor<FamilyWorkspace>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<WorkspaceParticipant>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteAccessGrant>()).count == 0)
    }

    @Test("Retry after a rolled-back failure succeeds, with no duplicate records left behind")
    @MainActor
    func retryAfterRollbackSucceedsWithNoDuplicates() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )

        #expect(throws: FamilyOnboardingCoordinator.SimulatedFailure.self) {
            try coordinator.createFamily(
                parentGivenName: "Kari",
                athleteGivenName: "Jonas",
                athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
                athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                athleteDevelopmentStage: .parentLed,
                failAt: .afterGrantStaged
            )
        }

        // Retry with the same coordinator instance, same context — the
        // failed attempt's staged-but-rolled-back objects must not
        // interfere with this succeeding.
        let result = try coordinator.createFamily(
            parentGivenName: "Kari",
            athleteGivenName: "Jonas",
            athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
            athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            athleteDevelopmentStage: .parentLed
        )

        #expect(result.parent.givenName == "Kari")
        #expect(try container.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<FamilyWorkspace>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<WorkspaceParticipant>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteAccessGrant>()).count == 1)
    }
}
