import Testing
import Foundation
import SwiftData
import VoxtrCoreContracts
import VoxtrParentAuthentication
import VoxtrParentDomain
import VoxtrAthleteDomain
@testable import VoxtrAppShell
@testable import VoxtrCore

// Parent hydration-upload integration: exercises
// `ParentHydrationUploadService.resolveProjection(...)` against a REAL
// `ParentWorkspaceRepository`/`AthleteRepository` backed by an in-memory
// `ModelContainer` — this codebase's own established convention for
// repository-dependent orchestration tests (see
// `AthleteDeviceAuthorizationInvitationCoordinatorTests.swift`'s own
// header note). The whole point of this service's own corrected
// workspace-scoping (see its own doc comment) only shows up with a
// REAL repository holding REAL rows — a mock would just assert
// whatever the mock was told to return.
private final class NeverCalledTransport: ParentAuthenticationTransport, @unchecked Sendable {
    struct UnexpectedCall: Error {}
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw UnexpectedCall()
    }
}

private final class NoOpSessionStore: ParentSessionStoring, @unchecked Sendable {
    func loadToken() -> String? { nil }
    func saveToken(_ token: String) throws {}
    func deleteToken() {}
}

// `.serialized`: matches `AthleteDeviceAuthorizationInvitationCoordinatorTests.swift` and
// `ParentAuthenticationServiceTests.swift` — each test builds its own in-memory
// `ModelContainer` via `InMemoryPersistenceController`, and concurrent construction of
// multiple SwiftData containers from parallel test execution is a known source of
// nondeterministic failures/hangs, not just a data race on shared fixture state.
@Suite(.serialized)
@MainActor
struct ParentHydrationUploadServiceTests {

    private struct Fixture {
        let container: ModelContainer
        let service: ParentHydrationUploadService
        let parentWorkspaceRepository: ParentWorkspaceRepository
        let parent: ParentProfile
        let workspace: FamilyWorkspace
        let ownerParticipant: WorkspaceParticipant
        let athlete: AthleteProfile
        let athleteParticipant: WorkspaceParticipant
    }

    /// Builds one real family graph: Parent → Workspace → owner
    /// `WorkspaceParticipant` → `AthleteProfile`, plus the athlete's own
    /// `.athlete`-role `WorkspaceParticipant` (created via
    /// `createInvitedAthleteParticipant`, the SAME canonical path every
    /// real invitation flow in this codebase uses — never hand-rolled).
    private static func makeFixture(
        container: ModelContainer? = nil,
        parentGivenName: String = "Kari",
        athleteGivenName: String = "Jonas"
    ) throws -> Fixture {
        let resolvedContainer: ModelContainer
        if let container {
            resolvedContainer = container
        } else {
            let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
            resolvedContainer = try controller.makeModelContainer()
        }
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: resolvedContainer.mainContext)
        let athleteRepository = AthleteRepository(modelContext: resolvedContainer.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: resolvedContainer.mainContext)
        let onboardingCoordinator = FamilyOnboardingCoordinator(
            modelContext: resolvedContainer.mainContext,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let created = try onboardingCoordinator.createFamily(
            parentGivenName: parentGivenName,
            athleteGivenName: athleteGivenName,
            athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
            athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            athleteDevelopmentStage: .parentLed
        )
        let athleteParticipant = try parentWorkspaceRepository.createInvitedAthleteParticipant(
            workspaceId: created.workspace.workspaceId,
            linkedAthleteId: created.athlete.athleteId,
            invitedBy: ActorId(rawValue: created.participant.id)
        )
        let parentAuthenticationService = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: URL(string: "https://parent-auth.invalid/functions/v1")!),
            transport: NeverCalledTransport(),
            sessionStore: NoOpSessionStore()
        )
        let service = ParentHydrationUploadService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            parentAuthenticationService: parentAuthenticationService
        )
        return Fixture(
            container: resolvedContainer,
            service: service,
            parentWorkspaceRepository: parentWorkspaceRepository,
            parent: created.parent,
            workspace: created.workspace,
            ownerParticipant: created.participant,
            athlete: created.athlete,
            athleteParticipant: athleteParticipant
        )
    }

    @Test("resolveProjection() returns the exact 11-field canonical payload for a real family graph — no made-up/placeholder values")
    func resolveProjectionReturnsCorrectPayload() throws {
        let fixture = try Self.makeFixture()

        let payload = try fixture.service.resolveProjection(
            workspaceId: fixture.workspace.workspaceId,
            intendedParticipantId: fixture.athleteParticipant.id,
            intendedAthleteId: fixture.athlete.athleteId
        )

        #expect(payload.workspaceId == fixture.workspace.workspaceId.rawValue)
        #expect(payload.intendedParticipantId == fixture.athleteParticipant.id)
        #expect(payload.intendedAthleteId == fixture.athlete.athleteId.rawValue)
        #expect(payload.parentId == fixture.parent.id)
        #expect(payload.parentGivenName == "Kari")
        #expect(payload.workspaceDisplayName == fixture.workspace.displayName)
        #expect(payload.ownerParticipantId == fixture.ownerParticipant.id)
        #expect(payload.athleteGivenName == "Jonas")
        #expect(payload.athleteBirthDateISO == fixture.athlete.birthDate.isoString)
        #expect(payload.athleteTimeZoneId == fixture.athlete.timeZoneId.rawValue)
        #expect(payload.athleteDevelopmentStage == fixture.athlete.developmentStage.rawValue)
    }

    @Test("resolveProjection() rejects an intended participant that does not exist at all")
    func resolveProjectionRejectsMissingParticipant() throws {
        let fixture = try Self.makeFixture()

        #expect(throws: ParentHydrationProjectionError.self) {
            try fixture.service.resolveProjection(
                workspaceId: fixture.workspace.workspaceId,
                intendedParticipantId: UUID(),
                intendedAthleteId: fixture.athlete.athleteId
            )
        }
    }

    @Test("resolveProjection() rejects the OWNER participant's own id as the intended participant — role mismatch, never silently accepted")
    func resolveProjectionRejectsOwnerParticipantAsIntendedParticipant() throws {
        let fixture = try Self.makeFixture()

        #expect(throws: ParentHydrationProjectionError.self) {
            try fixture.service.resolveProjection(
                workspaceId: fixture.workspace.workspaceId,
                intendedParticipantId: fixture.ownerParticipant.id,
                intendedAthleteId: fixture.athlete.athleteId
            )
        }
    }

    @Test("resolveProjection() rejects a mismatched intendedAthleteId for an otherwise-real athlete participant — never resolved by participant alone")
    func resolveProjectionRejectsAthleteLinkMismatch() throws {
        let fixture = try Self.makeFixture()

        #expect(throws: ParentHydrationProjectionError.self) {
            try fixture.service.resolveProjection(
                workspaceId: fixture.workspace.workspaceId,
                intendedParticipantId: fixture.athleteParticipant.id,
                intendedAthleteId: AthleteId()
            )
        }
    }

    // MARK: - Workspace isolation (the actual fix this task's brief asked for)

    /// Every family created via `createParentAndWorkspace`/`createFamily`
    /// starts with `accountId: .pending` on BOTH the `ParentProfile` and
    /// its owner `WorkspaceParticipant` (see `ParentWorkspaceRepository`'s
    /// own doc comment: "CloudKit account resolution doesn't exist yet") —
    /// a single, non-unique sentinel shared by every local family until a
    /// real SIWA/CloudKit account is linked. `resolveProjection`'s
    /// accountId-based Parent lookup (the same relationship
    /// `FamilyMembership.derive(...)` already treats as canonical) is
    /// only MEANINGFULLY scoped once accounts are actually distinct —
    /// this helper simulates that post-linking state directly, rather
    /// than inventing a new, not-yet-real identity mechanism.
    private static func linkDistinctAccount(_ accountId: AccountId, parent: ParentProfile, ownerParticipant: WorkspaceParticipant, container: ModelContainer) throws {
        parent.accountId = accountId.rawValue
        ownerParticipant.accountId = accountId.rawValue
        try container.mainContext.save()
    }

    @Test("resolveProjection() for workspace A never resolves workspace B's owner/Parent — WORKSPACE-SCOPED, unlike AthleteConnectionOwnerHandoffService's own bare first-match lookups — once each family has its own DISTINCT linked account")
    func resolveProjectionIsScopedToTheExactWorkspaceNeverASiblingOne() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()

        // TWO independent families/workspaces in the SAME local store —
        // the exact shape a bare `allParticipants.first(where: role ==
        // .workspaceOwner)` / `parents.first` would get wrong. Each is
        // given its OWN distinct linked account (see `linkDistinctAccount`
        // doc comment) — the realistic post-SIWA-linking state this
        // isolation guarantee is actually meant to hold for.
        let familyA = try Self.makeFixture(container: container, parentGivenName: "Kari", athleteGivenName: "Jonas")
        let familyB = try Self.makeFixture(container: container, parentGivenName: "Per", athleteGivenName: "Nora")
        try Self.linkDistinctAccount(AccountId(rawValue: "account-a"), parent: familyA.parent, ownerParticipant: familyA.ownerParticipant, container: container)
        try Self.linkDistinctAccount(AccountId(rawValue: "account-b"), parent: familyB.parent, ownerParticipant: familyB.ownerParticipant, container: container)

        let payloadForA = try familyA.service.resolveProjection(
            workspaceId: familyA.workspace.workspaceId,
            intendedParticipantId: familyA.athleteParticipant.id,
            intendedAthleteId: familyA.athlete.athleteId
        )
        #expect(payloadForA.parentId == familyA.parent.id)
        #expect(payloadForA.parentGivenName == "Kari")
        #expect(payloadForA.ownerParticipantId == familyA.ownerParticipant.id)
        #expect(payloadForA.workspaceDisplayName == familyA.workspace.displayName)

        let payloadForB = try familyB.service.resolveProjection(
            workspaceId: familyB.workspace.workspaceId,
            intendedParticipantId: familyB.athleteParticipant.id,
            intendedAthleteId: familyB.athlete.athleteId
        )
        #expect(payloadForB.parentId == familyB.parent.id)
        #expect(payloadForB.parentGivenName == "Per")
        #expect(payloadForB.ownerParticipantId == familyB.ownerParticipant.id)
        #expect(payloadForB.workspaceDisplayName == familyB.workspace.displayName)

        // Cross-check: resolving family A's own intended participant
        // against family B's workspaceId must fail with a workspace
        // mismatch, never silently resolve using family B's owner/Parent.
        #expect(throws: ParentHydrationProjectionError.self) {
            try familyA.service.resolveProjection(
                workspaceId: familyB.workspace.workspaceId,
                intendedParticipantId: familyA.athleteParticipant.id,
                intendedAthleteId: familyA.athlete.athleteId
            )
        }
    }

    @Test("resolveProjection() fails closed — never guesses — when two local ParentProfiles genuinely share the same accountId (the real pre-SIWA-linking default): review finding, do not remove this rejection to make isolation 'pass'")
    func resolveProjectionFailsClosedWhenTwoParentProfilesGenuinelyShareTheSameAccountId() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()

        // Deliberately NOT calling `linkDistinctAccount` here — both
        // families are left at their real default (`accountId: .pending`,
        // shared, non-unique). This is the actual current-day local state
        // for any two families before CloudKit account linking exists;
        // resolving "the" Parent for workspace A by accountId alone is
        // genuinely ambiguous in this state, and must be rejected rather
        // than silently picking family A's own profile because it happens
        // to be `.first`.
        let familyA = try Self.makeFixture(container: container, parentGivenName: "Kari", athleteGivenName: "Jonas")
        _ = try Self.makeFixture(container: container, parentGivenName: "Per", athleteGivenName: "Nora")

        #expect(throws: ParentHydrationProjectionError.self) {
            try familyA.service.resolveProjection(
                workspaceId: familyA.workspace.workspaceId,
                intendedParticipantId: familyA.athleteParticipant.id,
                intendedAthleteId: familyA.athlete.athleteId
            )
        }
    }

    @Test("resolveProjection() rejects an intended participant in workspace A that links to an AthleteProfile actually belonging to workspace B — never uploads the wrong workspace's athlete fields")
    func resolveProjectionRejectsAthleteProfileWorkspaceMismatchAcrossWorkspaces() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()

        let familyA = try Self.makeFixture(container: container, parentGivenName: "Kari", athleteGivenName: "Jonas")
        let familyB = try Self.makeFixture(container: container, parentGivenName: "Per", athleteGivenName: "Nora")

        // `createInvitedAthleteParticipant` performs no cross-check
        // between `workspaceId` and `linkedAthleteId` — nothing stops a
        // caller from constructing exactly this inconsistent combination.
        // A participant scoped to workspace A, but linked to workspace
        // B's own athlete profile.
        let parentWorkspaceRepository = familyA.parentWorkspaceRepository
        let crossLinkedParticipant = try parentWorkspaceRepository.createInvitedAthleteParticipant(
            workspaceId: familyA.workspace.workspaceId,
            linkedAthleteId: familyB.athlete.athleteId,
            invitedBy: ActorId(rawValue: familyA.ownerParticipant.id)
        )

        #expect(throws: ParentHydrationProjectionError.self) {
            try familyA.service.resolveProjection(
                workspaceId: familyA.workspace.workspaceId,
                intendedParticipantId: crossLinkedParticipant.id,
                intendedAthleteId: familyB.athlete.athleteId
            )
        }
    }

    @Test("resolveProjection() rejects a duplicate .workspaceOwner participant for the exact same workspace, rather than silently picking a first match")
    func resolveProjectionRejectsDuplicateOwnerParticipant() throws {
        let fixture = try Self.makeFixture()

        // Structurally shouldn't happen via any canonical creation path
        // in this codebase — inserted directly into the SAME container's
        // `mainContext` (not through the repository, which has no
        // method that would ever create a second owner) to prove the
        // defensive check actually fires rather than silently reusing a
        // first match, the same precedent `AthleteSessionActivationService`'s
        // own `localIdentityGraphInconsistent` test establishes.
        let secondOwner = WorkspaceParticipant(
            workspaceId: fixture.workspace.workspaceId,
            accountId: AccountId(rawValue: fixture.ownerParticipant.accountId),
            role: .workspaceOwner,
            state: .active
        )
        fixture.container.mainContext.insert(secondOwner)
        try fixture.container.mainContext.save()

        #expect(throws: ParentHydrationProjectionError.self) {
            try fixture.service.resolveProjection(
                workspaceId: fixture.workspace.workspaceId,
                intendedParticipantId: fixture.athleteParticipant.id,
                intendedAthleteId: fixture.athlete.athleteId
            )
        }
    }
}
