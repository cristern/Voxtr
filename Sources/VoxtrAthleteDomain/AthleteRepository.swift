import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// S1.2 scope only: creates and fetches `AthleteProfile`.
/// `AthleteSettings` and `AthleteSportParticipation` are not touched —
/// out of scope for S1.2.
///
/// VX-023 (Sleep V1) adds `AthleteSettings` methods below — the settings
/// row's ONLY reachable field so far is `sleepTrackingEnabled`; every
/// other `AthleteSettings` field remains unused by any repository/
/// service/UI, so this repository does not expose general-purpose
/// mutation for them.
@MainActor
public final class AthleteRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// S1.2a: stages an `AthleteProfile` into this repository's
    /// `ModelContext` — INSERT ONLY, NO SAVE. Used when this creation
    /// must be part of a larger atomic operation spanning multiple
    /// domains (see `FamilyOnboardingCoordinator`). `athleteId` is
    /// injectable (defaults to a fresh ID) so tests can force a genuine
    /// SwiftData uniqueness violation at `save()` time.
    ///
    /// `developmentStage` is a required parameter, not defaulted here —
    /// what a newly onboarded athlete's stage should be by default is a
    /// UX decision that belongs to S1.4 (onboarding UI), not something
    /// to guess at in a repository.
    public func stageAthlete(
        athleteId: AthleteId = AthleteId(),
        workspaceId: WorkspaceId,
        givenName: String,
        familyName: String? = nil,
        preferredName: String? = nil,
        birthDate: LocalDate,
        timeZoneId: TimeZoneId,
        developmentStage: DevelopmentStage
    ) -> AthleteProfile {
        let athlete = AthleteProfile(
            id: athleteId,
            workspaceId: workspaceId,
            givenName: givenName,
            familyName: familyName,
            preferredName: preferredName,
            birthDate: birthDate,
            timeZoneId: timeZoneId,
            developmentStage: developmentStage
        )
        modelContext.insert(athlete)
        return athlete
    }

    /// Standalone convenience: stage + save in one call. Preserved for
    /// any caller that only needs to create an athlete on its own — NOT
    /// used by `FamilyOnboardingCoordinator`, which stages via the
    /// method above and controls save/rollback itself.
    public func createAthlete(
        workspaceId: WorkspaceId,
        givenName: String,
        familyName: String? = nil,
        preferredName: String? = nil,
        birthDate: LocalDate,
        timeZoneId: TimeZoneId,
        developmentStage: DevelopmentStage
    ) throws -> AthleteProfile {
        let athlete = stageAthlete(
            workspaceId: workspaceId,
            givenName: givenName,
            familyName: familyName,
            preferredName: preferredName,
            birthDate: birthDate,
            timeZoneId: timeZoneId,
            developmentStage: developmentStage
        )
        try modelContext.save()
        return athlete
    }

    public func fetchAllAthletes() throws -> [AthleteProfile] {
        try modelContext.fetch(FetchDescriptor<AthleteProfile>())
    }

    /// Multi-Athlete Family Foundation: needed for editing/archiving a
    /// specific athlete — nothing before this work needed to fetch a
    /// single, specific `AthleteProfile` by ID.
    public func fetchAthlete(byId athleteId: AthleteId) throws -> AthleteProfile? {
        let rawId = athleteId.rawValue
        return try fetchAllAthletes().first { $0.id == rawId }
    }

    /// Scoped variant of `fetchAllAthletes`, for the family-management
    /// UI's own list. Under Sprint 1's still-current single-family-per-
    /// device assumption this returns the same rows as
    /// `fetchAllAthletes`, but scoping explicitly by `workspaceId` here
    /// (rather than relying on that assumption) is what makes this
    /// method correct if that assumption is ever relaxed later, without
    /// itself changing.
    public func fetchAthletes(forWorkspace workspaceId: WorkspaceId) throws -> [AthleteProfile] {
        let rawWorkspaceId = workspaceId.rawValue
        return try fetchAllAthletes().filter { $0.workspaceId == rawWorkspaceId }
    }

    /// Persists whatever mutation was already applied in-memory (via
    /// `AthleteProfile.applyMutation`, the sole sanctioned mutation
    /// path) — this repository never mutates fields itself, matching
    /// `PlanningRepository`'s own established split between "the
    /// entity knows how to mutate itself" and "the repository only
    /// persists."
    public func save() throws {
        try modelContext.save()
    }

    /// VX-023: at most one `AthleteSettings` row per athlete — `nil`
    /// when none has ever been created, which is the normal case for
    /// every athlete that has never had a settings-affecting toggle
    /// touched. `nil` is NOT "tracking off": callers (see
    /// `SleepCoordinationService.isSleepTrackingEnabled(for:)`) treat a
    /// missing row as tracking ON, never as a reason to fetch/create one
    /// eagerly here.
    public func fetchAthleteSettings(forAthlete athleteId: AthleteId) throws -> AthleteSettings? {
        let rawAthleteId = athleteId.rawValue
        return try modelContext.fetch(FetchDescriptor<AthleteSettings>()).first { $0.athleteId == rawAthleteId }
    }

    /// VX-023: sets `sleepTrackingEnabled` on the athlete's ONE
    /// `AthleteSettings` row — mutates the existing row in place if one
    /// already exists (preserving every other field on it untouched),
    /// or creates a brand-new row (with this type's own neutral
    /// defaults for every other field, per this file's own doc comment)
    /// only when this is the very first settings-affecting toggle ever
    /// recorded for this athlete. Never creates a second row for an
    /// athlete that already has one.
    @discardableResult
    public func setSleepTrackingEnabled(athleteId: AthleteId, enabled: Bool) throws -> AthleteSettings {
        if let existing = try fetchAthleteSettings(forAthlete: athleteId) {
            existing.sleepTrackingEnabled = enabled
            existing.updatedAt = .now
            try modelContext.save()
            return existing
        }
        let settings = AthleteSettings(athleteId: athleteId, sleepTrackingEnabled: enabled)
        modelContext.insert(settings)
        try modelContext.save()
        return settings
    }

    /// Design Foundation V0.1 (Athlete Color canonical preference
    /// round): sets `preferredColor` on the athlete's ONE
    /// `AthleteSettings` row — mirrors `setSleepTrackingEnabled` exactly
    /// (mutate the existing row in place if one already exists,
    /// preserving every other field untouched; otherwise create a
    /// brand-new row with this type's own neutral defaults). Never
    /// creates a second row for an athlete that already has one, and
    /// never touches any other athlete's row.
    @discardableResult
    public func setPreferredColor(athleteId: AthleteId, color: AthleteColor) throws -> AthleteSettings {
        if let existing = try fetchAthleteSettings(forAthlete: athleteId) {
            existing.preferredColor = color
            existing.updatedAt = .now
            try modelContext.save()
            return existing
        }
        let settings = AthleteSettings(athleteId: athleteId, preferredColor: color)
        modelContext.insert(settings)
        try modelContext.save()
        return settings
    }
}
