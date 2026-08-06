import Foundation
import SwiftUI
import VoxtrCoreContracts
import VoxtrAthleteDomain

/// Multi-Athlete Family Foundation. Powers the family-management
/// screen: lists every athlete in the family (active and archived —
/// see `AthleteFamilyManagementView`'s own handling of that
/// distinction), and drives add/edit/archive through
/// `AthleteFamilyManagementService`.
@MainActor
@Observable
public final class AthleteFamilyManagementViewModel {
    public private(set) var athletes: [AthleteProfile] = []
    public private(set) var errorMessage: String?

    // Shared add/edit form fields.
    public var givenName: String = ""
    public var familyName: String = ""
    public var preferredName: String = ""
    public var birthDate: Date = .now
    public var developmentStage: DevelopmentStage = .parentLed

    private let workspaceId: WorkspaceId
    private let participantId: UUID
    private let athleteRepository: AthleteRepository
    private let athleteFamilyManagementService: AthleteFamilyManagementService

    public init(
        workspaceId: WorkspaceId,
        participantId: UUID,
        athleteRepository: AthleteRepository,
        athleteFamilyManagementService: AthleteFamilyManagementService
    ) {
        self.workspaceId = workspaceId
        self.participantId = participantId
        self.athleteRepository = athleteRepository
        self.athleteFamilyManagementService = athleteFamilyManagementService
    }

    /// Re-fetches from persistence — `RestoredFamily.athletes` is a
    /// launch-time snapshot, so this screen never relies on it staying
    /// current after its own mutations. Deterministic ordering matches
    /// `FamilyRestorationService`'s own (createdAt, then id as a
    /// tiebreaker).
    public func loadAthletes() {
        errorMessage = nil
        do {
            athletes = try athleteRepository.fetchAthletes(forWorkspace: workspaceId).sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        } catch {
            errorMessage = "Could not load athletes."
        }
    }

    public func prefill(from athlete: AthleteProfile) {
        givenName = athlete.givenName
        familyName = athlete.familyName ?? ""
        preferredName = athlete.preferredName ?? ""
        birthDate = Self.date(from: athlete.birthDate)
        developmentStage = athlete.developmentStage
    }

    public func resetForm() {
        givenName = ""
        familyName = ""
        preferredName = ""
        birthDate = .now
        developmentStage = .parentLed
    }

    @discardableResult
    public func addAthlete() -> Bool {
        errorMessage = nil
        do {
            try athleteFamilyManagementService.addAthlete(
                workspaceId: workspaceId,
                participantId: participantId,
                givenName: givenName.trimmingCharacters(in: .whitespacesAndNewlines),
                familyName: Self.nilIfBlank(familyName),
                preferredName: Self.nilIfBlank(preferredName),
                birthDate: Self.localDate(from: birthDate),
                timeZoneId: TimeZoneId(rawValue: TimeZone.current.identifier),
                developmentStage: developmentStage
            )
            resetForm()
            loadAthletes()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    public func editAthlete(_ athlete: AthleteProfile) -> Bool {
        errorMessage = nil
        do {
            try athleteFamilyManagementService.editAthlete(
                athlete.athleteId,
                expectedRevision: athlete.revision,
                givenName: givenName.trimmingCharacters(in: .whitespacesAndNewlines),
                familyName: Self.nilIfBlank(familyName),
                preferredName: Self.nilIfBlank(preferredName),
                birthDate: Self.localDate(from: birthDate),
                timeZoneId: athlete.timeZoneId,
                developmentStage: developmentStage
            )
            resetForm()
            loadAthletes()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    /// "Archive/delete" — never touches any other athlete in
    /// `athletes`, and the archived athlete stays in this list (just
    /// with `isArchived == true`) rather than disappearing, so the
    /// parent can see it happened.
    public func archiveAthlete(_ athlete: AthleteProfile) {
        errorMessage = nil
        do {
            try athleteFamilyManagementService.archiveAthlete(athlete.athleteId, expectedRevision: athlete.revision)
            loadAthletes()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func localDate(from date: Date) -> LocalDate {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    private static func date(from localDate: LocalDate) -> Date {
        Calendar.current.date(from: DateComponents(year: localDate.year, month: localDate.month, day: localDate.day)) ?? .now
    }

    private static func message(for error: Error) -> String {
        if error is AthleteProfileConflictError {
            return "This athlete's profile was changed elsewhere. Please reload and try again."
        }
        if let managementError = error as? AthleteFamilyManagementError {
            switch managementError {
            case .athleteNotFound:
                return "Could not find this athlete."
            case .invalidField(let message):
                return message
            }
        }
        return "Something went wrong. Please try again."
    }
}
