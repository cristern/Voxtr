import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrReflectionDomain

/// VX-023 (Sleep V1): the lightweight capture screen's own state — one
/// `LocalDate`, one athlete, one 1-5 value. No sleep duration, no
/// bedtime/wake-time, no interpretation labels — exactly the approved
/// V1 capture contract ("How did you sleep?" / "Sleep score: 1 2 3 4 5").
@MainActor
@Observable
public final class SleepCaptureViewModel {
    public let athleteId: AthleteId
    public let athleteDisplayName: String
    public let localDate: LocalDate
    /// Preselected to the existing value when editing an already-logged
    /// date; defaults to the neutral midpoint (3) for a date with no
    /// Sleep recorded yet — `Picker` needs SOME initial selection, and 3
    /// is the one value on a 1-5 scale that carries no directional
    /// implication either way, consistent with "no interpretation
    /// labels" (this default is never itself saved unless the person
    /// explicitly taps Save).
    public var sleepQuality: Int
    public private(set) var errorMessage: String?
    public private(set) var didSave = false

    private let sleepCoordinationService: SleepCoordinationService
    private let today: LocalDate

    public init(
        sleepCoordinationService: SleepCoordinationService,
        athleteId: AthleteId,
        athleteDisplayName: String,
        localDate: LocalDate,
        existingSleepQuality: Int?,
        today: LocalDate
    ) {
        self.sleepCoordinationService = sleepCoordinationService
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.localDate = localDate
        self.sleepQuality = existingSleepQuality ?? 3
        self.today = today
    }

    /// "Successful save dismisses/returns normally; failed save keeps
    /// input and reports failure" — `didSave` is what the view checks to
    /// decide whether to dismiss; `errorMessage`/`sleepQuality` are left
    /// exactly as entered on failure, so the person can retry without
    /// re-entering anything.
    public func save() {
        do {
            try sleepCoordinationService.recordSleep(
                athleteId: athleteId,
                localDate: localDate,
                sleepQuality: sleepQuality,
                today: today
            )
            errorMessage = nil
            didSave = true
        } catch ReflectionServiceError.futureDateNotAllowed {
            errorMessage = "Sleep can't be logged for a future date."
        } catch ReflectionServiceError.invalidField(let message) {
            errorMessage = message
        } catch {
            errorMessage = "Could not save Sleep. Please try again."
        }
    }
}
