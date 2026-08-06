import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrParentDomain

/// Multi-Athlete Family Foundation. Lives in `VoxtrAppShell` for the
/// same reason `FamilyOnboardingCoordinator` does — it needs both
/// `AthleteRepository` (VoxtrAthleteDomain) and
/// `AthleteAccessGrantRepository` (VoxtrParentDomain) to add a new
/// athlete, and `VoxtrAthleteDomain` deliberately does not depend on
/// `VoxtrParentDomain` (see `Package.swift`) — this coordination
/// cannot live in either domain package alone.
public enum AthleteFamilyManagementError: Error, Sendable, Equatable {
    case athleteNotFound
    case invalidField(String)
}

@MainActor
public final class AthleteFamilyManagementService {
    private let modelContext: ModelContext
    private let athleteRepository: AthleteRepository
    private let athleteAccessGrantRepository: AthleteAccessGrantRepository

    public init(
        modelContext: ModelContext,
        athleteRepository: AthleteRepository,
        athleteAccessGrantRepository: AthleteAccessGrantRepository
    ) {
        self.modelContext = modelContext
        self.athleteRepository = athleteRepository
        self.athleteAccessGrantRepository = athleteAccessGrantRepository
    }

    public struct AddedAthlete {
        public let athlete: AthleteProfile
        public let grant: AthleteAccessGrant
    }

    /// Adds a genuinely new, additional athlete to the family — an
    /// `AthleteProfile` row and its own `AthleteAccessGrant` from the
    /// given participant, one athlete among however many the family
    /// already has (zero or more). This is the actual multi-athlete
    /// capability this work package adds: unlike the discarded
    /// "single archived athlete replacement" approach, this always
    /// creates a new row, never reuses an existing one.
    ///
    /// TRANSACTION DESIGN: identical to
    /// `FamilyOnboardingCoordinator.createFamily`'s own — autosave is
    /// disabled for the duration (restored via `defer`), both entities
    /// are staged (insert only) into the same `ModelContext`, one
    /// `save()` persists both together, and any failure — staging or
    /// `save()` itself — triggers `modelContext.rollback()` before
    /// re-throwing, so nothing partial is ever left in the store.
    @discardableResult
    public func addAthlete(
        workspaceId: WorkspaceId,
        participantId: UUID,
        givenName: String,
        familyName: String? = nil,
        preferredName: String? = nil,
        birthDate: LocalDate,
        timeZoneId: TimeZoneId,
        developmentStage: DevelopmentStage
    ) throws -> AddedAthlete {
        try addAthlete(
            workspaceId: workspaceId,
            participantId: participantId,
            givenName: givenName,
            familyName: familyName,
            preferredName: preferredName,
            birthDate: birthDate,
            timeZoneId: timeZoneId,
            developmentStage: developmentStage,
            saveOverride: nil
        )
    }

    /// Test-only seam, mirroring `FamilyOnboardingCoordinator`'s own
    /// `saveOverride` pattern exactly. Not `public`, reachable only via
    /// `@testable import`. Every production call site goes through the
    /// public overload above, which always passes `nil`.
    func addAthlete(
        workspaceId: WorkspaceId,
        participantId: UUID,
        givenName: String,
        familyName: String?,
        preferredName: String?,
        birthDate: LocalDate,
        timeZoneId: TimeZoneId,
        developmentStage: DevelopmentStage,
        saveOverride: (() throws -> Void)?
    ) throws -> AddedAthlete {
        try Self.validate(givenName: givenName)

        let previousAutosaveSetting = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        defer { modelContext.autosaveEnabled = previousAutosaveSetting }

        do {
            let athlete = athleteRepository.stageAthlete(
                workspaceId: workspaceId,
                givenName: givenName,
                familyName: familyName,
                preferredName: preferredName,
                birthDate: birthDate,
                timeZoneId: timeZoneId,
                developmentStage: developmentStage
            )
            let grant = athleteAccessGrantRepository.stageFullAccessGrant(
                workspaceId: workspaceId,
                participantId: participantId,
                athleteId: athlete.athleteId
            )
            if let saveOverride {
                try saveOverride()
            } else {
                try modelContext.save()
            }
            return AddedAthlete(athlete: athlete, grant: grant)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Edits one athlete's profile fields in place — never touches any
    /// other athlete in the family.
    @discardableResult
    public func editAthlete(
        _ athleteId: AthleteId,
        expectedRevision: Int,
        givenName: String,
        familyName: String?,
        preferredName: String?,
        birthDate: LocalDate,
        timeZoneId: TimeZoneId,
        developmentStage: DevelopmentStage
    ) throws -> AthleteProfile {
        guard let athlete = try athleteRepository.fetchAthlete(byId: athleteId) else {
            throw AthleteFamilyManagementError.athleteNotFound
        }
        try Self.validate(givenName: givenName)
        try athlete.applyMutation(
            expectedRevision: expectedRevision,
            changedFields: ["givenName", "familyName", "preferredName", "birthDate", "timeZoneId", "developmentStage"]
        ) { profile in
            profile.givenName = givenName
            profile.familyName = familyName
            profile.preferredName = preferredName
            profile.birthDate = birthDate
            profile.timeZoneId = timeZoneId
            profile.developmentStage = developmentStage
        }
        try athleteRepository.save()
        return athlete
    }

    /// "Archive/delete athlete" — a soft delete (`isArchived = true`),
    /// the repository's own established lifecycle rule for
    /// `AthleteProfile` (the `AthleteArchived` domain event already
    /// existed for exactly this transition before this work package).
    /// Never removes the row or its `AthleteAccessGrant`, and never
    /// touches any other athlete — `FamilyRestorationService`'s
    /// consistency check requires exactly one grant per
    /// `AthleteProfile` regardless of `isArchived`, and archiving must
    /// never turn a consistent family graph into an inconsistent one.
    @discardableResult
    public func archiveAthlete(_ athleteId: AthleteId, expectedRevision: Int) throws -> AthleteProfile {
        guard let athlete = try athleteRepository.fetchAthlete(byId: athleteId) else {
            throw AthleteFamilyManagementError.athleteNotFound
        }
        try athlete.applyMutation(expectedRevision: expectedRevision, changedFields: ["isArchived"]) { profile in
            profile.isArchived = true
        }
        try athleteRepository.save()
        return athlete
    }

    /// Mirrors `AthleteProfile.init`'s own precondition (`givenName`
    /// 1-80 characters) as a catchable error — the precondition still
    /// guards direct construction, but a service-level create/edit path
    /// needs to reject bad input without crashing.
    private static func validate(givenName: String) throws {
        guard (1...80).contains(givenName.count) else {
            throw AthleteFamilyManagementError.invalidField("givenName must be 1-80 characters")
        }
    }
}
