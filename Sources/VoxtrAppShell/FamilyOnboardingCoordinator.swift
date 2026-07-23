import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain

/// S1.2a: orchestrates the full "create a family" flow — parent
/// profile, workspace, the parent's own participant record, the first
/// athlete, and the access grant connecting them — as ONE atomic
/// operation. This coordination can only live in `VoxtrAppShell`: it's
/// the only place in the codebase allowed to import both
/// `VoxtrParentDomain` and `VoxtrAthleteDomain` (same rule
/// `ModuleRegistry.swift` documents for itself).
///
/// TRANSACTION DESIGN: all five entities are inserted into the SAME
/// `ModelContext` via each repository's `stage...` method (insert only,
/// no save — see S1.2a additions to `ParentWorkspaceRepository`,
/// `AthleteRepository`, `AthleteAccessGrantRepository`). This
/// coordinator, not the repositories, controls the transaction boundary:
/// - `modelContext.autosaveEnabled` is turned off for the duration of
///   the operation (restored via `defer` on every exit path), so
///   SwiftData cannot flush a partial graph to the store on its own
///   schedule between staging steps.
/// - A single `modelContext.save()` call at the end persists all five
///   entities together.
/// - Any failure — a staging step, or `save()` itself — is caught, and
///   `modelContext.rollback()` discards every staged-but-unsaved change
///   on the context before the error is re-thrown. Nothing partial is
///   ever left in the store.
///
/// Out of scope for S1.2a, per the approved scope: no UI calls this yet
/// (S1.4), no athlete `WorkspaceParticipant` is created (confirmed out
/// of scope for Sprint 1 entirely), no family-restoration logic (S1.3),
/// no input validation layer (deferred).
@MainActor
public final class FamilyOnboardingCoordinator {
    private let modelContext: ModelContext
    private let parentWorkspaceRepository: ParentWorkspaceRepository
    private let athleteRepository: AthleteRepository
    private let athleteAccessGrantRepository: AthleteAccessGrantRepository

    public init(
        modelContext: ModelContext,
        parentWorkspaceRepository: ParentWorkspaceRepository,
        athleteRepository: AthleteRepository,
        athleteAccessGrantRepository: AthleteAccessGrantRepository
    ) {
        self.modelContext = modelContext
        self.parentWorkspaceRepository = parentWorkspaceRepository
        self.athleteRepository = athleteRepository
        self.athleteAccessGrantRepository = athleteAccessGrantRepository
    }

    public struct Result {
        public let parent: ParentProfile
        public let workspace: FamilyWorkspace
        public let participant: WorkspaceParticipant
        public let athlete: AthleteProfile
        public let grant: AthleteAccessGrant
    }

    /// Internal-only failure-injection points, used exclusively by
    /// `@testable import` tests to prove rollback behavior at specific
    /// stages of the operation (requirement 6's test list needs
    /// deterministic control over exactly when the failure happens —
    /// not exposed on the public API, which never simulates failure).
    enum FailurePoint {
        case afterParentAndWorkspaceStaged
        case afterAthleteStaged
        case afterGrantStaged
    }

    struct SimulatedFailure: Error {}

    public func createFamily(
        parentGivenName: String,
        parentFamilyName: String? = nil,
        parentPreferredName: String? = nil,
        athleteGivenName: String,
        athleteFamilyName: String? = nil,
        athletePreferredName: String? = nil,
        athleteBirthDate: LocalDate,
        athleteTimeZoneId: TimeZoneId,
        athleteDevelopmentStage: DevelopmentStage
    ) throws -> Result {
        try createFamily(
            parentGivenName: parentGivenName,
            parentFamilyName: parentFamilyName,
            parentPreferredName: parentPreferredName,
            athleteGivenName: athleteGivenName,
            athleteFamilyName: athleteFamilyName,
            athletePreferredName: athletePreferredName,
            athleteBirthDate: athleteBirthDate,
            athleteTimeZoneId: athleteTimeZoneId,
            athleteDevelopmentStage: athleteDevelopmentStage,
            failAt: nil
        )
    }

    func createFamily(
        parentGivenName: String,
        parentFamilyName: String? = nil,
        parentPreferredName: String? = nil,
        athleteGivenName: String,
        athleteFamilyName: String? = nil,
        athletePreferredName: String? = nil,
        athleteBirthDate: LocalDate,
        athleteTimeZoneId: TimeZoneId,
        athleteDevelopmentStage: DevelopmentStage,
        failAt: FailurePoint?,
        forcedParentId: UUID? = nil
    ) throws -> Result {
        // Requirement 7: no autosave flush can persist a partial graph
        // while we're mid-operation. Restored on every exit path.
        let previousAutosaveSetting = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        defer { modelContext.autosaveEnabled = previousAutosaveSetting }

        do {
            let staged: (parent: ParentProfile, workspace: FamilyWorkspace, participant: WorkspaceParticipant)
            if let forcedParentId {
                // Test-only seam: forces a genuine SwiftData uniqueness
                // violation at save() time, rather than a simulated
                // error, to prove rollback works against a real
                // persistence-layer failure — not just a thrown Swift
                // error at an arbitrary point.
                staged = parentWorkspaceRepository.stageParentAndWorkspace(
                    parentId: forcedParentId,
                    givenName: parentGivenName,
                    familyName: parentFamilyName,
                    preferredName: parentPreferredName
                )
            } else {
                staged = parentWorkspaceRepository.stageParentAndWorkspace(
                    givenName: parentGivenName,
                    familyName: parentFamilyName,
                    preferredName: parentPreferredName
                )
            }
            if failAt == .afterParentAndWorkspaceStaged { throw SimulatedFailure() }

            let athlete = athleteRepository.stageAthlete(
                workspaceId: staged.workspace.workspaceId,
                givenName: athleteGivenName,
                familyName: athleteFamilyName,
                preferredName: athletePreferredName,
                birthDate: athleteBirthDate,
                timeZoneId: athleteTimeZoneId,
                developmentStage: athleteDevelopmentStage
            )
            if failAt == .afterAthleteStaged { throw SimulatedFailure() }

            let grant = athleteAccessGrantRepository.stageFullAccessGrant(
                workspaceId: staged.workspace.workspaceId,
                participantId: staged.participant.id,
                athleteId: athlete.athleteId
            )
            if failAt == .afterGrantStaged { throw SimulatedFailure() }

            try modelContext.save()

            return Result(
                parent: staged.parent,
                workspace: staged.workspace,
                participant: staged.participant,
                athlete: athlete,
                grant: grant
            )
        } catch {
            // Requirement 3: any failure above — a staging step, a
            // simulated test failure, or a genuine save() error —
            // rolls back every staged insert on this context. Nothing
            // partial is left behind.
            modelContext.rollback()
            throw error
        }
    }
}
