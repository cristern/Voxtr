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

    /// `developmentStage` is a required parameter, not defaulted here —
    /// what a newly onboarded athlete's stage should be by default is a
    /// UX decision that belongs to S1.4 (onboarding UI), not something
    /// to guess at in a repository. Every caller (including
    /// `FamilyOnboardingCoordinator` and this file's own tests) must
    /// supply it explicitly.
    public func createAthlete(
        workspaceId: WorkspaceId,
        givenName: String,
        familyName: String? = nil,
        preferredName: String? = nil,
        birthDate: LocalDate,
        timeZoneId: TimeZoneId,
        developmentStage: DevelopmentStage
    ) throws -> AthleteProfile {
        let athlete = AthleteProfile(
            workspaceId: workspaceId,
            givenName: givenName,
            familyName: familyName,
            preferredName: preferredName,
            birthDate: birthDate,
            timeZoneId: timeZoneId,
            developmentStage: developmentStage
        )
        modelContext.insert(athlete)
        try modelContext.save()
        return athlete
    }

    public func fetchAllAthletes() throws -> [AthleteProfile] {
        try modelContext.fetch(FetchDescriptor<AthleteProfile>())
    }
}
