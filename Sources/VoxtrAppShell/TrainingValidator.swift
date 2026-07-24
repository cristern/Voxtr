import Foundation

/// S3.3 requirement: "Surface validation and service errors without
/// crashing." `LoggedActivity`'s own `precondition`s (durationMinutes
/// 1–1440, perceivedExertion 1–10 if set, notes ≤500 chars if set) exist
/// but only run inside its `init` — they crash the process on
/// violation rather than throwing. Checking the SAME bounds here first
/// is what lets the UI reject bad input as a catchable error instead of
/// a crash; it mirrors — does not add to — the existing schema, exactly
/// like `FamilyOnboardingValidator` and `PlanningService`'s private
/// `validate()` already established for their own entities. `title` is
/// deliberately NOT validated here — `LoggedActivity` has no
/// precondition on it at all, so inventing one would go beyond scope.
public enum TrainingValidator {
    public static func validateDurationMinutes(_ value: Int) -> String? {
        guard (1...1440).contains(value) else { return TrainingStrings.invalidDuration }
        return nil
    }

    public static func validatePerceivedExertion(_ value: Int?) -> String? {
        guard let value else { return nil }
        guard (1...10).contains(value) else { return TrainingStrings.invalidPerceivedExertion }
        return nil
    }

    public static func validateNotes(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.count <= 500 else { return TrainingStrings.notesTooLong }
        return nil
    }
}
