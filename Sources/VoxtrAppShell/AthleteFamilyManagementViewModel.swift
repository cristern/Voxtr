import Foundation
import SwiftUI
import VoxtrCore
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
    /// In-progress state follow-up: true from the moment
    /// `connectAthleteApp(for:)` starts a real request until it finishes
    /// (success or failure) — set synchronously before the first `await`,
    /// so the View can show immediate feedback, and doubles as the
    /// re-entry guard at the ViewModel/service boundary (see that
    /// method's own doc comment for why the guard belongs here, not only
    /// on the button). Mirrors the existing `isSubmitting` convention
    /// already used by `CreateFamilyViewModel`/`DailyTrainingViewModel`/
    /// `WeeklyReflectionFormViewModel`.
    public private(set) var isConnectingAthleteApp = false
    /// Explicit, differentiated failure surfaced to the UI — never a
    /// generic/silent failure, matching `AthleteConnectionOwnerHandoffError`'s
    /// own explicit-error-handling requirement. Cleared at the start of
    /// every `connectAthleteApp(for:)` call.
    public private(set) var connectAthleteAppErrorMessage: String?
    /// Internal Alpha diagnostic surface follow-up: the safe, structured
    /// CloudKit diagnostic behind the most recent `connectAthleteApp(for:)`
    /// failure, if the failure involved CloudKit at all — `nil` for the
    /// purely-local failure cases (participant/profile/workspace lookup),
    /// which have no CloudKit stage to report. Never read directly by the
    /// View — see `connectAthleteAppDiagnosticSummary`/`...CopyText` below,
    /// which is all `AthleteFamilyManagementView` needs, so it never has
    /// to import CloudKit-adjacent types itself.
    private var connectAthleteAppDiagnostic: CloudKitErrorDiagnostic?

    /// `"<stage> · <ckCode>"` for on-screen display — see
    /// `CloudKitErrorDiagnostics.conciseDisplay(_:)`.
    public var connectAthleteAppDiagnosticSummary: String? {
        connectAthleteAppDiagnostic.map(CloudKitErrorDiagnostics.conciseDisplay)
    }

    /// The fuller, greppable line for "Copy diagnostic" — the same shape
    /// PR #76 already logs via `os.Logger`/`VoxtrLog`, never
    /// `localizedDescription`, never record/athlete/account content.
    public var connectAthleteAppDiagnosticCopyText: String? {
        connectAthleteAppDiagnostic.map(CloudKitErrorDiagnostics.format)
    }

    private let workspaceId: WorkspaceId
    private let participantId: UUID
    private let athleteRepository: AthleteRepository
    private let athleteFamilyManagementService: AthleteFamilyManagementService
    private let athleteConnectionOwnerHandoffService: AthleteConnectionOwnerHandoffService

    /// In-progress state follow-up: test-only seam, default `nil` — every
    /// real call goes through `athleteConnectionOwnerHandoffService
    /// .prepareInvitation` exactly as before. `AthleteConnectionOwnerHandoffService
    /// .prepareInvitation` itself performs real CloudKit/SwiftData I/O and
    /// is deliberately never exercised end-to-end in tests (see
    /// `AthleteConnectionOwnerHandoffServiceTests.swift`'s own suite-level
    /// comment) — and a call that never suspends can never overlap with a
    /// second one on the MainActor, so no fixture built from that service
    /// alone could ever prove the re-entry guard rejects a concurrent
    /// second call. This lets a test control the timing of "creating the
    /// invitation" instead, without touching that service's own
    /// established testability boundary. Mirrors
    /// `CreateFamilyViewModel.testSaveOverride`'s own precedent for the
    /// same reason.
    ///
    /// PR #80 Codemagic Swift 6 follow-up: the closure type itself is
    /// explicitly `@MainActor`-isolated — a plain, unannotated function
    /// type is NOT implicitly MainActor-isolated merely by being stored
    /// on a `@MainActor` class, so passing the already-MainActor-isolated
    /// `athlete` argument into it was flagged as a potential actor-crossing
    /// send. There is no product/architectural reason for this seam to
    /// leave MainActor at all — `connectAthleteApp(for:)` itself never
    /// does — so pinning the closure's isolation to match, rather than
    /// weakening `AthleteProfile`'s own Sendability, is the correct fix.
    var testPrepareInvitationOverride: (@MainActor (AthleteProfile) async throws -> AthleteConnectionInvitationHandoff)?

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
    ///
    /// In-progress state follow-up: the `isConnectingAthleteApp` guard
    /// below is the re-entry boundary — deliberately not left to the
    /// View's own `.disabled(...)` alone, so a second caller reaching
    /// this method directly (e.g. if the button/screen structure changes
    /// later) still cannot start a second, parallel invitation request
    /// while one is already in flight. `isConnectingAthleteApp` is set
    /// synchronously, before the first `await`, so it is already `true`
    /// by the time this method's first suspension point is reached —
    /// there is no window where a second call could slip in before the
    /// flag takes effect. `defer` resets it on every exit path (success
    /// or the `catch` below), matching this file's own existing
    /// `isSubmitting`-style convention elsewhere in this module.
    public func connectAthleteApp(for athlete: AthleteProfile) async {
        guard !isConnectingAthleteApp else { return }
        isConnectingAthleteApp = true
        defer { isConnectingAthleteApp = false }

        connectAthleteAppErrorMessage = nil
        connectAthleteAppDiagnostic = nil
        pendingInvitationHandoff = nil
        do {
            if let testPrepareInvitationOverride {
                pendingInvitationHandoff = try await testPrepareInvitationOverride(athlete)
            } else {
                pendingInvitationHandoff = try await athleteConnectionOwnerHandoffService.prepareInvitation(
                    forAthlete: athlete.athleteId,
                    workspaceId: workspaceId,
                    invitedBy: ActorId(rawValue: participantId)
                )
            }
        } catch {
            connectAthleteAppErrorMessage = Self.message(forHandoffError: error)
            connectAthleteAppDiagnostic = Self.diagnostic(forHandoffError: error)
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
        // PR #68 Codemagic follow-up: these seven cases all mean the same
        // thing to a Parent — some piece of this device's own local
        // family/athlete data (needed to build the invitation) could not
        // be read or was missing entirely. None of these should happen on
        // a device that ever completed onboarding, so there's no more
        // useful distinction to surface than "try again"; the specific
        // underlying case remains available to logging via the real
        // thrown `AthleteConnectionOwnerHandoffError`, never surfaced here.
        case .ownerParticipantNotFound,
             .parentProfileLookupFailed,
             .parentProfileNotFound,
             .workspaceLookupFailed,
             .workspaceNotFound,
             .athleteProfileLookupFailed,
             .athleteProfileNotFound:
            return "Couldn't prepare this invitation. Please try again."
        case .shareCreationFailed:
            return "Couldn't reach iCloud to create the invitation. Please check your connection and try again."
        case .invitationMappingFailed:
            return "Couldn't finish preparing the invitation. Please try again."
        }
    }

    /// Athlete Connection invitation-flow diagnostics follow-up (PR #76),
    /// extended for the Internal Alpha on-device diagnostic surface: the
    /// only two `AthleteConnectionOwnerHandoffError` cases that wrap a
    /// real CloudKit failure. When the wrapped error is a
    /// `FamilyWorkspaceSharingError` (always true today —
    /// `FamilyWorkspaceOwnerShareCoordinator` is the only thing
    /// `prepareInvitation` calls that can produce one), its own
    /// `.diagnostic` already carries the GRANULAR stage
    /// (`sharing-zone-create`/`share-save`/etc.) that coordinator's own
    /// per-operation logs captured at the moment it happened — used here
    /// instead of the generic `"handoff-prepare"` label so the on-device
    /// diagnostic is as specific as what unified logging already shows.
    /// Also logs the same diagnostic (unchanged PR #76 behavior, just
    /// consolidated into one call site instead of two identical ones).
    private static func diagnostic(forHandoffError error: Error) -> CloudKitErrorDiagnostic? {
        guard let handoffError = error as? AthleteConnectionOwnerHandoffError else { return nil }
        let underlying: Error
        switch handoffError {
        case .shareCreationFailed(let wrapped), .invitationMappingFailed(let wrapped):
            underlying = wrapped
        default:
            return nil
        }
        let diagnostic = (underlying as? FamilyWorkspaceSharingError)?.diagnostic
            ?? CloudKitErrorDiagnostics.classify(stage: "handoff-prepare", error: underlying)
        VoxtrLog.logger(.appShell).error("\(CloudKitErrorDiagnostics.format(diagnostic), privacy: .public)")
        return diagnostic
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
