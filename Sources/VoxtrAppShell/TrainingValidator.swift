import Foundation
import VoxtrCoreContracts

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

    /// VX-022: Form is required for the V1 Log Activity flow (approved
    /// product contract) — enforced here, at the UI/orchestration
    /// boundary, before `TrainingReflectionCoordinationService.logActivity`
    /// is ever called. Deliberately NOT enforced by making
    /// `ActivityReflection.bodyFeeling` non-optional at the domain
    /// level: `ActivityReflection` also carries reflection content that
    /// has no bodyFeeling at all (see `ReflectionRepositoryAndServiceTests`'s
    /// text-only-reflection coverage), so narrowing the entity itself
    /// would break other, unrelated reflection use cases.
    public static func validateForm(_ value: Int?) -> String? {
        guard let value else { return TrainingStrings.formRequired }
        guard (1...5).contains(value) else { return TrainingStrings.invalidForm }
        return nil
    }

    /// Planned/Logged Activity lifecycle consistency cleanup: whether
    /// actual/logged duration is required for a given outcome —
    /// `.completed`/`.partiallyCompleted` genuinely happened, so a real
    /// duration is meaningful and required; `.missed`/`.cancelled`
    /// represent "this did not take place," so there is nothing to
    /// measure and duration stays optional; `.scheduled` is not a
    /// logging outcome at all (never reached through the logging flow)
    /// but is included for exhaustiveness rather than left to a
    /// `default` case that would silently swallow a future new case.
    public static func requiresActualDuration(for status: ActivityStatus) -> Bool {
        switch status {
        case .completed, .partiallyCompleted:
            return true
        case .missed, .cancelled, .scheduled:
            return false
        }
    }

    /// Mirrors `validateForm`'s exact shape: required only for outcomes
    /// `requiresActualDuration(for:)` says need one, checked at the
    /// UI/orchestration boundary before anything is created — the same
    /// "required at this layer, not by making the domain field
    /// non-optional" principle `validateForm`'s own doc comment already
    /// establishes (`LoggedActivity.durationMinutes` itself stays the
    /// schema's existing non-optional `Int`; this only governs what the
    /// UI must collect before it ever calls the service).
    public static func validateActualDuration(_ value: Int?, for status: ActivityStatus) -> String? {
        guard requiresActualDuration(for: status) else { return nil }
        guard let value else { return TrainingStrings.actualDurationRequired }
        guard (1...1440).contains(value) else { return TrainingStrings.invalidDuration }
        return nil
    }
}
