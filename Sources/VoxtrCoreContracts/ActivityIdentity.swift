import Foundation

/// Sport / Activity Identity domain foundation. The ONE canonical rule
/// every activity-shaped mutation boundary (`PlannedActivity`,
/// `RecurringPlannedActivity`, `LoggedActivity`) must enforce:
///
/// `normalizedName(name) != nil || sportId != nil`
///
/// Activity Type is never part of this check — it is classification
/// metadata, never a substitute identity (approved product contract).
/// Lives in `VoxtrCoreContracts`, not a `*Domain` target or
/// `VoxtrCoreReferenceData`: every feature domain that owns an activity
/// entity (`VoxtrPlanningDomain`, `VoxtrTrainingDomain`) already depends
/// on `VoxtrCoreContracts` and stores `SportId` only (never the `Sport`
/// entity itself, which those domains are architecturally forbidden from
/// importing — see `Package.swift`'s own dependency comment) — this type
/// only ever needs the typed ID, never the referenced row, so it belongs
/// exactly where every domain that needs it can already reach it,
/// without any of them needing a second, locally-reimplemented copy of
/// this same check.
public enum ActivityIdentity {
    /// Whitespace-only input is treated as absent, per the approved
    /// contract. The one normalization boundary every mutation path
    /// (entity `init`, and every service-level edit that assigns
    /// `title` directly without going back through `init`) must call
    /// before persisting — never store a whitespace-only string as if
    /// it were a real name.
    public static func normalizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Non-throwing form, for entity-level `precondition` call sites
    /// (defense-in-depth, mirroring how `PlannedActivity`'s own
    /// `title.count` bound was already enforced directly in `init`
    /// before this rule existed) — expects the caller to have already
    /// normalized `name` via `normalizedName(_:)`.
    public static func isValid(normalizedName: String?, sportId: SportId?) -> Bool {
        normalizedName != nil || sportId != nil
    }

    /// Throwing form, for the catchable service-level validation every
    /// create/edit path (Planned, Recurring, Logged) calls before
    /// mutating — the narrowest shared boundary these three otherwise-
    /// isolated domains can share, given none of them may depend on
    /// each other (see this type's own doc comment). Normalizes `name`
    /// itself, so callers may pass the raw, unnormalized user input
    /// directly.
    public static func validate(name: String?, sportId: SportId?) throws {
        guard isValid(normalizedName: normalizedName(name), sportId: sportId) else {
            throw ActivityIdentityError.missingIdentity
        }
    }
}

/// Thrown by `ActivityIdentity.validate(name:sportId:)`. Each domain's
/// own service-level error enum (`PlanningServiceError`,
/// `TrainingServiceError`) wraps this into its own existing
/// `.invalidField(String)`-shaped case at the call site, matching how
/// every other catchable validation error in this codebase is already
/// surfaced to ViewModels — never propagated as this raw domain-neutral
/// type across a `*Domain` package boundary.
public enum ActivityIdentityError: Error, Sendable, Equatable {
    case missingIdentity
}
