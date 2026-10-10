import Testing
import Foundation
import SwiftData
import VoxtrCoreContracts
@testable import VoxtrAppShell
@testable import VoxtrCore
import VoxtrParentDomain
import VoxtrAthleteDomain

// Athlete hydration/activation integration slice (transition-plan §5.2,
// task brief `Docs/Tasks/AthleteHydrationActivationIntegration-2026-10-10.md`).
//
// `AthleteBackendConnectionCoordinator`'s own hydrate -> accept -> bind
// -> activate sequencing, restoration flow, and cancellation/generation
// safety are exercised here against REAL canonical collaborators
// (`AcceptWorkspaceInvitationService`, `AthleteConnectionIdentityBindingService`,
// `AthleteSessionActivationService`, `AthleteRepository`, all backed by a
// real in-memory SwiftData family — matching `AthleteConnectionLifecycleServiceTests
// .swift`'s own established fixture pattern) and FAKES only for the two
// network-touching seams this coordinator itself introduced
// (`AthleteBackendHydrating`, `AthleteFreshSessionVerifying` — both
// thin, single-purpose test-substitution protocols mirroring this
// codebase's own existing `AthleteSessionActivating` precedent) plus the
// Keychain-backed checkpoint store (`AthleteBackendConnectionCheckpointStoring`,
// already a protocol).
//
// Every nested service's OWN exhaustive error/eligibility matrix
// (acceptance outcomes, binding failures, eligibility reasons) already
// has its own dedicated test file — never re-derived here. This suite
// proves only the coordinator's OWN orchestration contract: which state
// each hydration/session outcome maps to, that a local activation
// failure of ANY kind folds into `.recoveryRequired` without fabricating
// a connection, that the checkpoint is written only after a real local
// success, and that cancellation/generation-fencing never lets a stale
// attempt overwrite a newer one's state.
//
// Like the other persistence-backed tests in this suite, the tests that
// build a real family via `InMemoryPersistenceController` exercise
// `@Model` types through actual SwiftData persistence and require the
// Xcode/macOS SwiftData runtime — written but not executed in this
// sandbox.
@MainActor
private final class FakeCoordinatorHydrationAdapter: AthleteBackendHydrating {
    enum Step {
        case outcome(AthleteBackendHydrationOutcome)
        case failure(Error)
    }

    private var queue: [Step] = []
    private(set) var callCount = 0
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspend = false

    func enqueue(_ step: Step) { queue.append(step) }

    /// Makes the NEXT `hydrate(deviceGrantId:)` call park until
    /// `resumeSuspendedCall()` releases it — lets a test build a real
    /// cancellation/generation-replacement scenario instead of trusting
    /// `Task.yield()` scheduling order, mirroring this suite's sibling
    /// test doubles' own established suspend/resume gate shape (see
    /// `AthleteBackendHydrationAdapterTests.FakeAdapterTransport`).
    func suspendNextCall() { shouldSuspend = true }

    func resumeSuspendedCall() {
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }

    func waitUntilSuspended() async {
        while suspensionContinuation == nil { await Task.yield() }
    }

    func hydrate(deviceGrantId: UUID) async throws -> AthleteBackendHydrationOutcome {
        callCount += 1
        // Reserves THIS call's own step before ever suspending — a
        // later, separate call must dequeue ITS OWN enqueued step, not
        // steal the one this call already claimed, mirroring
        // `AthleteBackendHydrationAdapterTests.FakeAdapterTransport
        // .send(_:)`'s own established "remove the stub, then suspend"
        // ordering exactly.
        guard !queue.isEmpty else {
            struct NoStepConfigured: Error {}
            throw NoStepConfigured()
        }
        let step = queue.removeFirst()
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                suspensionContinuation = continuation
            }
        }
        switch step {
        case .outcome(let outcome): return outcome
        case .failure(let error): throw error
        }
    }
}

@MainActor
private final class FakeCoordinatorSessionManager: AthleteFreshSessionVerifying {
    enum Step {
        case token(String)
        case failure(Error)
    }

    private var queue: [Step] = []
    private(set) var callCount = 0
    private(set) var clearStoredSessionCallCount = 0
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspend = false

    func enqueue(_ step: Step) { queue.append(step) }
    func suspendNextCall() { shouldSuspend = true }

    func resumeSuspendedCall() {
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }

    func waitUntilSuspended() async {
        while suspensionContinuation == nil { await Task.yield() }
    }

    func ensureFreshlyVerifiedSession(deviceGrantId: UUID) async throws -> String {
        callCount += 1
        guard !queue.isEmpty else {
            struct NoStepConfigured: Error {}
            throw NoStepConfigured()
        }
        let step = queue.removeFirst()
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                suspensionContinuation = continuation
            }
        }
        switch step {
        case .token(let token): return token
        case .failure(let error): throw error
        }
    }

    func clearStoredSession() {
        clearStoredSessionCallCount += 1
    }
}

/// Deterministic, in-memory — never real Keychain I/O, matching
/// `AthleteBackendHydrationAdapterTests.FakeAdapterSessionStore`'s own
/// established shape.
@MainActor
private final class FakeCoordinatorCheckpointStore: AthleteBackendConnectionCheckpointStoring {
    var stored: AthleteBackendConnectionCheckpoint?
    var saveShouldThrow = false
    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0

    func loadCheckpoint() -> AthleteBackendConnectionCheckpoint? { stored }

    func saveCheckpoint(_ checkpoint: AthleteBackendConnectionCheckpoint) throws {
        saveCallCount += 1
        if saveShouldThrow {
            throw AthleteBackendConnectionCheckpointStoreError.encodingFailed
        }
        stored = checkpoint
    }

    func clearCheckpoint() {
        clearCallCount += 1
        stored = nil
    }
}

@Suite("AthleteBackendConnectionCoordinator (Athlete hydration/activation integration slice, §5.2)", .serialized)
@MainActor
struct AthleteBackendConnectionCoordinatorTests {

    private static let deviceGrantId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private static let otherDeviceGrantId = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    private struct Fixture {
        // Retained for the fixture's entire lifetime — see
        // `AthleteConnectionLifecycleServiceTests.swift`'s own
        // established precedent.
        let container: ModelContainer
        let coordinator: AthleteBackendConnectionCoordinator
        let hydrationAdapter: FakeCoordinatorHydrationAdapter
        let sessionManager: FakeCoordinatorSessionManager
        let checkpointStore: FakeCoordinatorCheckpointStore
        let parentWorkspaceRepository: ParentWorkspaceRepository
        let athleteRepository: AthleteRepository
        let invitedParticipantId: UUID
        let workspaceRawId: UUID
        let athleteRawId: UUID
    }

    /// Builds a real, canonically-created family with a single
    /// `.athlete`-role participant left genuinely `.invited` — the
    /// coordinator's own job is to drive the real `.invited -> .active`
    /// transition itself via `acceptanceService`, matching
    /// `AthleteConnectionLifecycleServiceTests.makeFixture(preAccept:
    /// false)`'s own established precedent.
    private static func makeFixture() throws -> Fixture {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let coordinatorOnboarding = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let created = try coordinatorOnboarding.createFamily(
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
        let restorationService = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let identityBindingService = AthleteConnectionIdentityBindingService(familyRestorationService: restorationService)
        let sessionActivationService = AthleteSessionActivationService(parentWorkspaceRepository: parentWorkspaceRepository)

        let hydrationAdapter = FakeCoordinatorHydrationAdapter()
        let sessionManager = FakeCoordinatorSessionManager()
        let checkpointStore = FakeCoordinatorCheckpointStore()

        let coordinator = AthleteBackendConnectionCoordinator(
            hydrationAdapter: hydrationAdapter,
            sessionManager: sessionManager,
            athleteRepository: athleteRepository,
            acceptanceService: acceptanceService,
            identityBindingService: identityBindingService,
            sessionActivationService: sessionActivationService,
            checkpointStore: checkpointStore
        )

        return Fixture(
            container: container,
            coordinator: coordinator,
            hydrationAdapter: hydrationAdapter,
            sessionManager: sessionManager,
            checkpointStore: checkpointStore,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            invitedParticipantId: invitedParticipant.id,
            workspaceRawId: created.workspace.id,
            athleteRawId: created.athlete.id
        )
    }

    /// Real-sleep-based bounded wait for the coordinator's own
    /// fire-and-forget `Task` to settle, mirroring
    /// `AthleteDeviceAuthorizationInvitationCoordinatorTests.waitUntil(_:_:)`'s
    /// own established shape exactly — `activate`/`restoreOnLaunchOrForeground`
    /// are themselves synchronous (they only kick off the background
    /// work and return), so no `await` on them alone can observe the
    /// eventual settled state.
    private func waitUntil(
        _ coordinator: AthleteBackendConnectionCoordinator,
        timeoutMS: Int = 2000,
        _ predicate: (AthleteBackendConnectionCoordinator.State) -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMS))
        while ContinuousClock.now < deadline {
            if predicate(coordinator.state) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func isSettled(_ state: AthleteBackendConnectionCoordinator.State) -> Bool {
        if case .activating = state { return false }
        return true
    }

    // MARK: - First-time activation: hydration outcomes

    @Test(".hydratedAndAcked drives accept -> bind -> activate and reports .connected(verified: true), saving a checkpoint with the exact hydrated IDs")
    func hydratedAndAckedProducesConnectedVerified() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.enqueue(.outcome(.hydratedAndAcked(
            workspaceId: fixture.workspaceRawId, participantId: fixture.invitedParticipantId, athleteId: fixture.athleteRawId
        )))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        guard case .connected(let actor, let verified) = fixture.coordinator.state else {
            Issue.record("expected .connected, got \(fixture.coordinator.state)")
            return
        }
        #expect(verified == true)
        #expect(actor.participantId == fixture.invitedParticipantId)
        #expect(actor.workspaceId == WorkspaceId(rawValue: fixture.workspaceRawId))
        #expect(actor.linkedAthleteId == AthleteId(rawValue: fixture.athleteRawId))

        #expect(fixture.checkpointStore.saveCallCount == 1)
        #expect(fixture.checkpointStore.stored == AthleteBackendConnectionCheckpoint(
            deviceGrantId: Self.deviceGrantId, workspaceId: fixture.workspaceRawId,
            participantId: fixture.invitedParticipantId, athleteId: fixture.athleteRawId
        ))
    }

    @Test(".alreadyCompleted resumes from a matching previously-saved checkpoint for the SAME grant and still reaches .connected(verified: true)")
    func alreadyCompletedResumesFromMatchingCheckpoint() async throws {
        let fixture = try Self.makeFixture()
        fixture.checkpointStore.stored = AthleteBackendConnectionCheckpoint(
            deviceGrantId: Self.deviceGrantId, workspaceId: fixture.workspaceRawId,
            participantId: fixture.invitedParticipantId, athleteId: fixture.athleteRawId
        )
        fixture.hydrationAdapter.enqueue(.outcome(.alreadyCompleted))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        guard case .connected(_, let verified) = fixture.coordinator.state else {
            Issue.record("expected .connected, got \(fixture.coordinator.state)")
            return
        }
        #expect(verified == true)
    }

    @Test(".alreadyCompleted with NO saved checkpoint at all honestly reports .recoveryRequired, never fabricating a target")
    func alreadyCompletedWithNoCheckpointReportsRecoveryRequired() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.enqueue(.outcome(.alreadyCompleted))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        #expect(fixture.coordinator.state == .recoveryRequired)
        #expect(fixture.checkpointStore.saveCallCount == 0)
    }

    @Test(".alreadyCompleted with a checkpoint saved for a DIFFERENT grant is never reused — reports .recoveryRequired")
    func alreadyCompletedWithCheckpointForDifferentGrantReportsRecoveryRequired() async throws {
        let fixture = try Self.makeFixture()
        fixture.checkpointStore.stored = AthleteBackendConnectionCheckpoint(
            deviceGrantId: Self.otherDeviceGrantId, workspaceId: fixture.workspaceRawId,
            participantId: fixture.invitedParticipantId, athleteId: fixture.athleteRawId
        )
        fixture.hydrationAdapter.enqueue(.outcome(.alreadyCompleted))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        #expect(fixture.coordinator.state == .recoveryRequired)
        #expect(fixture.checkpointStore.saveCallCount == 0)
    }

    @Test(".deadlinePassed reports .hydrationWindowExpired")
    func deadlinePassedReportsHydrationWindowExpired() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.enqueue(.outcome(.deadlinePassed))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        #expect(fixture.coordinator.state == .hydrationWindowExpired)
    }

    @Test(".grantRevoked reports the SPECIFIC .grantRevoked state")
    func grantRevokedReportsGrantRevoked() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.enqueue(.outcome(.grantRevoked))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        #expect(fixture.coordinator.state == .grantRevoked)
    }

    @Test(".notYetAvailable reports .waitingForParentApproval")
    func notYetAvailableReportsWaitingForParentApproval() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.enqueue(.outcome(.notYetAvailable))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        #expect(fixture.coordinator.state == .waitingForParentApproval)
    }

    // MARK: - First-time activation: hydrate() throwing

    @Test("SessionFailure.grantUnavailable from hydrate() reports the NEUTRAL .connectionUnavailable, never .grantRevoked")
    func grantUnavailableFailureReportsConnectionUnavailable() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.enqueue(.failure(AthleteDeviceAuthorizationSessionManager.SessionFailure.grantUnavailable))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        #expect(fixture.coordinator.state == .connectionUnavailable)
    }

    @Test("SessionFailure.installationKeyUnavailable from hydrate() reports .installationKeyUnavailable")
    func installationKeyUnavailableFailureReportsInstallationKeyUnavailable() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.enqueue(.failure(AthleteDeviceAuthorizationSessionManager.SessionFailure.installationKeyUnavailable))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        #expect(fixture.coordinator.state == .installationKeyUnavailable)
    }

    @Test("AthleteBackendHydrationError.ackNotConfirmed reports .ackNotConfirmed, never a completed connection")
    func ackNotConfirmedFailureReportsAckNotConfirmed() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.enqueue(.failure(AthleteBackendHydrationError.ackNotConfirmed(.notAvailable)))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        #expect(fixture.coordinator.state == .ackNotConfirmed)
    }

    @Test("An unrecognized hydrate() failure (e.g. a local persistence/graph error) folds into .recoveryRequired, never misclassified as a security denial")
    func unrecognizedFailureReportsRecoveryRequired() async throws {
        let fixture = try Self.makeFixture()
        struct SomeUnrelatedError: Error {}
        fixture.hydrationAdapter.enqueue(.failure(SomeUnrelatedError()))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        #expect(fixture.coordinator.state == .recoveryRequired)
    }

    // MARK: - Local activation correctness

    @Test("A hydrated target whose participant/athlete IDs do not exist in this device's own local family folds into .recoveryRequired, never fabricating a connection, and never saves a checkpoint")
    func foreignHydrationTargetReportsRecoveryRequiredWithoutCheckpoint() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.enqueue(.outcome(.hydratedAndAcked(
            workspaceId: fixture.workspaceRawId, participantId: UUID(), athleteId: UUID()
        )))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        #expect(fixture.coordinator.state == .recoveryRequired)
        #expect(fixture.checkpointStore.saveCallCount == 0)
    }

    @Test("A checkpoint-store save failure never blocks reporting the already-genuine .connected success")
    func checkpointSaveFailureNeverBlocksReportingConnected() async throws {
        let fixture = try Self.makeFixture()
        fixture.checkpointStore.saveShouldThrow = true
        fixture.hydrationAdapter.enqueue(.outcome(.hydratedAndAcked(
            workspaceId: fixture.workspaceRawId, participantId: fixture.invitedParticipantId, athleteId: fixture.athleteRawId
        )))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)

        guard case .connected(_, let verified) = fixture.coordinator.state else {
            Issue.record("expected .connected despite the checkpoint save failure, got \(fixture.coordinator.state)")
            return
        }
        #expect(verified == true)
        #expect(fixture.checkpointStore.saveCallCount == 1)
        #expect(fixture.checkpointStore.stored == nil)
    }

    // MARK: - Cancellation / generation safety

    @Test("A second activate() call supersedes an in-flight first attempt — the first's late-arriving result never overwrites the second's own final state")
    func secondActivateSupersedesInFlightFirst() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.suspendNextCall()
        fixture.hydrationAdapter.enqueue(.outcome(.grantRevoked))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await fixture.hydrationAdapter.waitUntilSuspended()
        #expect(fixture.coordinator.state == .activating)

        // A fresh attempt for a DIFFERENT grant, resolving immediately.
        fixture.hydrationAdapter.enqueue(.outcome(.waitingForParentApproval))
        fixture.coordinator.activate(deviceGrantId: Self.otherDeviceGrantId)
        await waitUntil(fixture.coordinator, isSettled)
        #expect(fixture.coordinator.state == .waitingForParentApproval)

        // Release the FIRST attempt's suspended call now — its own
        // `.grantRevoked` result must never land, since it is no longer
        // the current generation.
        fixture.hydrationAdapter.resumeSuspendedCall()
        // Give the (now-stale) first Task a real chance to run to
        // completion and attempt (and fail) its own state write.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(fixture.coordinator.state == .waitingForParentApproval)
    }

    @Test("cancel() while activating stops the in-flight attempt without itself changing state, and the cancelled attempt's own eventual result never lands")
    func cancelLeavesStateUnchangedAndSuppressesStaleResult() async throws {
        let fixture = try Self.makeFixture()
        fixture.hydrationAdapter.suspendNextCall()
        fixture.hydrationAdapter.enqueue(.outcome(.grantRevoked))

        fixture.coordinator.activate(deviceGrantId: Self.deviceGrantId)
        await fixture.hydrationAdapter.waitUntilSuspended()
        #expect(fixture.coordinator.state == .activating)

        fixture.coordinator.cancel()
        #expect(fixture.coordinator.state == .activating)

        fixture.hydrationAdapter.resumeSuspendedCall()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(fixture.coordinator.state == .activating)
    }

    // MARK: - Restoration (launch/foreground)

    @Test("restoreOnLaunchOrForeground() with no saved checkpoint stays .idle and never touches hydration/session collaborators")
    func restorationWithNoCheckpointStaysIdle() async throws {
        let fixture = try Self.makeFixture()

        fixture.coordinator.restoreOnLaunchOrForeground()

        #expect(fixture.coordinator.state == .idle)
        #expect(fixture.hydrationAdapter.callCount == 0)
        #expect(fixture.sessionManager.callCount == 0)
    }

    @Test("restoreOnLaunchOrForeground() presents cached/unverified FIRST, then promotes to verified only after a genuine online round trip succeeds")
    func restorationPresentsCachedThenPromotesToVerified() async throws {
        let fixture = try Self.makeFixture()
        // Already a genuinely-active local participant — simulating a
        // prior successful activation this same device already
        // completed.
        _ = AcceptWorkspaceInvitationService(
            repository: fixture.parentWorkspaceRepository, eligibilityService: AthleteParticipantEligibilityService()
        ).accept(
            athleteId: AthleteId(rawValue: fixture.athleteRawId), workspaceId: WorkspaceId(rawValue: fixture.workspaceRawId),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: WorkspaceId(rawValue: fixture.workspaceRawId), isArchived: false)
        )
        fixture.checkpointStore.stored = AthleteBackendConnectionCheckpoint(
            deviceGrantId: Self.deviceGrantId, workspaceId: fixture.workspaceRawId,
            participantId: fixture.invitedParticipantId, athleteId: fixture.athleteRawId
        )
        fixture.sessionManager.suspendNextCall()
        fixture.sessionManager.enqueue(.token("fresh-token"))

        fixture.coordinator.restoreOnLaunchOrForeground()

        await fixture.sessionManager.waitUntilSuspended()
        guard case .connected(_, let verifiedWhileSuspended) = fixture.coordinator.state else {
            Issue.record("expected the cached .connected(verified: false) presentation before the online check resolves, got \(fixture.coordinator.state)")
            return
        }
        #expect(verifiedWhileSuspended == false)

        fixture.sessionManager.resumeSuspendedCall()
        await waitUntil(fixture.coordinator) { state in
            if case .connected(_, true) = state { return true }
            return false
        }
        guard case .connected(_, let verifiedAfter) = fixture.coordinator.state else {
            Issue.record("expected .connected(verified: true) after the online check succeeds, got \(fixture.coordinator.state)")
            return
        }
        #expect(verifiedAfter == true)
    }

    @Test("restoreOnLaunchOrForeground(): a forced online check denied with .grantUnavailable reports the NEUTRAL .connectionUnavailable, overwriting the cached presentation")
    func restorationOnlineDenialReportsConnectionUnavailable() async throws {
        let fixture = try Self.makeFixture()
        _ = AcceptWorkspaceInvitationService(
            repository: fixture.parentWorkspaceRepository, eligibilityService: AthleteParticipantEligibilityService()
        ).accept(
            athleteId: AthleteId(rawValue: fixture.athleteRawId), workspaceId: WorkspaceId(rawValue: fixture.workspaceRawId),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: WorkspaceId(rawValue: fixture.workspaceRawId), isArchived: false)
        )
        fixture.checkpointStore.stored = AthleteBackendConnectionCheckpoint(
            deviceGrantId: Self.deviceGrantId, workspaceId: fixture.workspaceRawId,
            participantId: fixture.invitedParticipantId, athleteId: fixture.athleteRawId
        )
        fixture.sessionManager.enqueue(.failure(AthleteDeviceAuthorizationSessionManager.SessionFailure.grantUnavailable))

        fixture.coordinator.restoreOnLaunchOrForeground()
        await waitUntil(fixture.coordinator) { $0 == .connectionUnavailable }

        #expect(fixture.coordinator.state == .connectionUnavailable)
    }

    @Test("restoreOnLaunchOrForeground(): a transient network failure on the online check stays at the already-shown cached/unverified presentation — never promoted, never denied")
    func restorationTransientNetworkFailureStaysCached() async throws {
        let fixture = try Self.makeFixture()
        _ = AcceptWorkspaceInvitationService(
            repository: fixture.parentWorkspaceRepository, eligibilityService: AthleteParticipantEligibilityService()
        ).accept(
            athleteId: AthleteId(rawValue: fixture.athleteRawId), workspaceId: WorkspaceId(rawValue: fixture.workspaceRawId),
            eligibilityFacts: AthleteEligibilityFacts(workspaceId: WorkspaceId(rawValue: fixture.workspaceRawId), isArchived: false)
        )
        fixture.checkpointStore.stored = AthleteBackendConnectionCheckpoint(
            deviceGrantId: Self.deviceGrantId, workspaceId: fixture.workspaceRawId,
            participantId: fixture.invitedParticipantId, athleteId: fixture.athleteRawId
        )
        fixture.sessionManager.enqueue(.failure(AthleteDeviceAuthorizationSessionManager.SessionFailure.network))

        fixture.coordinator.restoreOnLaunchOrForeground()
        await waitUntil(fixture.coordinator) { state in
            fixture.sessionManager.callCount > 0
        }
        // Bounded settle window for the (already-dispatched) state write.
        try? await Task.sleep(nanoseconds: 50_000_000)

        guard case .connected(_, let verified) = fixture.coordinator.state else {
            Issue.record("expected to remain at the cached .connected(verified: false), got \(fixture.coordinator.state)")
            return
        }
        #expect(verified == false)
    }

    @Test("restoreOnLaunchOrForeground(): a checkpoint whose local graph no longer supports it (still .invited, never actually accepted) reports .recoveryRequired and never calls the session manager")
    func restorationWithUnsupportedLocalGraphReportsRecoveryRequired() async throws {
        let fixture = try Self.makeFixture()
        // Deliberately NOT accepted — the checkpoint claims an
        // activation that never actually completed locally.
        fixture.checkpointStore.stored = AthleteBackendConnectionCheckpoint(
            deviceGrantId: Self.deviceGrantId, workspaceId: fixture.workspaceRawId,
            participantId: fixture.invitedParticipantId, athleteId: fixture.athleteRawId
        )

        fixture.coordinator.restoreOnLaunchOrForeground()
        await waitUntil(fixture.coordinator) { $0 == .recoveryRequired }

        #expect(fixture.coordinator.state == .recoveryRequired)
        #expect(fixture.sessionManager.callCount == 0)
    }

    // MARK: - Sign-out / invalidation

    @Test("signOutOrInvalidate() clears the checkpoint and the session manager's stored session, and returns to .idle")
    func signOutClearsCheckpointAndSessionAndReturnsToIdle() throws {
        let fixture = try Self.makeFixture()
        fixture.checkpointStore.stored = AthleteBackendConnectionCheckpoint(
            deviceGrantId: Self.deviceGrantId, workspaceId: fixture.workspaceRawId,
            participantId: fixture.invitedParticipantId, athleteId: fixture.athleteRawId
        )

        fixture.coordinator.signOutOrInvalidate()

        #expect(fixture.coordinator.state == .idle)
        #expect(fixture.checkpointStore.clearCallCount == 1)
        #expect(fixture.checkpointStore.stored == nil)
        #expect(fixture.sessionManager.clearStoredSessionCallCount == 1)
    }
}
