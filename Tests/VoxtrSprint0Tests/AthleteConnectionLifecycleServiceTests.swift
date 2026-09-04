import Testing
import Foundation
import CloudKit
import SwiftData
import VoxtrCoreContracts
@testable import VoxtrAppShell
@testable import VoxtrCore
import VoxtrParentDomain
import VoxtrAthleteDomain

// NOTE: `AthleteConnectionLifecycleService.connect(from: CKShare.Metadata)`
// — the real production entry point — is NEVER exercised here, for the
// exact same reason `FamilyWorkspaceParticipantShareCoordinator
// .resolveAcceptedShare(from:)` itself has no test (see that type's own
// XCTEST-SAFETY doc comment in CloudKitTransportTests.swift): `CKShare
// .Metadata` has no public initializer reachable without a real accepted
// share, so no fixture — fake-backed or otherwise — could ever supply
// one to call `connect(from:)` with. What IS fully tested here is
// `connect(acceptedShare:)`, the B2.3 → B2.4 continuation this service
// exposes once a B2.2 result already exists — an
// `AcceptedFamilyWorkspaceShare`'s own fields (`zoneID`/`rootRecordID`/
// `shareRecordID`) ARE freely constructible local CloudKit value types
// (see that struct's own doc comment), so this fully covers the
// service's actual sequencing/error-wrapping logic. That `connect(from:)`
// stops the chain before ever reaching `connect(acceptedShare:)` on a
// B2.2 failure is a structural guarantee of its own `do`/`catch` +
// early-`throw` control flow, not something a runtime test could
// independently verify without real CloudKit I/O.
//
// Like the other persistence-backed tests in this suite, the tests that
// build a real family via `InMemoryPersistenceController` exercise
// @Model types through actual SwiftData persistence and require the
// Xcode/macOS SwiftData runtime — written but not executed in this
// sandbox.
@Suite("AthleteConnectionLifecycleService (Athlete Connection Foundation B2.5)", .serialized)
@MainActor
struct AthleteConnectionLifecycleServiceTests {

    private struct Fixture {
        let service: AthleteConnectionLifecycleService
        let parentWorkspaceRepository: ParentWorkspaceRepository
        let athleteRepository: AthleteRepository
        let created: FamilyOnboardingCoordinator.Result
        let acceptedAthleteParticipant: WorkspaceParticipant
    }

    /// Builds a real, canonically-created family with an invited AND
    /// accepted `.athlete` participant — the same fixture shape B2.3/B2.4's
    /// own integration tests use — wired into a real
    /// `AthleteConnectionLifecycleService`.
    private static func makeFixture() throws -> Fixture {
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
            struct UnexpectedAcceptanceResult: Error {}
            throw UnexpectedAcceptanceResult()
        }

        let restorationService = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let identityBindingService = AthleteConnectionIdentityBindingService(familyRestorationService: restorationService)
        let sessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        // Never actually exercised by connect(acceptedShare:) — only
        // required to satisfy AthleteConnectionLifecycleService's own
        // initializer. Constructing CloudKitTransport performs no
        // network I/O (B1's lazy CKContainer realization).
        let participantShareCoordinator = FamilyWorkspaceParticipantShareCoordinator(transport: CloudKitTransport())

        let service = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService
        )

        return Fixture(
            service: service,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            created: created,
            acceptedAthleteParticipant: acceptedParticipant
        )
    }

    private static func makeAcceptedShare(workspaceId: UUID) -> AcceptedFamilyWorkspaceShare {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        return AcceptedFamilyWorkspaceShare(
            workspaceId: workspaceId,
            zoneID: zoneID,
            rootRecordID: CKRecord.ID(recordName: "test-root", zoneID: zoneID),
            shareRecordID: CKRecord.ID(recordName: "test-share", zoneID: zoneID)
        )
    }

    // MARK: - 1/5/6: successful sequence

    @Test("connect(acceptedShare:) sequences B2.3 -> B2.4 and returns exactly B2.4's own CurrentSessionActor, creating/mutating nothing")
    func successfulSequenceProducesCanonicalActor() throws {
        let fixture = try makeFixture()
        let accepted = Self.makeAcceptedShare(workspaceId: fixture.created.workspace.id)

        let participantCountBefore = try fixture.parentWorkspaceRepository.fetchAllParticipants().count
        let athleteCountBefore = try fixture.athleteRepository.fetchAllAthletes().count
        let workspaceCountBefore = try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count

        let actor = try fixture.service.connect(acceptedShare: accepted)

        #expect(actor.participantId == fixture.acceptedAthleteParticipant.id)
        #expect(actor.workspaceId == fixture.created.workspace.workspaceId)
        #expect(actor.role == .athlete)
        #expect(actor.linkedAthleteId == fixture.created.athlete.athleteId)

        #expect(try fixture.parentWorkspaceRepository.fetchAllParticipants().count == participantCountBefore)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == athleteCountBefore)
        #expect(try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count == workspaceCountBefore)
    }

    // MARK: - 3: B2.3 failure stops before activation

    @Test("connect(acceptedShare:) wraps a B2.3 (identity binding) failure as identityBindingFailed and never reaches B2.4")
    func identityBindingFailureStopsChain() throws {
        // No family exists at all on this device's persistence, so B2.3
        // fails with workspaceNotFound before B2.4 is ever invoked.
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let restorationService = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let identityBindingService = AthleteConnectionIdentityBindingService(familyRestorationService: restorationService)
        let sessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        let participantShareCoordinator = FamilyWorkspaceParticipantShareCoordinator(transport: CloudKitTransport())
        let service = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService
        )
        let accepted = Self.makeAcceptedShare(workspaceId: UUID())

        do {
            _ = try service.connect(acceptedShare: accepted)
            Issue.record("Expected connect(acceptedShare:) to throw")
        } catch let error as AthleteConnectionLifecycleError {
            guard case .identityBindingFailed = error else {
                Issue.record("Expected .identityBindingFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - 4: B2.4 failure surfaces correctly

    @Test("connect(acceptedShare:) wraps a B2.4 (session activation) failure as sessionActivationFailed after B2.3 already succeeded")
    func sessionActivationFailureSurfacesCorrectly() throws {
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
        // Invited, but never accepted — B2.3 still succeeds (the
        // participant exists and links correctly), but B2.4 fails with
        // participantNotActive since it is still .invited.
        _ = try parentWorkspaceRepository.createInvitedAthleteParticipant(
            workspaceId: created.workspace.workspaceId,
            linkedAthleteId: created.athlete.athleteId,
            invitedBy: ownerActorId
        )

        let restorationService = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let identityBindingService = AthleteConnectionIdentityBindingService(familyRestorationService: restorationService)
        let sessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        let participantShareCoordinator = FamilyWorkspaceParticipantShareCoordinator(transport: CloudKitTransport())
        let service = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService
        )
        let accepted = Self.makeAcceptedShare(workspaceId: created.workspace.id)

        do {
            _ = try service.connect(acceptedShare: accepted)
            Issue.record("Expected connect(acceptedShare:) to throw")
        } catch let error as AthleteConnectionLifecycleError {
            guard case .sessionActivationFailed = error else {
                Issue.record("Expected .sessionActivationFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - 6: no alternative identity created

    @Test("A failed connect(acceptedShare:) attempt creates/mutates nothing")
    func failedAttemptCreatesNothing() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let restorationService = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let identityBindingService = AthleteConnectionIdentityBindingService(familyRestorationService: restorationService)
        let sessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        let participantShareCoordinator = FamilyWorkspaceParticipantShareCoordinator(transport: CloudKitTransport())
        let service = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService
        )
        let accepted = Self.makeAcceptedShare(workspaceId: UUID())

        let participantCountBefore = try parentWorkspaceRepository.fetchAllParticipants().count
        let athleteCountBefore = try athleteRepository.fetchAllAthletes().count
        let workspaceCountBefore = try parentWorkspaceRepository.fetchAllWorkspaces().count

        _ = try? service.connect(acceptedShare: accepted)

        #expect(try parentWorkspaceRepository.fetchAllParticipants().count == participantCountBefore)
        #expect(try athleteRepository.fetchAllAthletes().count == athleteCountBefore)
        #expect(try parentWorkspaceRepository.fetchAllWorkspaces().count == workspaceCountBefore)
    }
}
