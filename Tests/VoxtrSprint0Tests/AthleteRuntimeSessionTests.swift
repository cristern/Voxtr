import Testing
import Foundation
import CloudKit
import SwiftData
import VoxtrCoreContracts
@testable import VoxtrAppShell
@testable import VoxtrCore
import VoxtrParentDomain
import VoxtrAthleteDomain

// NOTE: every test here constructs its OWN `AthleteRuntimeSession()`
// (its initializer is internal specifically for this reason — see that
// type's own doc comment) rather than using `.shared` — testing the
// state machine against a shared, cross-test, cross-suite singleton
// would be inherently order-dependent. `handleAcceptedCloudKitShare(_:
// CKShare.Metadata)` — the real production entry point — is never
// exercised here for the same reason `AthleteConnectionLifecycleService
// .connect(from:)` itself has no test: `CKShare.Metadata` has no public
// initializer reachable without a real accepted share. What IS fully
// tested is `handleAcceptedShare(_:)`, the directly-testable hydration →
// B2.3 → B2.4 continuation this type exposes — see that method's own
// doc comment.
//
// Like the other persistence-backed tests in this suite, the tests that
// build a real family via `InMemoryPersistenceController` require the
// Xcode/macOS SwiftData runtime — written but not executed in this
// sandbox.
@Suite("AthleteRuntimeSession (Athlete Connection Foundation B2.5/B2.6, PR #68 follow-up)", .serialized)
@MainActor
struct AthleteRuntimeSessionTests {

    private struct SuccessFixture {
        // Retained for the fixture's entire lifetime — see
        // AthleteConnectionLifecycleServiceTests.Fixture's own doc
        // comment for why an in-memory ModelContainer built inside a
        // static factory function must be carried out of it rather than
        // left to go out of scope, or SwiftData invalidates every
        // @Model instance fetched through it.
        let container: ModelContainer
        let session: AthleteRuntimeSession
        let acceptedShare: AcceptedFamilyWorkspaceShare
        let expectedParticipantId: UUID
        let expectedWorkspaceId: WorkspaceId
        let expectedAthleteId: AthleteId
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

    /// A syntactically well-formed but semantically INVALID hydration
    /// payload — an `athleteBirthDateISO` `AthleteIdentityHydrationService`
    /// cannot parse into a `LocalDate`. Used to force a genuine, real
    /// failure (`identityHydrationFailed`) without depending on any
    /// pre-existing local state, matching this codebase's own
    /// established preference for real failure modes over fabricated
    /// ones.
    private static func makeInvalidHydrationPayload(workspaceId: UUID = UUID()) -> AthleteConnectionInvitationCloudRecordPayload {
        AthleteConnectionInvitationCloudRecordPayload(
            workspaceId: workspaceId,
            intendedParticipantId: UUID(),
            intendedAthleteId: UUID(),
            parentId: UUID(),
            parentGivenName: "Kari",
            workspaceDisplayName: "Kari's family",
            ownerParticipantId: UUID(),
            athleteGivenName: "Jonas",
            athleteBirthDateISO: "not-a-real-date",
            athleteTimeZoneId: "Europe/Oslo",
            athleteDevelopmentStage: DevelopmentStage.parentLed.rawValue
        )
    }

    /// A session configured against a real, canonically-created and
    /// accepted family — `handleAcceptedShare(_:)` against this fixture
    /// always succeeds.
    private static func makeSuccessFixture() throws -> SuccessFixture {
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
        let identityHydrationService = AthleteIdentityHydrationService(
            modelContext: container.mainContext,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let sessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        let participantShareCoordinator = FamilyWorkspaceParticipantShareCoordinator(transport: CloudKitTransport())
        let lifecycleService = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            identityHydrationService: identityHydrationService,
            athleteRepository: athleteRepository,
            acceptanceService: acceptanceService,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService
        )

        let session = AthleteRuntimeSession()
        session.configure(lifecycleService: lifecycleService)

        let hydration = AthleteConnectionInvitationCloudRecordPayload(
            workspaceId: created.workspace.id,
            intendedParticipantId: acceptedParticipant.id,
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

        return SuccessFixture(
            container: container,
            session: session,
            acceptedShare: Self.makeAcceptedShare(hydration: hydration),
            expectedParticipantId: acceptedParticipant.id,
            expectedWorkspaceId: created.workspace.workspaceId,
            expectedAthleteId: created.athlete.athleteId
        )
    }

    // MARK: - 7: initial state has no actor

    @Test("A freshly-constructed AthleteRuntimeSession starts .notConnected, with no actor")
    func initialStateHasNoActor() {
        let session = AthleteRuntimeSession()

        guard case .notConnected = session.state else {
            Issue.record("Expected .notConnected, got \(session.state)")
            return
        }
    }

    // MARK: - 8: .connecting never carries an actor

    @Test(".connecting carries no associated value — structurally cannot expose a fabricated actor while a connect attempt is pending (not tested as a live race: both handleAcceptedShare's underlying hydration/B2.3/B2.4 calls are synchronous, so there is no real suspension point to observe .connecting at without an artificial delay, which this project's own lifecycle rules forbid)")
    func connectingStateStructurallyCarriesNoActor() {
        let state = AthleteConnectionRuntimeState.connecting
        if case .connected = state {
            Issue.record(".connecting must never equal .connected")
        }
    }

    // MARK: - 9: successful connection stores exactly one CurrentSessionActor

    @Test("A successful handleAcceptedShare(_:) transitions state to .connected with exactly B2.4's own CurrentSessionActor")
    func successfulConnectionStoresCanonicalActor() async throws {
        let fixture = try Self.makeSuccessFixture()

        await fixture.session.handleAcceptedShare(fixture.acceptedShare)

        guard case .connected(let actor) = fixture.session.state else {
            Issue.record("Expected .connected, got \(fixture.session.state)")
            return
        }
        #expect(actor.participantId == fixture.expectedParticipantId)
        #expect(actor.workspaceId == fixture.expectedWorkspaceId)
        #expect(actor.role == .athlete)
        #expect(actor.linkedAthleteId == fixture.expectedAthleteId)
    }

    // MARK: - 10: failure clears/does not fabricate an active actor

    @Test("A failing handleAcceptedShare(_:) transitions state to .failed, never .connected")
    func failedConnectionNeverFabricatesActor() async throws {
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
        let identityHydrationService = AthleteIdentityHydrationService(
            modelContext: container.mainContext,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let sessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)
        let participantShareCoordinator = FamilyWorkspaceParticipantShareCoordinator(transport: CloudKitTransport())
        let acceptanceService = AcceptWorkspaceInvitationService(
            repository: parentWorkspaceRepository,
            eligibilityService: AthleteParticipantEligibilityService()
        )
        let lifecycleService = AthleteConnectionLifecycleService(
            participantShareCoordinator: participantShareCoordinator,
            identityHydrationService: identityHydrationService,
            athleteRepository: athleteRepository,
            acceptanceService: acceptanceService,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService
        )
        let session = AthleteRuntimeSession()
        session.configure(lifecycleService: lifecycleService)
        // A malformed hydration payload (unparseable birth date) fails
        // hydration itself, regardless of what's on this device already.
        let acceptedShare = Self.makeAcceptedShare(hydration: Self.makeInvalidHydrationPayload())

        await session.handleAcceptedShare(acceptedShare)

        guard case .failed = session.state else {
            Issue.record("Expected .failed, got \(session.state)")
            return
        }
    }

    @Test("Calling handleAcceptedShare(_:) before configure(lifecycleService:) fails explicitly with .lifecycleServiceNotReady rather than silently dropping the callback")
    func unconfiguredSessionFailsExplicitly() async {
        let session = AthleteRuntimeSession()
        let acceptedShare = Self.makeAcceptedShare(hydration: Self.makeInvalidHydrationPayload())

        await session.handleAcceptedShare(acceptedShare)

        guard case .lifecycleServiceNotReady = session.state else {
            Issue.record("Expected .lifecycleServiceNotReady, got \(session.state)")
            return
        }
    }

    // MARK: - 11: repeated same successful connection converges on same actor identity

    @Test("Repeated handleAcceptedShare(_:) calls against unchanged persisted state converge on the identical CurrentSessionActor")
    func repeatedConnectionConvergesOnSameActor() async throws {
        let fixture = try Self.makeSuccessFixture()

        await fixture.session.handleAcceptedShare(fixture.acceptedShare)
        guard case .connected(let firstActor) = fixture.session.state else {
            Issue.record("Expected .connected after first attempt, got \(fixture.session.state)")
            return
        }

        await fixture.session.handleAcceptedShare(fixture.acceptedShare)
        guard case .connected(let secondActor) = fixture.session.state else {
            Issue.record("Expected .connected after second attempt, got \(fixture.session.state)")
            return
        }

        #expect(firstActor == secondActor)
    }
}
