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
