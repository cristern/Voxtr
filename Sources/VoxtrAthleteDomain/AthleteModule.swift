import Foundation
import VoxtrCore

/// Athlete domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns AthleteProfile,
/// AthleteSettings, and AthleteSportParticipation (Section 6), and
/// publishes AthleteProfileCreated / AthleteProfileUpdated /
/// AthleteArchived (Section 6.1, Section 16).
public struct AthleteModule: VoxtrModule {
    public static let domainID = "athlete"

    public init() {}
}
