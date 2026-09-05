import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrParentDomain
import VoxtrAthleteDomain

// NOTE: like the other persistence-backed tests in this suite (see
// `FamilyRestorationServiceTests.swift`'s own header), the one test here
// that constructs a real `ModelContainer`
// (`realFamilyGraphBindsSuccessfullyAndMutatesNothing`) exercises @Model
// types through actual SwiftData persistence and requires the Xcode/
// macOS SwiftData runtime — written but not executed in this sandbox.
// Every other test below calls `AthleteConnectionIdentityBindingService
// .resolve(acceptedWorkspaceId:restorationState:)` directly — a pure,
// `nonisolated` function with no `ModelContext`/persistence I/O at all.
// Constructing `WorkspaceParticipant`/`AthleteProfile`/`FamilyWorkspace`/
// `ParentProfile` (`@Model` classes) WITHOUT ever inserting them into a
// `ModelContext` is itself just plain Swift object construction — no
// SwiftData runtime involved, matching this project's own established
// "pure value-type test" convention (see `CurrentSessionActorTests.swift`).
@Suite("AthleteConnectionIdentityBindingService (Athlete Connection Foundation B2.3)", .serialized)
struct AthleteConnectionIdentityBindingServiceTests {

    // MARK: - Fixture helpers (in-memory, never persisted)

    private static func makeWorkspace(id: UUID = UUID()) -> FamilyWorkspace {
        FamilyWorkspace(id: WorkspaceId(rawValue: id), displayName: "Test family", technicalOwnerAccountId: .pending)
    }

    private static func makeAthleteParticipant(
        id: UUID = UUID(),
        workspaceId: UUID,
        state: ParticipantState,
        linkedAthleteId: UUID? = UUID()
    ) -> WorkspaceParticipant {
        WorkspaceParticipant(
            id: id,
            workspaceId: WorkspaceId(rawValue: workspaceId),
            accountId: .pending,
            role: .athlete,
            state: state,
            linkedAthleteId: linkedAthleteId.map { AthleteId(rawValue: $0) }
        )
    }

    private static func makeAthlete(id: UUID, workspaceId: UUID) -> AthleteProfile {
        AthleteProfile(
            id: AthleteId(rawValue: id),
            workspaceId: WorkspaceId(rawValue: workspaceId),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )
    }

    private static func makeOwnerParticipant(workspaceId: UUID) -> WorkspaceParticipant {
        WorkspaceParticipant(
            workspaceId: WorkspaceId(rawValue: workspaceId),
            accountId: .pending,
            role: .workspaceOwner,
            state: .active,
            invitedAt: .now,
            acceptedAt: .now
        )
    }

    private static func makeFamily(
        workspace: FamilyWorkspace,
        athleteParticipants: [WorkspaceParticipant],
        athletes: [AthleteProfile]
    ) -> RestoredFamily {
        RestoredFamily(
            parent: ParentProfile(accountId: .pending, givenName: "Kari"),
            workspace: workspace,
            participant: makeOwnerParticipant(workspaceId: workspace.id),
            athletes: athletes,
            grants: [],
            athleteParticipants: athleteParticipants
        )
    }

    // MARK: - Pure resolve(acceptedWorkspaceId:restorationState:) tests

    @Test("A workspace with exactly one active, correctly-linked athlete participant binds to the correct stable IDs")
    func validWorkspaceParticipantAthleteBindsToCorrectIds() throws {
        let workspace = Self.makeWorkspace()
        let athleteId = UUID()
        let participant = Self.makeAthleteParticipant(workspaceId: workspace.id, state: .active, linkedAthleteId: athleteId)
        let athlete = Self.makeAthlete(id: athleteId, workspaceId: workspace.id)
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [participant], athletes: [athlete])

        let bound = try AthleteConnectionIdentityBindingService.resolve(
            acceptedWorkspaceId: workspace.id,
            intendedParticipantId: participant.id,
            restorationState: .existingFamily(family)
        )

        #expect(bound.workspaceId == workspace.workspaceId)
        #expect(bound.participantId == participant.id)
        #expect(bound.athleteId == AthleteId(rawValue: athleteId))
    }

    @Test("resolve(acceptedWorkspaceId:intendedParticipantId:restorationState:) is deterministic — repeated calls with identical inputs produce an identical BoundAthleteIdentity")
    func repeatedResolutionIsDeterministic() throws {
        let workspace = Self.makeWorkspace()
        let athleteId = UUID()
        let participant = Self.makeAthleteParticipant(workspaceId: workspace.id, state: .active, linkedAthleteId: athleteId)
        let athlete = Self.makeAthlete(id: athleteId, workspaceId: workspace.id)
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [participant], athletes: [athlete])
        let state = FamilyRestorationState.existingFamily(family)

        let first = try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: workspace.id, intendedParticipantId: participant.id, restorationState: state)
        let second = try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: workspace.id, intendedParticipantId: participant.id, restorationState: state)

        #expect(first == second)
    }

    @Test(".noExistingFamily fails explicitly with workspaceNotFound")
    func noExistingFamilyFailsWithWorkspaceNotFound() {
        #expect(throws: AthleteConnectionIdentityBindingError.workspaceNotFound) {
            try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: UUID(), intendedParticipantId: UUID(), restorationState: .noExistingFamily)
        }
    }

    @Test(".inconsistentGraph fails explicitly with localFamilyGraphInconsistent, preserving the original reason")
    func inconsistentGraphFailsWithReasonPreserved() {
        #expect(throws: AthleteConnectionIdentityBindingError.localFamilyGraphInconsistent(reason: "some specific rule failed")) {
            try AthleteConnectionIdentityBindingService.resolve(
                acceptedWorkspaceId: UUID(),
                intendedParticipantId: UUID(),
                restorationState: .inconsistentGraph(reason: "some specific rule failed")
            )
        }
    }

    @Test("An existingFamily whose workspace id does not match the accepted share's workspaceId fails with workspaceNotFound rather than binding to the wrong family")
    func mismatchedWorkspaceIdFailsWithWorkspaceNotFound() {
        let workspace = Self.makeWorkspace()
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [], athletes: [])

        #expect(throws: AthleteConnectionIdentityBindingError.workspaceNotFound) {
            try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: UUID(), intendedParticipantId: UUID(), restorationState: .existingFamily(family))
        }
    }

    @Test("No .athlete-role participant at all in the workspace fails with athleteParticipantNotFound")
    func noAthleteParticipantFailsExplicitly() {
        let workspace = Self.makeWorkspace()
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [], athletes: [])

        #expect(throws: AthleteConnectionIdentityBindingError.athleteParticipantNotFound) {
            try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: workspace.id, intendedParticipantId: UUID(), restorationState: .existingFamily(family))
        }
    }

    @Test("Athlete Connection Foundation B2.6: an intendedParticipantId that does not match ANY .athlete-role participant in the workspace fails with athleteParticipantNotFound, even when other athlete participants exist — never falls back to picking one of them")
    func nonMatchingIntendedParticipantIdFailsExplicitly() {
        let workspace = Self.makeWorkspace()
        let participant = Self.makeAthleteParticipant(workspaceId: workspace.id, state: .active)
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [participant], athletes: [])

        #expect(throws: AthleteConnectionIdentityBindingError.athleteParticipantNotFound) {
            try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: workspace.id, intendedParticipantId: UUID(), restorationState: .existingFamily(family))
        }
    }

    @Test("An .athlete-role participant that exists but is still .invited (not yet locally accepted) fails with participantNotEligible rather than being silently treated as usable")
    func invitedOnlyParticipantFailsAsNotEligible() {
        let workspace = Self.makeWorkspace()
        let participant = Self.makeAthleteParticipant(workspaceId: workspace.id, state: .invited)
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [participant], athletes: [])

        #expect(throws: AthleteConnectionIdentityBindingError.participantNotEligible) {
            try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: workspace.id, intendedParticipantId: participant.id, restorationState: .existingFamily(family))
        }
    }

    // Athlete Connection Foundation B2.6: this replaces the pre-B2.6
    // "two currently-.active participants fail as ambiguous" test — that
    // ambiguity is now CLOSED by the exact-ID discriminator (see the next
    // test), not merely narrowed. What remains a real, explicit failure
    // is two participants sharing the SAME `id` (structurally impossible
    // via a real repository fetch given `@Attribute(.unique)`, but
    // constructible as a pure in-memory fixture, matching this suite's
    // own established `duplicateAthleteIdFailsExplicitly` precedent).
    @Test("Two WorkspaceParticipant fixtures sharing the same id fail with duplicateWorkspaceParticipantIdentity rather than silently binding to the first match")
    func duplicateWorkspaceParticipantIdentityFailsExplicitly() {
        let workspace = Self.makeWorkspace()
        let sharedId = UUID()
        let athleteIdA = UUID()
        let athleteIdB = UUID()
        let first = Self.makeAthleteParticipant(id: sharedId, workspaceId: workspace.id, state: .active, linkedAthleteId: athleteIdA)
        let second = Self.makeAthleteParticipant(id: sharedId, workspaceId: workspace.id, state: .active, linkedAthleteId: athleteIdB)
        let athletes = [
            Self.makeAthlete(id: athleteIdA, workspaceId: workspace.id),
            Self.makeAthlete(id: athleteIdB, workspaceId: workspace.id),
        ]
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [first, second], athletes: athletes)

        #expect(throws: AthleteConnectionIdentityBindingError.duplicateWorkspaceParticipantIdentity) {
            try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: workspace.id, intendedParticipantId: sharedId, restorationState: .existingFamily(family))
        }
    }

    @Test("Athlete Connection Foundation B2.6: two DIFFERENT currently-.active .athlete-role participants in the same workspace no longer cause failure — the exact intendedParticipantId resolves to precisely the one it names, never the other, closing B2.3's original ambiguity gap")
    func resolvesExactIntendedParticipantAmongMultipleActiveParticipants() throws {
        let workspace = Self.makeWorkspace()
        let athleteIdA = UUID()
        let athleteIdB = UUID()
        let participantA = Self.makeAthleteParticipant(workspaceId: workspace.id, state: .active, linkedAthleteId: athleteIdA)
        let participantB = Self.makeAthleteParticipant(workspaceId: workspace.id, state: .active, linkedAthleteId: athleteIdB)
        let athletes = [
            Self.makeAthlete(id: athleteIdA, workspaceId: workspace.id),
            Self.makeAthlete(id: athleteIdB, workspaceId: workspace.id),
        ]
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [participantA, participantB], athletes: athletes)

        let bound = try AthleteConnectionIdentityBindingService.resolve(
            acceptedWorkspaceId: workspace.id,
            intendedParticipantId: participantB.id,
            restorationState: .existingFamily(family)
        )

        #expect(bound.participantId == participantB.id)
        #expect(bound.participantId != participantA.id)
        #expect(bound.athleteId == AthleteId(rawValue: athleteIdB))
    }

    // NOTE: there is deliberately no test constructing an eligible
    // (.athlete, .active) participant with `linkedAthleteId == nil`.
    // `WorkspaceParticipant`'s own canonical initializer (ParentEntities
    // .swift) enforces `precondition(role != .athlete || linkedAthleteId
    // != nil, ...)` — that state cannot be constructed at all, not even
    // as a pure in-memory fixture, so a test attempting it would crash
    // the test process rather than exercise `resolve(...)`. See
    // `AthleteConnectionIdentityBindingService.resolve`'s own comment
    // at the `linkedAthleteId` access for how this is handled in
    // production code.

    @Test("An eligible participant whose linkedAthleteId does not resolve to any AthleteProfile in the family fails with athleteNotFound")
    func unresolvedAthleteLinkFailsExplicitly() {
        let workspace = Self.makeWorkspace()
        let participant = Self.makeAthleteParticipant(workspaceId: workspace.id, state: .active, linkedAthleteId: UUID())
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [participant], athletes: [])

        #expect(throws: AthleteConnectionIdentityBindingError.athleteNotFound) {
            try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: workspace.id, intendedParticipantId: participant.id, restorationState: .existingFamily(family))
        }
    }

    @Test("Two AthleteProfile entries sharing the same id fail with duplicateAthleteIdentity rather than silently binding to the first match")
    func duplicateAthleteIdFailsExplicitly() {
        let workspace = Self.makeWorkspace()
        let athleteId = UUID()
        let participant = Self.makeAthleteParticipant(workspaceId: workspace.id, state: .active, linkedAthleteId: athleteId)
        let duplicateAthletes = [
            Self.makeAthlete(id: athleteId, workspaceId: workspace.id),
            Self.makeAthlete(id: athleteId, workspaceId: workspace.id),
        ]
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [participant], athletes: duplicateAthletes)

        #expect(throws: AthleteConnectionIdentityBindingError.duplicateAthleteIdentity) {
            try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: workspace.id, intendedParticipantId: participant.id, restorationState: .existingFamily(family))
        }
    }

    @Test("A resolved AthleteProfile whose own workspaceId does not match the accepted share's workspaceId fails with athleteWorkspaceMismatch")
    func athleteWorkspaceMismatchFailsExplicitly() {
        let workspace = Self.makeWorkspace()
        let athleteId = UUID()
        let participant = Self.makeAthleteParticipant(workspaceId: workspace.id, state: .active, linkedAthleteId: athleteId)
        // Deliberately built with a DIFFERENT workspaceId than the family's own.
        let athlete = Self.makeAthlete(id: athleteId, workspaceId: UUID())
        let family = Self.makeFamily(workspace: workspace, athleteParticipants: [participant], athletes: [athlete])

        #expect(throws: AthleteConnectionIdentityBindingError.athleteWorkspaceMismatch) {
            try AthleteConnectionIdentityBindingService.resolve(acceptedWorkspaceId: workspace.id, intendedParticipantId: participant.id, restorationState: .existingFamily(family))
        }
    }

    // MARK: - Real persistence integration test

    @Test("A real family created via the canonical onboarding + invitation + acceptance services binds successfully, produces the correct stable IDs, and creates/mutates nothing")
    @MainActor
    func realFamilyGraphBindsSuccessfullyAndMutatesNothing() throws {
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
            Issue.record("Expected .accepted")
            return
        }

        let participantCountBefore = try parentWorkspaceRepository.fetchAllParticipants().count
        let athleteCountBefore = try athleteRepository.fetchAllAthletes().count
        let workspaceCountBefore = try parentWorkspaceRepository.fetchAllWorkspaces().count

        let restorationService = FamilyRestorationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let bindingService = AthleteConnectionIdentityBindingService(familyRestorationService: restorationService)

        let bound = try bindingService.bind(acceptedWorkspaceId: created.workspace.id, intendedParticipantId: acceptedParticipant.id)

        #expect(bound.workspaceId == created.workspace.workspaceId)
        #expect(bound.participantId == acceptedParticipant.id)
        #expect(bound.athleteId == created.athlete.athleteId)

        #expect(try parentWorkspaceRepository.fetchAllParticipants().count == participantCountBefore)
        #expect(try athleteRepository.fetchAllAthletes().count == athleteCountBefore)
        #expect(try parentWorkspaceRepository.fetchAllWorkspaces().count == workspaceCountBefore)
    }
}
