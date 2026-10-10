import Testing
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAthleteDomain
@testable import VoxtrAppShell

// `AthleteShellRoute.route(for:)` is pure/no I/O — every case below runs
// directly, no persistence involved. `AthleteDisplayIdentity
// .resolvedName(for:athleteRepository:)` calls into `AthleteRepository
// .fetchAthlete(byId:)`, which fetches from a real `ModelContext` — like
// the other persistence-backed tests in this suite (see
// `AthleteFamilyManagementServiceTests.swift`'s own header), those cases
// require the Xcode/macOS SwiftData runtime and are written but not
// executed in this sandbox.
@Suite("AthleteShellRoute / AthleteDisplayIdentity (Athlete App Shell / UX Foundation)", .serialized)
struct AthleteShellRoutingTests {

    private static func makeActor(linkedAthleteId: AthleteId? = AthleteId()) -> CurrentSessionActor {
        CurrentSessionActor(
            participantId: UUID(),
            workspaceId: WorkspaceId(),
            role: .athlete,
            linkedAthleteId: linkedAthleteId
        )
    }

    // MARK: - AthleteShellRoute.route(for:)

    @Test("notConnected routes to .gate")
    func notConnectedRoutesToGate() {
        #expect(AthleteShellRoute.route(for: .notConnected) == .gate)
    }

    @Test("connecting routes to .gate")
    func connectingRoutesToGate() {
        #expect(AthleteShellRoute.route(for: .connecting) == .gate)
    }

    @Test("lifecycleServiceNotReady routes to .gate")
    func lifecycleServiceNotReadyRoutesToGate() {
        #expect(AthleteShellRoute.route(for: .lifecycleServiceNotReady) == .gate)
    }

    @Test("failed routes to .gate")
    func failedRoutesToGate() {
        let error = AthleteConnectionLifecycleError.shareAcceptanceOrResolutionFailed(
            NSError(domain: "test", code: 1)
        )
        #expect(AthleteShellRoute.route(for: .failed(error)) == .gate)
    }

    @Test("connected routes to .shell carrying the same actor")
    func connectedRoutesToShellWithSameActor() {
        let actor = Self.makeActor()
        #expect(AthleteShellRoute.route(for: .connected(actor)) == .shell(actor: actor))
    }

    // MARK: - AthleteShellRoute.route(legacyState:backendState:)
    //
    // Athlete hydration/activation integration slice (§5.2): the
    // combined routing decision across the legacy CKShare path and the
    // new backend device-authorization path. Neither path's own status
    // presentation is exercised here (that remains each state's own
    // concern) — only which one, if either, resolves to `.shell`.

    @Test("legacy connected routes to shell even when backend is not connected")
    func legacyConnectedRoutesToShellWhenBackendIsNot() {
        let actor = Self.makeActor()
        let route = AthleteShellRoute.route(legacyState: .connected(actor), backendState: .idle)
        #expect(route == .shell(actor: actor))
    }

    @Test("backend connected routes to shell when legacy is not connected")
    func backendConnectedRoutesToShellWhenLegacyIsNot() {
        let actor = Self.makeActor()
        let route = AthleteShellRoute.route(
            legacyState: .notConnected,
            backendState: .connected(actor, verified: true)
        )
        #expect(route == .shell(actor: actor))
    }

    @Test("backend connected but unverified still routes to shell, carrying the same actor")
    func backendConnectedUnverifiedStillRoutesToShell() {
        let actor = Self.makeActor()
        let route = AthleteShellRoute.route(
            legacyState: .lifecycleServiceNotReady,
            backendState: .connected(actor, verified: false)
        )
        #expect(route == .shell(actor: actor))
    }

    @Test("legacy connected wins over a also-connected backend state")
    func legacyConnectedWinsOverBackendConnected() {
        let legacyActor = Self.makeActor(linkedAthleteId: AthleteId())
        let backendActor = Self.makeActor(linkedAthleteId: AthleteId())
        let route = AthleteShellRoute.route(
            legacyState: .connected(legacyActor),
            backendState: .connected(backendActor, verified: true)
        )
        #expect(route == .shell(actor: legacyActor))
    }

    @Test("neither connected routes to .gate")
    func neitherConnectedRoutesToGate() {
        let route = AthleteShellRoute.route(legacyState: .notConnected, backendState: .idle)
        #expect(route == .gate)
    }

    @Test("backend activating with legacy not connected routes to .gate")
    func backendActivatingRoutesToGate() {
        let route = AthleteShellRoute.route(legacyState: .notConnected, backendState: .activating)
        #expect(route == .gate)
    }

    @Test("backend recoveryRequired with legacy not connected routes to .gate")
    func backendRecoveryRequiredRoutesToGate() {
        let route = AthleteShellRoute.route(legacyState: .notConnected, backendState: .recoveryRequired)
        #expect(route == .gate)
    }

    // MARK: - AthleteConnectionGateView.showsScanButton(for:)
    //
    // PR #86 follow-up (lead review): `.lifecycleServiceNotReady`
    // previously shared `.notConnected`'s "Connect this app" / scan
    // instruction copy but showed no action — a dead end. This table
    // proves every gate-shown state (`.notConnected`, `.failed`,
    // `.lifecycleServiceNotReady`) now exposes the scan action, while
    // `.connecting` still shows none (no duplicate/re-entry action while
    // a scan is already resolving) and `.connected` shows none either
    // (structurally unreachable — `AthleteConnectionGateView` is only
    // ever presented for `AthleteShellRoute.gate`, which never includes
    // `.connected`).

    @Test("notConnected shows the scan action")
    func notConnectedShowsScanAction() {
        #expect(AthleteConnectionGateView.showsScanButton(for: .notConnected))
    }

    @Test("failed shows the scan action")
    func failedShowsScanAction() {
        let error = AthleteConnectionLifecycleError.shareAcceptanceOrResolutionFailed(
            NSError(domain: "test", code: 1)
        )
        #expect(AthleteConnectionGateView.showsScanButton(for: .failed(error)))
    }

    @Test("lifecycleServiceNotReady now shows the scan action, never a dead end")
    func lifecycleServiceNotReadyShowsScanAction() {
        #expect(AthleteConnectionGateView.showsScanButton(for: .lifecycleServiceNotReady))
    }

    @Test("connecting shows no duplicate/re-entry action")
    func connectingShowsNoScanAction() {
        #expect(!AthleteConnectionGateView.showsScanButton(for: .connecting))
    }

    @Test("connected shows no scan action")
    func connectedShowsNoScanAction() {
        #expect(!AthleteConnectionGateView.showsScanButton(for: .connected(Self.makeActor())))
    }

    // MARK: - AthleteDisplayIdentity.resolvedName(for:athleteRepository:)

    @Test("resolvedName prefers preferredName over givenName")
    @MainActor
    func resolvedNamePrefersPreferredName() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let workspaceId = WorkspaceId()
        let athlete = try athleteRepository.createAthlete(
            workspaceId: workspaceId,
            givenName: "Jonas",
            preferredName: "Jon",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )
        let actor = Self.makeActor(linkedAthleteId: athlete.id)

        #expect(AthleteDisplayIdentity.resolvedName(for: actor, athleteRepository: athleteRepository) == "Jon")
    }

    @Test("resolvedName falls back to givenName when there is no preferredName")
    @MainActor
    func resolvedNameFallsBackToGivenName() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let workspaceId = WorkspaceId()
        let athlete = try athleteRepository.createAthlete(
            workspaceId: workspaceId,
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )
        let actor = Self.makeActor(linkedAthleteId: athlete.id)

        #expect(AthleteDisplayIdentity.resolvedName(for: actor, athleteRepository: athleteRepository) == "Jonas")
    }

    @Test("resolvedName is nil, never fabricated, when the actor has no linked athlete")
    @MainActor
    func resolvedNameNilWhenNoLinkedAthlete() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let actor = Self.makeActor(linkedAthleteId: nil)

        #expect(AthleteDisplayIdentity.resolvedName(for: actor, athleteRepository: athleteRepository) == nil)
    }

    @Test("resolvedName is nil, never fabricated, when the linked athlete cannot be found")
    @MainActor
    func resolvedNameNilWhenAthleteNotFound() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let actor = Self.makeActor(linkedAthleteId: AthleteId())

        #expect(AthleteDisplayIdentity.resolvedName(for: actor, athleteRepository: athleteRepository) == nil)
    }
}
