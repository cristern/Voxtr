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
        // Retained for the fixture's entire lifetime: an in-memory
        // ModelContainer that nothing else keeps alive gets deallocated
        // once the factory function returns, which invalidates every
        // @Model instance fetched through it (SwiftData resets/destroys
        // the backing context) — the exact cause of the
        // "This model instance was destroyed by calling ModelContext
        // .reset" crash this fixture previously produced. Every other
        // persistence-backed test in this suite avoids this by
        // constructing `container` directly inside the test function
        // itself (so its scope IS the test); this factory function
        // needed the container to outlive its own return, so it is
        // carried here instead.
        let container: ModelContainer
        let service: AthleteConnectionLifecycleService
        let parentWorkspaceRepository: ParentWorkspaceRepository
        let athleteRepository: AthleteRepository
        // Snapshotted stable IDs rather than the managed `@Model`
        // instances themselves — the test only ever needs identity
        // values for comparison, not continued live access to the
        // objects.
        let workspaceRawId: UUID
        let expectedParticipantId: UUID
        let expectedWorkspaceId: WorkspaceId
        let expectedAthleteId: AthleteId
    }

    /// Builds a real, canonically-created family with an invited AND
    /// accepted `.athlete` participant — the same fixture shape B2.3/B2.4's
    /// own integration tests use — wired into a real
    /// `AthleteConnectionLifecycleService`. `sessionActivationService`
    /// defaults to the real B2.4 implementation; a test proving a GENUINE
    /// later B2.4 failure (after this real, successful B2.3-eligible
    /// setup) substitutes a fake conforming to `AthleteSessionActivating`
    /// instead — see that protocol's own doc comment for why.
    /// `preAccept`: when `true` (the default, matching every pre-B2.6
    /// test in this suite), the fixture pre-accepts the invited
    /// participant itself before ever calling `connect(acceptedShare:)`,
    /// so `.expectedParticipantId` names an already-`.active` participant
    /// — exercising `connect(acceptedShare:)`'s own ACCEPTANCE STEP as a
    /// safe no-op (`.alreadyAccepted`). When `false`, the fixture leaves
    /// the participant genuinely `.invited` — proving `connect(
    /// acceptedShare:)` itself performs the real `.invited -> .active`
    /// transition (Athlete Connection Foundation B2.6) rather than
    /// requiring the caller to have already done so.
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
        let realSessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        // Never actually exercised by connect(acceptedShare:) — only
        // required to satisfy AthleteConnectionLifecycleService's own
        // initializer. Constructing CloudKitTransport performs no
        // network I/O (B1's lazy CKContainer realization).
        let participantShareCoordinator = FamilyWorkspaceParticipantShareCoordinator(transport: CloudKitTransport())

        let service = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            athleteRepository: athleteRepository,
            acceptanceService: acceptanceService,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService ?? realSessionActivationService
        )

        return Fixture(
            container: container,
            service: service,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            workspaceRawId: created.workspace.id,
            expectedParticipantId: expectedParticipantId,
            expectedWorkspaceId: created.workspace.workspaceId,
            expectedAthleteId: created.athlete.athleteId
        )
    }

    private static func makeAcceptedShare(
        workspaceId: UUID,
        intendedParticipantId: UUID = UUID(),
        intendedAthleteId: UUID = UUID()
    ) -> AcceptedFamilyWorkspaceShare {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        return AcceptedFamilyWorkspaceShare(
            workspaceId: workspaceId,
            zoneID: zoneID,
            rootRecordID: CKRecord.ID(recordName: "test-root", zoneID: zoneID),
            shareRecordID: CKRecord.ID(recordName: "test-share", zoneID: zoneID),
            intendedParticipantId: intendedParticipantId,
            intendedAthleteId: intendedAthleteId
        )
    }

    // MARK: - 1/5/6: successful sequence

    @Test("connect(acceptedShare:) sequences B2.3 -> B2.4 and returns exactly B2.4's own CurrentSessionActor, creating/mutating nothing")
    func successfulSequenceProducesCanonicalActor() throws {
        let fixture = try Self.makeFixture()
        let accepted = Self.makeAcceptedShare(
            workspaceId: fixture.workspaceRawId,
            intendedParticipantId: fixture.expectedParticipantId,
            intendedAthleteId: fixture.expectedAthleteId.rawValue
        )

        let participantCountBefore = try fixture.parentWorkspaceRepository.fetchAllParticipants().count
        let athleteCountBefore = try fixture.athleteRepository.fetchAllAthletes().count
        let workspaceCountBefore = try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count

        let actor = try fixture.service.connect(acceptedShare: accepted)

        #expect(actor.participantId == fixture.expectedParticipantId)
        #expect(actor.workspaceId == fixture.expectedWorkspaceId)
        #expect(actor.role == .athlete)
        #expect(actor.linkedAthleteId == fixture.expectedAthleteId)

        #expect(try fixture.parentWorkspaceRepository.fetchAllParticipants().count == participantCountBefore)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == athleteCountBefore)
        #expect(try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count == workspaceCountBefore)
    }

    // MARK: - Athlete Connection Foundation B2.6: the acceptance step itself
    // performs the canonical .invited -> .active transition

    @Test("connect(acceptedShare:) performs the canonical .invited -> .active transition itself, via AcceptWorkspaceInvitationService, before B2.3's bind — a participant that starts genuinely .invited still successfully connects")
    func connectPerformsInvitedToActiveTransitionItself() throws {
        let fixture = try Self.makeFixture(preAccept: false)
        let participantBeforeConnect = try fixture.parentWorkspaceRepository.fetchAllParticipants()
            .first { $0.id == fixture.expectedParticipantId }
        #expect(participantBeforeConnect?.state == .invited)

        let accepted = Self.makeAcceptedShare(
            workspaceId: fixture.workspaceRawId,
            intendedParticipantId: fixture.expectedParticipantId,
            intendedAthleteId: fixture.expectedAthleteId.rawValue
        )

        let actor = try fixture.service.connect(acceptedShare: accepted)

        #expect(actor.participantId == fixture.expectedParticipantId)
        #expect(actor.role == .athlete)
        let participantAfterConnect = try fixture.parentWorkspaceRepository.fetchAllParticipants()
            .first { $0.id == fixture.expectedParticipantId }
        #expect(participantAfterConnect?.state == .active)
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
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: parentWorkspaceRepository,
            eligibilityService: AthleteParticipantEligibilityService()
        )
        let service = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            athleteRepository: athleteRepository,
            acceptanceService: acceptanceService,
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

    @Test("connect(acceptedShare:) wraps a B2.4 (session activation) failure as sessionActivationFailed after B2.3 already succeeded")
    func sessionActivationFailureSurfacesCorrectly() throws {
        // B2.3 runs for real, against the same genuinely-`.active`
        // participant `makeFixture()` always builds — B2.3 succeeds
        // exactly as it does in `successfulSequenceProducesCanonicalActor`.
        // Only B2.4 is substituted, with a fake that fails regardless of
        // the BoundAthleteIdentity B2.3 legitimately produced.
        let fixture = try Self.makeFixture(
            sessionActivationService: FailingSessionActivator(error: .participantNotActive)
        )
        let accepted = Self.makeAcceptedShare(
            workspaceId: fixture.workspaceRawId,
            intendedParticipantId: fixture.expectedParticipantId,
            intendedAthleteId: fixture.expectedAthleteId.rawValue
        )

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
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: parentWorkspaceRepository,
            eligibilityService: AthleteParticipantEligibilityService()
        )
        let service = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            athleteRepository: athleteRepository,
            acceptanceService: acceptanceService,
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
