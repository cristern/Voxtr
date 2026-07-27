import Testing
import Foundation
import VoxtrCoreContracts
import VoxtrParentDomain

@Suite("AthleteParticipantEligibilityService (VX-035)", .serialized)
struct AthleteParticipantEligibilityServiceTests {

    private static let workspaceId = WorkspaceId()

    private static func makeFacts(
        workspaceId: WorkspaceId = workspaceId,
        isArchived: Bool = false
    ) -> AthleteEligibilityFacts {
        AthleteEligibilityFacts(workspaceId: workspaceId, isArchived: isArchived)
    }

    // MARK: - Eligible

    @Test("An active, non-archived athlete in the correct workspace with no existing participant is eligible")
    func eligibleAthleteIsEligible() {
        let service = AthleteParticipantEligibilityService()
        let facts = Self.makeFacts()

        let result = service.evaluate(athlete: facts, workspaceId: Self.workspaceId, hasExistingParticipant: false)

        #expect(result == .eligible)
    }

    // MARK: - Missing athlete

    @Test("A nil athlete is not eligible, with .athleteNotFound as the primary reason and no additional reasons")
    func missingAthleteIsNotEligible() {
        let service = AthleteParticipantEligibilityService()

        let result = service.evaluate(athlete: nil, workspaceId: Self.workspaceId, hasExistingParticipant: false)

        #expect(result == .notEligible(primaryReason: .athleteNotFound, additionalReasons: []))
    }

    @Test("A missing athlete's result is never combined with other reasons, even when other inputs would also fail")
    func missingAthleteReasonIsExclusive() {
        let service = AthleteParticipantEligibilityService()

        let result = service.evaluate(athlete: nil, workspaceId: Self.workspaceId, hasExistingParticipant: true)

        #expect(result == .notEligible(primaryReason: .athleteNotFound, additionalReasons: []))
    }

    // MARK: - Archived athlete

    @Test("An archived athlete is not eligible, with .athleteArchived as the primary reason")
    func archivedAthleteIsNotEligible() {
        let service = AthleteParticipantEligibilityService()
        let facts = Self.makeFacts(isArchived: true)

        let result = service.evaluate(athlete: facts, workspaceId: Self.workspaceId, hasExistingParticipant: false)

        #expect(result == .notEligible(primaryReason: .athleteArchived, additionalReasons: []))
    }

    // MARK: - Workspace mismatch

    @Test("An athlete belonging to a different workspace is not eligible, with .athleteNotInWorkspace as the primary reason")
    func athleteInDifferentWorkspaceIsNotEligible() {
        let service = AthleteParticipantEligibilityService()
        let otherWorkspaceId = WorkspaceId()
        let facts = Self.makeFacts(workspaceId: otherWorkspaceId)

        let result = service.evaluate(athlete: facts, workspaceId: Self.workspaceId, hasExistingParticipant: false)

        #expect(result == .notEligible(primaryReason: .athleteNotInWorkspace, additionalReasons: []))
    }

    // MARK: - Existing participant

    @Test("An athlete who already has a WorkspaceParticipant is not eligible, with .participantAlreadyExists as the primary reason")
    func duplicateParticipantIsNotEligible() {
        let service = AthleteParticipantEligibilityService()
        let facts = Self.makeFacts()

        let result = service.evaluate(athlete: facts, workspaceId: Self.workspaceId, hasExistingParticipant: true)

        #expect(result == .notEligible(primaryReason: .participantAlreadyExists, additionalReasons: []))
    }

    // MARK: - Multiple reasons

    @Test("Two simultaneously failing rules report the first as primary and the second as an additional reason")
    func twoFailingRulesReportPrimaryAndAdditional() {
        let service = AthleteParticipantEligibilityService()
        let facts = Self.makeFacts(isArchived: true)

        let result = service.evaluate(athlete: facts, workspaceId: Self.workspaceId, hasExistingParticipant: true)

        #expect(result == .notEligible(primaryReason: .athleteArchived, additionalReasons: [.participantAlreadyExists]))
    }

    @Test("All three non-exclusive rules can fail together, reported in fixed order")
    func allThreeNonExclusiveRulesCanFailTogether() {
        let service = AthleteParticipantEligibilityService()
        let otherWorkspaceId = WorkspaceId()
        let facts = Self.makeFacts(workspaceId: otherWorkspaceId, isArchived: true)

        let result = service.evaluate(athlete: facts, workspaceId: Self.workspaceId, hasExistingParticipant: true)

        #expect(result == .notEligible(
            primaryReason: .athleteArchived,
            additionalReasons: [.athleteNotInWorkspace, .participantAlreadyExists]
        ))
    }

    // MARK: - Deterministic ordering

    @Test("Reason ordering is always athleteArchived, then athleteNotInWorkspace, then participantAlreadyExists, regardless of which rules fail")
    func reasonOrderingIsFixedRegardlessOfWhichRulesFail() {
        let service = AthleteParticipantEligibilityService()
        let otherWorkspaceId = WorkspaceId()
        let facts = Self.makeFacts(workspaceId: otherWorkspaceId, isArchived: true)

        let result = service.evaluate(athlete: facts, workspaceId: Self.workspaceId, hasExistingParticipant: true)

        guard case .notEligible(let primary, let additional) = result else {
            Issue.record("Expected .notEligible")
            return
        }
        #expect(primary == .athleteArchived)
        #expect(additional == [.athleteNotInWorkspace, .participantAlreadyExists])
    }

    // MARK: - Determinism

    @Test("Evaluating the same input repeatedly always produces an identical result")
    func repeatedEvaluationIsDeterministic() {
        let service = AthleteParticipantEligibilityService()
        let facts = Self.makeFacts()

        let first = service.evaluate(athlete: facts, workspaceId: Self.workspaceId, hasExistingParticipant: false)
        let second = service.evaluate(athlete: facts, workspaceId: Self.workspaceId, hasExistingParticipant: false)
        let third = service.evaluate(athlete: facts, workspaceId: Self.workspaceId, hasExistingParticipant: false)

        #expect(first == second)
        #expect(second == third)
    }

    // MARK: - evaluateForAcceptance (VX-037, ADR-0002)

    @Test("evaluateForAcceptance: an eligible athlete is eligible")
    func evaluateForAcceptanceEligibleAthleteIsEligible() {
        let service = AthleteParticipantEligibilityService()
        let facts = Self.makeFacts()

        let result = service.evaluateForAcceptance(athlete: facts, workspaceId: Self.workspaceId)

        #expect(result == .eligible)
    }

    @Test("evaluateForAcceptance: a nil athlete is not eligible, with .athleteNotFound only")
    func evaluateForAcceptanceMissingAthleteIsNotEligible() {
        let service = AthleteParticipantEligibilityService()

        let result = service.evaluateForAcceptance(athlete: nil, workspaceId: Self.workspaceId)

        #expect(result == .notEligible(primaryReason: .athleteNotFound, additionalReasons: []))
    }

    @Test("evaluateForAcceptance: an archived athlete is not eligible, with .athleteArchived")
    func evaluateForAcceptanceArchivedAthleteIsNotEligible() {
        let service = AthleteParticipantEligibilityService()
        let facts = Self.makeFacts(isArchived: true)

        let result = service.evaluateForAcceptance(athlete: facts, workspaceId: Self.workspaceId)

        #expect(result == .notEligible(primaryReason: .athleteArchived, additionalReasons: []))
    }

    @Test("evaluateForAcceptance: a workspace mismatch is not eligible, with .athleteNotInWorkspace")
    func evaluateForAcceptanceWorkspaceMismatchIsNotEligible() {
        let service = AthleteParticipantEligibilityService()
        let otherWorkspaceId = WorkspaceId()
        let facts = Self.makeFacts(workspaceId: otherWorkspaceId)

        let result = service.evaluateForAcceptance(athlete: facts, workspaceId: Self.workspaceId)

        #expect(result == .notEligible(primaryReason: .athleteNotInWorkspace, additionalReasons: []))
    }

    @Test("evaluateForAcceptance has no way to report .participantAlreadyExists — it takes no hasExistingParticipant input at all, unlike evaluate(_:)")
    func evaluateForAcceptanceNeverReportsParticipantAlreadyExists() {
        // This test exists to make the design decision explicit and
        // regression-proof: evaluateForAcceptance's signature itself
        // (no hasExistingParticipant parameter) makes reporting this
        // reason structurally impossible here, not just behaviorally
        // avoided — the existence of the participant being accepted is
        // the precondition, never a disqualifier, at this call site.
        let service = AthleteParticipantEligibilityService()
        let facts = Self.makeFacts()

        let result = service.evaluateForAcceptance(athlete: facts, workspaceId: Self.workspaceId)

        #expect(result == .eligible)
    }
}
