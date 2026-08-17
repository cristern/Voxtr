import Foundation
import Observation
import VoxtrCoreContracts

/// VX-023 (Sleep V1): "under the existing athlete profile/settings flow
/// add 'Sleep [Tracking On/Off].' Keep V1 minimal." No reminder time, no
/// notification toggle — those belong to VX-026/VX-027.
@MainActor
@Observable
public final class AthleteSleepSettingsViewModel {
    public let athleteId: AthleteId
    public let athleteDisplayName: String
    public private(set) var isTrackingEnabled: Bool
    public private(set) var errorMessage: String?

    private let sleepCoordinationService: SleepCoordinationService

    public init(sleepCoordinationService: SleepCoordinationService, athleteId: AthleteId, athleteDisplayName: String) {
        self.sleepCoordinationService = sleepCoordinationService
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.isTrackingEnabled = true
    }

    /// "Default: Sleep tracking = ON for every new/existing athlete
    /// unless an explicit persisted setting already says Off" —
    /// `isSleepTrackingEnabled(for:)` already implements exactly that
    /// "no row = ON" rule; this just reads it into presentation state.
    public func load() {
        do {
            isTrackingEnabled = try sleepCoordinationService.isSleepTrackingEnabled(for: athleteId)
            errorMessage = nil
        } catch {
            // Keep whatever value was already known (the ON default,
            // or a previous successful load) rather than surfacing a
            // toggle in an indeterminate state.
            errorMessage = "Could not load Sleep tracking setting."
        }
    }

    /// "Disabled != missing" — this only ever flips the preference flag
    /// (see `SleepCoordinationService.setSleepTrackingEnabled`'s own doc
    /// comment); Sleep history is never touched in either direction.
    public func setTrackingEnabled(_ enabled: Bool) {
        do {
            isTrackingEnabled = try sleepCoordinationService.setSleepTrackingEnabled(athleteId: athleteId, enabled: enabled)
            errorMessage = nil
        } catch {
            errorMessage = "Could not update Sleep tracking setting."
        }
    }
}
