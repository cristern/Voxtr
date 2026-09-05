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
// `connect(acceptedShare:)`, the hydration → acceptance → B2.3 → B2.4
// continuation this service exposes once a B2.2 result already exists —
// an `AcceptedFamilyWorkspaceShare`'s own fields ARE freely constructible
// local CloudKit value types (see that struct's own doc comment), so
// this fully covers the service's actual sequencing/error-wrapping
// logic. That `connect(from:)` stops the chain before ever reaching
// `connect(acceptedShare:)` on a B2.2 failure is a structural guarantee
// of its own `do`/`catch` + early-`throw` control flow, not something a
// runtime test could independently verify without real CloudKit I/O.
//
// Like the other persistence-backed tests in this suite, the tests that
// build a real family via `InMemoryPersistenceController` exercise
// @Model types through actual SwiftData persistence and require the
// Xcode/macOS SwiftData runtime — written but not executed in this
// sandbox.
@Suite("AthleteConnectionLifecycleService (Athlete Connection Foundation B2.5/B2.6, PR #68 follow-up)", .serialized)
@MainActor
struct AthleteConnectionLifecycleServiceTests {

    private struct Fixture {
        // Retained for the fixture's entire lifetime — see this file's
        // own established precedent (a factory function that hands the
        // container back out must keep it alive, or SwiftData
        // invalidates every @Model instance fetched through it).
        let container: ModelContainer
        let service: AthleteConnectionLifecycleService
        let parentWorkspaceRepository: ParentWorkspaceRepository
        let athleteRepository: AthleteRepository
        let athleteAccessGrantRepository: AthleteAccessGrantRepository
        // Snapshotted stable IDs rather than the managed `@Model`
        // instances themselves — the test only ever needs identity
        // values for comparison, not continued live access to the
        // objects.
        let workspaceRawId: UUID
        let expectedParticipantId: UUID
        let expectedWorkspaceId: WorkspaceId
        let expectedAthleteId: AthleteId
        let hydrationPayload: AthleteConnectionInvitationCloudRecordPayload
    }

    private static func makeIdentityHydrationService(
        container: ModelContainer,
        parentWorkspaceRepository: ParentWorkspaceRepository,
        athleteRepository: AthleteRepository,
        athleteAccessGrantRepository: AthleteAccessGrantRepository
    ) -> AthleteIdentityHydrationService {
        AthleteIdentityHydrationService(
            modelContext: container.mainContext,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
    }

    /// A completely independent, freshly-generated hydration payload —
    /// no relationship to any locally-persisted state. Used by the
    /// "fresh device" tests, which prove the FULL chain succeeds purely
    /// from this transported projection, with NOTHING pre-existing
    /// locally.
    private static func makeFreshHydrationPayload(
        workspaceId: UUID = UUID(),
        intendedParticipantId: UUID = UUID(),
        intendedAthleteId: UUID = UUID(),
        parentId: UUID = UUID(),
        ownerParticipantId: UUID = UUID(),
        athleteGivenName: String = "Jonas"
    ) -> AthleteConnectionInvitationCloudRecordPayload {
        AthleteConnectionInvitationCloudRecordPayload(
            workspaceId: workspaceId,
            intendedParticipantId: intendedParticipantId,
            intendedAthleteId: intendedAthleteId,
            parentId: parentId,
            parentGivenName: "Kari",
            workspaceDisplayName: "Kari's family",
            ownerParticipantId: ownerParticipantId,
            athleteGivenName: athleteGivenName,
            athleteBirthDateISO: LocalDate(year: 2012, month: 4, day: 10).isoString,
            athleteTimeZoneId: "Europe/Oslo",
            athleteDevelopmentStage: DevelopmentStage.parentLed.rawValue
        )
    }

    private static func makeAcceptedShare(hydration: AthleteConnectionInvitationCloudRecordPayload) -> AcceptedFamilyWorkspaceShare {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        return AcceptedFamilyWorkspaceShare(
            workspaceId: hydration.workspaceId,
            zoneID: zoneID,
            rootRecordID: CKRecord.ID(recordName: "test-invitation", zoneID: zoneID),
            shareRecordID: CKRecord.ID(recordName: "test-share", zoneID: zoneID),
            intendedParticipantId: hydration.intendedParticipantId,
            intendedAthleteId: hydration.intendedAthleteId,
            hydration: hydration
        )
    }

    /// Builds a real, canonically-created family with an invited AND
    /// accepted `.athlete` participant, wired into a real
    /// `AthleteConnectionLifecycleService` — the "this device already
    /// has this exact family hydrated" case, so the hydration step
    /// exercises its own reuse/no-op path, not creation.
    /// `sessionActivationService` defaults to the real B2.4
    /// implementation; a test proving a GENUINE later B2.4 failure
    /// substitutes a fake conforming to `AthleteSessionActivating`
    /// instead. `preAccept`: when `true` (default), the fixture
    /// pre-accepts the invited participant itself before ever calling
    /// `connect(acceptedShare:)`. When `false`, the fixture leaves the
    /// participant genuinely `.invited` — proving `connect(acceptedShare:)`
    /// itself performs the real `.invited -> .active` transition.
    private static func makeFixture(
        sessionActivationService: AthleteSessionActivating? = nil,
        preAccept: Bool = true
    ) throws -> Fixture {
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
        let invitedParticipant = try parentWorkspaceRepository.createInvitedAthleteParticipant(
            workspaceId: created.workspace.workspaceId,
            linkedAthleteId: created.athlete.athleteId,
            invitedBy: ownerActorId
        )
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: parentWorkspaceRepository,
            eligibilityService: AthleteParticipantEligibilityService()
        )
        let expectedParticipantId: UUID
        if preAccept {
            let acceptanceResult = acceptanceService.accept(
                athleteId: created.athlete.athleteId,
                workspaceId: created.workspace.workspaceId,
                eligibilityFacts: AthleteEligibilityFacts(workspaceId: created.workspace.workspaceId, isArchived: false)
            )
            guard case .accepted(let acceptedParticipant) = acceptanceResult else {
                struct UnexpectedAcceptanceResult: Error {}
                throw UnexpectedAcceptanceResult()
            }
            expectedParticipantId = acceptedParticipant.id
        } else {
            expectedParticipantId = invitedParticipant.id
        }

        let restorationService = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let identityBindingService = AthleteConnectionIdentityBindingService(familyRestorationService: restorationService)
        let identityHydrationService = Self.makeIdentityHydrationService(
            container: container,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let realSessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        // Never actually exercised by connect(acceptedShare:) — only
        // required to satisfy AthleteConnectionLifecycleService's own
        // initializer. Constructing CloudKitTransport performs no
        // network I/O (B1's lazy CKContainer realization).
        let participantShareCoordinator = FamilyWorkspaceParticipantShareCoordinator(transport: CloudKitTransport())

        let service = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            identityHydrationService: identityHydrationService,
            athleteRepository: athleteRepository,
            acceptanceService: acceptanceService,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService ?? realSessionActivationService
        )

        let hydrationPayload = AthleteConnectionInvitationCloudRecordPayload(
            workspaceId: created.workspace.id,
            intendedParticipantId: expectedParticipantId,
            intendedAthleteId: created.athlete.id,
            parentId: created.parent.id,
            parentGivenName: created.parent.givenName,
            workspaceDisplayName: created.workspace.displayName,
            ownerParticipantId: created.participant.id,
            athleteGivenName: created.athlete.givenName,
            athleteBirthDateISO: created.athlete.birthDate.isoString,
            athleteTimeZoneId: created.athlete.timeZoneId.rawValue,
            athleteDevelopmentStage: created.athlete.developmentStage.rawValue
        )

        return Fixture(
            container: container,
            service: service,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository,
            workspaceRawId: created.workspace.id,
            expectedParticipantId: expectedParticipantId,
            expectedWorkspaceId: created.workspace.workspaceId,
            expectedAthleteId: created.athlete.athleteId,
            hydrationPayload: hydrationPayload
        )
    }

    // MARK: - 1/5/6: successful sequence (device already has this family locally)

    @Test("connect(acceptedShare:) sequences hydration (no-op reuse) -> B2.3 -> B2.4 and returns exactly B2.4's own CurrentSessionActor, creating/mutating nothing beyond what already existed")
    func successfulSequenceProducesCanonicalActor() throws {
        let fixture = try Self.makeFixture()
        let accepted = Self.makeAcceptedShare(hydration: fixture.hydrationPayload)

        let participantCountBefore = try fixture.parentWorkspaceRepository.fetchAllParticipants().count
        let athleteCountBefore = try fixture.athleteRepository.fetchAllAthletes().count
        let workspaceCountBefore = try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count
        let grantCountBefore = try fixture.athleteAccessGrantRepository.fetchAllGrants().count

        let actor = try fixture.service.connect(acceptedShare: accepted)

        #expect(actor.participantId == fixture.expectedParticipantId)
        #expect(actor.workspaceId == fixture.expectedWorkspaceId)
        #expect(actor.role == .athlete)
        #expect(actor.linkedAthleteId == fixture.expectedAthleteId)

        #expect(try fixture.parentWorkspaceRepository.fetchAllParticipants().count == participantCountBefore)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == athleteCountBefore)
        #expect(try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count == workspaceCountBefore)
        #expect(try fixture.athleteAccessGrantRepository.fetchAllGrants().count == grantCountBefore)
    }

    // MARK: - PR #68: fresh device, no pre-existing local state at all

    @Test("connect(acceptedShare:) succeeds on a COMPLETELY FRESH device — no ParentProfile/FamilyWorkspace/WorkspaceParticipant/AthleteProfile/AthleteAccessGrant exist locally beforehand — driven purely by the accepted share's own hydration payload")
    func freshDeviceHydratesAndConnectsSuccessfully() throws {
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
        let identityHydrationService = Self.makeIdentityHydrationService(
            container: container,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let sessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: parentWorkspaceRepository,
            eligibilityService: AthleteParticipantEligibilityService()
        )
        let participantShareCoordinator = FamilyWorkspaceParticipantShareCoordinator(transport: CloudKitTransport())
        let service = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            identityHydrationService: identityHydrationService,
            athleteRepository: athleteRepository,
            acceptanceService: acceptanceService,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService
        )

        // Confirm the store really is empty before proceeding.
        #expect(try parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
        #expect(try parentWorkspaceRepository.fetchAllWorkspaces().isEmpty)
        #expect(try parentWorkspaceRepository.fetchAllParticipants().isEmpty)
        #expect(try athleteRepository.fetchAllAthletes().isEmpty)
        #expect(try athleteAccessGrantRepository.fetchAllGrants().isEmpty)

        let hydration = Self.makeFreshHydrationPayload()
        let accepted = Self.makeAcceptedShare(hydration: hydration)

        let actor = try service.connect(acceptedShare: accepted)

        #expect(actor.participantId == hydration.intendedParticipantId)
        #expect(actor.workspaceId == WorkspaceId(rawValue: hydration.workspaceId))
        #expect(actor.role == .athlete)
        #expect(actor.linkedAthleteId == AthleteId(rawValue: hydration.intendedAthleteId))

        #expect(try parentWorkspaceRepository.fetchAllParentProfiles().count == 1)
        #expect(try parentWorkspaceRepository.fetchAllWorkspaces().count == 1)
        #expect(try parentWorkspaceRepository.fetchAllParticipants().count == 2)
        #expect(try athleteRepository.fetchAllAthletes().count == 1)
        #expect(try athleteAccessGrantRepository.fetchAllGrants().count == 1)

        let restored = try restorationService.restoreState()
        guard case .existingFamily = restored else {
            Issue.record("Expected .existingFamily after hydration, got \(restored)")
            return
        }
    }

    @Test("A repeated connect(acceptedShare:) for the SAME accepted share on the same fresh device is idempotent — no duplicate ParentProfile/FamilyWorkspace/WorkspaceParticipant/AthleteProfile/AthleteAccessGrant, and both calls resolve to the identical CurrentSessionActor")
    func repeatedConnectHydratesIdempotently() throws {
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
        let identityHydrationService = Self.makeIdentityHydrationService(
            container: container,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let sessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: parentWorkspaceRepository,
            eligibilityService: AthleteParticipantEligibilityService()
        )
        let participantShareCoordinator = FamilyWorkspaceParticipantShareCoordinator(transport: CloudKitTransport())
        let service = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            identityHydrationService: identityHydrationService,
            athleteRepository: athleteRepository,
            acceptanceService: acceptanceService,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService
        )
        let accepted = Self.makeAcceptedShare(hydration: Self.makeFreshHydrationPayload())

        let firstActor = try service.connect(acceptedShare: accepted)
        let secondActor = try service.connect(acceptedShare: accepted)

        #expect(firstActor == secondActor)
        #expect(try parentWorkspaceRepository.fetchAllParentProfiles().count == 1)
        #expect(try parentWorkspaceRepository.fetchAllWorkspaces().count == 1)
        #expect(try parentWorkspaceRepository.fetchAllParticipants().count == 2)
        #expect(try athleteRepository.fetchAllAthletes().count == 1)
        #expect(try athleteAccessGrantRepository.fetchAllGrants().count == 1)
    }

    // MARK: - Athlete Connection Foundation B2.6: the acceptance step itself
    // performs the canonical .invited -> .active transition

    @Test("connect(acceptedShare:) performs the canonical .invited -> .active transition itself, via AcceptWorkspaceInvitationService, before B2.3's bind — a participant that starts genuinely .invited still successfully connects")
    func connectPerformsInvitedToActiveTransitionItself() throws {
        let fixture = try Self.makeFixture(preAccept: false)
        let participantBeforeConnect = try fixture.parentWorkspaceRepository.fetchAllParticipants()
            .first { $0.id == fixture.expectedParticipantId }
        #expect(participantBeforeConnect?.state == .invited)

        let accepted = Self.makeAcceptedShare(hydration: fixture.hydrationPayload)

        let actor = try fixture.service.connect(acceptedShare: accepted)

        #expect(actor.participantId == fixture.expectedParticipantId)
        #expect(actor.role == .athlete)
        let participantAfterConnect = try fixture.parentWorkspaceRepository.fetchAllParticipants()
            .first { $0.id == fixture.expectedParticipantId }
        #expect(participantAfterConnect?.state == .active)
    }

    // MARK: - PR #68: hydration conflict stops the chain, creating nothing

    @Test("connect(acceptedShare:) wraps a hydration conflict (a DIFFERENT family already exists locally) as identityHydrationFailed, creating/mutating nothing, and never reaches acceptance/B2.3/B2.4")
    func identityHydrationFailureStopsChain() throws {
        // This device already has a real, different family — a
        // completely unrelated parent/workspace/athlete.
        let fixture = try Self.makeFixture()

        let participantCountBefore = try fixture.parentWorkspaceRepository.fetchAllParticipants().count
        let athleteCountBefore = try fixture.athleteRepository.fetchAllAthletes().count
        let workspaceCountBefore = try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count
        let grantCountBefore = try fixture.athleteAccessGrantRepository.fetchAllGrants().count

        // A genuinely different family's invitation — different
        // workspaceId/parentId/ownerParticipantId entirely.
        let unrelatedHydration = Self.makeFreshHydrationPayload(athleteGivenName: "Emma")
        let accepted = Self.makeAcceptedShare(hydration: unrelatedHydration)

        do {
            _ = try fixture.service.connect(acceptedShare: accepted)
            Issue.record("Expected connect(acceptedShare:) to throw")
        } catch let error as AthleteConnectionLifecycleError {
            guard case .identityHydrationFailed = error else {
                Issue.record("Expected .identityHydrationFailed, got \(error)")
                return
            }
        }

        #expect(try fixture.parentWorkspaceRepository.fetchAllParticipants().count == participantCountBefore)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == athleteCountBefore)
        #expect(try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count == workspaceCountBefore)
        #expect(try fixture.athleteAccessGrantRepository.fetchAllGrants().count == grantCountBefore)
    }

    // MARK: - 4: B2.4 failure surfaces correctly

    /// Test seam: throws a fixed, real `AthleteSessionActivationError`
    /// regardless of the (already-valid) `BoundAthleteIdentity` it
    /// receives — see `AthleteSessionActivating`'s own doc comment for
    /// why this is necessary (no canonical repository/domain path exists
    /// to move an already-`.active` `WorkspaceParticipant` into a state
    /// B2.4 itself would reject, so this test cannot legitimately
    /// reproduce a real B2.4 failure through persistence alone).
    @MainActor
    private struct FailingSessionActivator: AthleteSessionActivating {
        let error: AthleteSessionActivationError
        func activate(boundIdentity: BoundAthleteIdentity) throws -> CurrentSessionActor {
            throw error
        }
    }

    @Test("connect(acceptedShare:) wraps a B2.4 (session activation) failure as sessionActivationFailed after hydration/acceptance/B2.3 already succeeded")
    func sessionActivationFailureSurfacesCorrectly() throws {
        // B2.3 runs for real, against the same genuinely-`.active`
        // participant `makeFixture()` always builds — B2.3 succeeds
        // exactly as it does in `successfulSequenceProducesCanonicalActor`.
        // Only B2.4 is substituted, with a fake that fails regardless of
        // the BoundAthleteIdentity B2.3 legitimately produced.
        let fixture = try Self.makeFixture(
            sessionActivationService: FailingSessionActivator(error: .participantNotActive)
        )
        let accepted = Self.makeAcceptedShare(hydration: fixture.hydrationPayload)

        do {
            _ = try fixture.service.connect(acceptedShare: accepted)
            Issue.record("Expected connect(acceptedShare:) to throw")
        } catch let error as AthleteConnectionLifecycleError {
            guard case .sessionActivationFailed = error else {
                Issue.record("Expected .sessionActivationFailed, got \(error)")
                return
            }
        }
    }
}
