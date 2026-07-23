import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// S1.2 scope only: creates and fetches `AthleteProfile`.
/// `AthleteSettings` and `AthleteSportParticipation` are not touched —
/// out of scope for S1.2.
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
}
