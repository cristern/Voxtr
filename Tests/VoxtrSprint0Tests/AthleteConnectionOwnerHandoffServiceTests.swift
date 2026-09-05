import Testing
import Foundation
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrParentDomain

// Athlete Connection Foundation B2.6. `AthleteConnectionOwnerHandoffService
// .prepareInvitation(forAthlete:workspaceId:invitedBy:)` itself performs
// real CloudKit network I/O (via `FamilyWorkspaceOwnerShareCoordinator
// .ensureSharingRoot`/`ensureInvitationIntent`) and real SwiftData
// persistence, so — matching this repository's established B1/B2
// XCTEST-SAFETY convention — it is not exercised end-to-end here. What IS
// fully unit-testable is the PURE participant-matching decision it
// depends on, `matchingAthleteParticipants(athleteId:workspaceId:participants:)`,
// which takes an already-fetched `[WorkspaceParticipant]` array — no
// `ModelContext`/persistence I/O, no CloudKit I/O.
@Suite("AthleteConnectionOwnerHandoffService (Athlete Connection Foundation B2.6)")
struct AthleteConnectionOwnerHandoffServiceTests {

    private static func makeAthleteParticipant(
        id: UUID = UUID(),
        workspaceId: UUID,
        linkedAthleteId: UUID,
        state: ParticipantState = .active
    ) -> WorkspaceParticipant {
        WorkspaceParticipant(
            id: id,
            workspaceId: WorkspaceId(rawValue: workspaceId),
            accountId: .pending,
            role: .athlete,
            state: state,
            linkedAthleteId: AthleteId(rawValue: linkedAthleteId)
        )
    }

    @Test("No participant links to this athlete in this workspace resolves to .none — a new participant must be created")
    func noMatchResolvesToNone() {
        let workspaceId = WorkspaceId()
        let athleteId = AthleteId()
        let unrelated = Self.makeAthleteParticipant(workspaceId: workspaceId.rawValue, linkedAthleteId: UUID())

        let result = AthleteConnectionOwnerHandoffService.matchingAthleteParticipants(
            athleteId: athleteId,
            workspaceId: workspaceId,
            participants: [unrelated]
        )

        guard case .none = result else {
            Issue.record("Expected .none, got \(result)")
            return
        }
    }

    @Test("Exactly one existing participant linking to this athlete in this workspace resolves to .one, regardless of its current state — reused, never duplicated")
    func exactlyOneMatchResolvesToOneRegardlessOfState() {
        let workspaceId = WorkspaceId()
        let athleteId = AthleteId()
        for state: ParticipantState in [.invited, .active, .declined, .revoked] {
            let participant = Self.makeAthleteParticipant(workspaceId: workspaceId.rawValue, linkedAthleteId: athleteId.rawValue, state: state)

            let result = AthleteConnectionOwnerHandoffService.matchingAthleteParticipants(
                athleteId: athleteId,
                workspaceId: workspaceId,
                participants: [participant]
            )

            guard case .one(let matched) = result else {
                Issue.record("Expected .one for state \(state), got \(result)")
                return
            }
            #expect(matched.id == participant.id)
        }
    }

    @Test("A different athlete's participant in the SAME workspace is never matched — no cross-athlete confusion")
    func differentAthleteNeverMatched() {
        let workspaceId = WorkspaceId()
        let athleteId = AthleteId()
        let otherAthleteParticipant = Self.makeAthleteParticipant(workspaceId: workspaceId.rawValue, linkedAthleteId: UUID())

        let result = AthleteConnectionOwnerHandoffService.matchingAthleteParticipants(
            athleteId: athleteId,
            workspaceId: workspaceId,
            participants: [otherAthleteParticipant]
        )

        guard case .none = result else {
            Issue.record("Expected .none, got \(result)")
            return
        }
    }

    @Test("The SAME athlete's participant in a DIFFERENT workspace is never matched — workspace identity is part of the discriminator, not just athleteId")
    func differentWorkspaceNeverMatched() {
        let athleteId = AthleteId()
        let participantInOtherWorkspace = Self.makeAthleteParticipant(workspaceId: UUID(), linkedAthleteId: athleteId.rawValue)

        let result = AthleteConnectionOwnerHandoffService.matchingAthleteParticipants(
            athleteId: athleteId,
            workspaceId: WorkspaceId(),
            participants: [participantInOtherWorkspace]
        )

        guard case .none = result else {
            Issue.record("Expected .none, got \(result)")
            return
        }
    }

    @Test("Two WorkspaceParticipant fixtures both linking to the same athlete in the same workspace resolve to .duplicate rather than silently picking a first match")
    func duplicateParticipantsResolveToDuplicate() {
        let workspaceId = WorkspaceId()
        let athleteId = AthleteId()
        let first = Self.makeAthleteParticipant(workspaceId: workspaceId.rawValue, linkedAthleteId: athleteId.rawValue)
        let second = Self.makeAthleteParticipant(workspaceId: workspaceId.rawValue, linkedAthleteId: athleteId.rawValue)

        let result = AthleteConnectionOwnerHandoffService.matchingAthleteParticipants(
            athleteId: athleteId,
            workspaceId: workspaceId,
            participants: [first, second]
        )

        guard case .duplicate = result else {
            Issue.record("Expected .duplicate, got \(result)")
            return
        }
    }

    @Test("An empty participant list resolves to .none")
    func emptyParticipantListResolvesToNone() {
        let result = AthleteConnectionOwnerHandoffService.matchingAthleteParticipants(
            athleteId: AthleteId(),
            workspaceId: WorkspaceId(),
            participants: []
        )

        guard case .none = result else {
            Issue.record("Expected .none, got \(result)")
            return
        }
    }

    @Test("Two DIFFERENT athletes each with their own single participant in the same workspace both resolve to their own exact .one match — no cross-athlete mapping")
    func multipleDifferentAthletesEachResolveIndependently() {
        let workspaceId = WorkspaceId()
        let athleteA = AthleteId()
        let athleteB = AthleteId()
        let participantA = Self.makeAthleteParticipant(workspaceId: workspaceId.rawValue, linkedAthleteId: athleteA.rawValue)
        let participantB = Self.makeAthleteParticipant(workspaceId: workspaceId.rawValue, linkedAthleteId: athleteB.rawValue)

        let resultA = AthleteConnectionOwnerHandoffService.matchingAthleteParticipants(
            athleteId: athleteA, workspaceId: workspaceId, participants: [participantA, participantB]
        )
        let resultB = AthleteConnectionOwnerHandoffService.matchingAthleteParticipants(
            athleteId: athleteB, workspaceId: workspaceId, participants: [participantA, participantB]
        )

        guard case .one(let matchedA) = resultA else {
            Issue.record("Expected .one for athleteA, got \(resultA)")
            return
        }
        guard case .one(let matchedB) = resultB else {
            Issue.record("Expected .one for athleteB, got \(resultB)")
            return
        }
        #expect(matchedA.id == participantA.id)
        #expect(matchedB.id == participantB.id)
        #expect(matchedA.id != matchedB.id)
    }
}
