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

    /// Athlete Connection Foundation B2.6: the in-flight/completed
    /// "Connect Athlete App" handoff, if any — `nil` means no handoff is
    /// currently being presented. Set only by `connectAthleteApp(for:)`
    /// and cleared by `dismissConnectAthleteApp()` (called when
    /// `CloudSharingPresenter` finishes or the Parent dismisses it).
    public private(set) var pendingInvitationHandoff: AthleteConnectionInvitationHandoff?
    /// Explicit, differentiated failure surfaced to the UI — never a
    /// generic/silent failure, matching `AthleteConnectionOwnerHandoffError`'s
    /// own explicit-error-handling requirement. Cleared at the start of
    /// every `connectAthleteApp(for:)` call.
    public private(set) var connectAthleteAppErrorMessage: String?

    private let workspaceId: WorkspaceId
    private let participantId: UUID
    private let athleteRepository: AthleteRepository
    private let athleteFamilyManagementService: AthleteFamilyManagementService
    private let athleteConnectionOwnerHandoffService: AthleteConnectionOwnerHandoffService

    public init(
        workspaceId: WorkspaceId,
        participantId: UUID,
        athleteRepository: AthleteRepository,
        athleteFamilyManagementService: AthleteFamilyManagementService,
        athleteConnectionOwnerHandoffService: AthleteConnectionOwnerHandoffService
    ) {
        self.workspaceId = workspaceId
        self.participantId = participantId
        self.athleteRepository = athleteRepository
        self.athleteFamilyManagementService = athleteFamilyManagementService
        self.athleteConnectionOwnerHandoffService = athleteConnectionOwnerHandoffService
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

    /// "Reactivate/undo archive" — the reverse of `archiveAthlete(_:)`
    /// above, same shape (same service call pattern, same
    /// `loadAthletes()` refresh afterward, same error handling). Never
    /// touches any other athlete in `athletes`.
    public func reactivateAthlete(_ athlete: AthleteProfile) {
        errorMessage = nil
        do {
            try athleteFamilyManagementService.reactivateAthlete(athlete.athleteId, expectedRevision: athlete.revision)
            loadAthletes()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Narrow Development Stage mutation — does not touch shared
    /// add/edit form fields (`givenName` etc.) and does not call
    /// `resetForm()`, since it was never backed by that shared form
    /// state to begin with. Mirrors `archiveAthlete(_:)` above.
    public func setDevelopmentStage(for athlete: AthleteProfile, to developmentStage: DevelopmentStage) {
        errorMessage = nil
        do {
            try athleteFamilyManagementService.setDevelopmentStage(
                athlete.athleteId, expectedRevision: athlete.revision, developmentStage: developmentStage
            )
            loadAthletes()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Design Foundation V0.1 (Athlete Color canonical preference
    /// round): the RESOLVED colour for one athlete — "explicit
    /// preference wins, otherwise the stable `AthleteId`-derived
    /// fallback," the same rule `FamilyHomeViewModel.resolvedAthleteColor(for:)`
    /// applies on the shared-view side. Reads straight from
    /// `AthleteSettings` on every call (no cache) — used both by the
    /// single-athlete Athlete Settings hub (a fresh read per call is
    /// cheap and always current there) and, since the Design Foundation
    /// extension round, by Manage Athletes' own small colour marker per
    /// row.
    ///
    /// Design Foundation extension round: delegates to the ONE
    /// canonical `AthleteColor.resolved(forAthlete:using:)` helper
    /// (`VoxtrDesignSystem.swift`) instead of re-deriving the same
    /// "explicit preference wins, otherwise stable fallback" lookup
    /// inline — this method used to duplicate that exact two-step logic
    /// before the shared helper existed; same result, same per-call
    /// freshness, no local mapping of its own anymore.
    public func resolvedColor(for athlete: AthleteProfile) -> AthleteColor {
        AthleteColor.resolved(forAthlete: athlete.athleteId, using: athleteRepository)
    }

    /// Narrow Athlete Color mutation — mirrors `setDevelopmentStage(for:to:)`'s
    /// shape (single field, no shared form state touched), but goes
    /// straight through `AthleteRepository.setPreferredColor(athleteId:color:)`
    /// rather than `AthleteFamilyManagementService`: Athlete Color lives
    /// on `AthleteSettings`, not `AthleteProfile`, so there is no
    /// `AthleteProfile.revision`/`applyMutation` optimistic-concurrency
    /// check to make here — same reasoning `AthleteRepository.setSleepTrackingEnabled`
    /// already establishes for the other `AthleteSettings` field this
    /// codebase mutates narrowly. Does not call `loadAthletes()` — this
    /// setting isn't part of the `athletes` list's own data.
    public func setPreferredColor(for athlete: AthleteProfile, to color: AthleteColor) {
        errorMessage = nil
        do {
            try athleteRepository.setPreferredColor(athleteId: athlete.athleteId, color: color)
        } catch {
            errorMessage = "Could not update Color."
        }
    }

    /// Athlete Connection Foundation B2.6: the "Connect Athlete App"
    /// action — the smallest ParentApp-side entry point into the
    /// owner-side CloudKit share handoff. `invitedBy`: this Parent's own
    /// `ActorId`, from the SAME `participantId` this ViewModel already
    /// holds (the owner's own `WorkspaceParticipant.id`) — never a
    /// separately-derived identity.
    public func connectAthleteApp(for athlete: AthleteProfile) async {
        connectAthleteAppErrorMessage = nil
        pendingInvitationHandoff = nil
        do {
            pendingInvitationHandoff = try await athleteConnectionOwnerHandoffService.prepareInvitation(
                forAthlete: athlete.athleteId,
                workspaceId: workspaceId,
                invitedBy: ActorId(rawValue: participantId)
            )
        } catch {
            connectAthleteAppErrorMessage = Self.message(forHandoffError: error)
        }
    }

    /// Called once `CloudSharingPresenter` finishes (share saved/stopped)
    /// or the Parent dismisses the sheet without completing it — either
    /// way, this handoff is done being presented.
    public func dismissConnectAthleteApp() {
        pendingInvitationHandoff = nil
    }

    private static func message(forHandoffError error: Error) -> String {
        guard let handoffError = error as? AthleteConnectionOwnerHandoffError else {
            return "Something went wrong. Please try again."
        }
        switch handoffError {
        case .participantLookupFailed:
            return "Couldn't look up this athlete's connection status. Please try again."
        case .duplicateAthleteParticipant:
            return "Something is inconsistent with this athlete's connection record. Please contact support."
        case .participantCreationFailed:
            return "Couldn't set up this athlete's connection. Please try again."
        case .shareCreationFailed:
            return "Couldn't reach iCloud to create the invitation. Please check your connection and try again."
        case .invitationMappingFailed:
            return "Couldn't finish preparing the invitation. Please try again."
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
