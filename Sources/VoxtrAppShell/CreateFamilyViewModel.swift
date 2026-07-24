import Foundation
import Observation
import VoxtrCoreContracts

/// S1.4: backs `CreateFamilyView`. Validates every field via
/// `FamilyOnboardingValidator` before ever calling
/// `FamilyOnboardingCoordinator.createFamily` — requirement 2/3: no
/// crash on invalid input, validation errors surfaced clearly per field.
///
/// `athleteDevelopmentStage` defaults to `.parentLed` but is shown as a
/// real picker in `CreateFamilyView`, not hidden — S1.2 flagged that the
/// default for a newly onboarded athlete was a UX decision for S1.4 to
/// make, not to be silently baked into a repository. Resolving it as
/// "sensible default the parent can change" rather than either forcing
/// a choice or hiding the field entirely.
///
/// `athleteTimeZoneId` is NOT a form field — defaults to the device's
/// current time zone (`TimeZone.current`). Asking a parent to pick a
/// time zone during onboarding is unnecessary friction for something
/// the device already knows.
@MainActor
@Observable
public final class CreateFamilyViewModel {
    public var parentGivenName: String = ""
    public var athleteGivenName: String = ""
    public var athleteBirthDate: Date = .now
    public var athleteDevelopmentStage: DevelopmentStage = .parentLed

    public private(set) var parentGivenNameError: String?
    public private(set) var athleteGivenNameError: String?
    public private(set) var athleteBirthDateError: String?
    public private(set) var submissionError: String?
    public private(set) var isSubmitting = false

    private let coordinator: FamilyOnboardingCoordinator

    /// Called after a successful `createFamily`. `RootView` uses this to
    /// re-query `FamilyRestorationState` (requirement 1) rather than
    /// this view model owning any navigation state itself.
    public var onFamilyCreated: (() -> Void)?

    public init(coordinator: FamilyOnboardingCoordinator) {
        self.coordinator = coordinator
    }

    public func submit() {
        parentGivenNameError = FamilyOnboardingValidator.validateParentGivenName(parentGivenName)
        athleteGivenNameError = FamilyOnboardingValidator.validateAthleteGivenName(athleteGivenName)
        athleteBirthDateError = FamilyOnboardingValidator.validateBirthDate(athleteBirthDate)
        submissionError = nil

        guard parentGivenNameError == nil, athleteGivenNameError == nil, athleteBirthDateError == nil else {
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        let components = Calendar.current.dateComponents([.year, .month, .day], from: athleteBirthDate)
        guard let year = components.year, let month = components.month, let day = components.day else {
            submissionError = "Couldn't read the selected birth date. Please try again."
            return
        }
        let localBirthDate = LocalDate(year: year, month: month, day: day)
        let timeZoneId = TimeZoneId(rawValue: TimeZone.current.identifier)

        do {
            _ = try coordinator.createFamily(
                parentGivenName: parentGivenName.trimmingCharacters(in: .whitespacesAndNewlines),
                athleteGivenName: athleteGivenName.trimmingCharacters(in: .whitespacesAndNewlines),
                athleteBirthDate: localBirthDate,
                athleteTimeZoneId: timeZoneId,
                athleteDevelopmentStage: athleteDevelopmentStage
            )
            onFamilyCreated?()
        } catch {
            // Requirement 2: never crash. Per-field validation already
            // ran above, so a failure here means something it couldn't
            // have caught (e.g. a genuine persistence error) — shown as
            // one submission-level message rather than attributed to a
            // specific field it isn't about.
            submissionError = "Something went wrong creating the family. Please try again."
        }
    }
}
