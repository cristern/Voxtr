import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData

/// Sport / Activity Identity domain foundation, Blocker B fix (review
/// correction): the ONE shared "what do we call this activity" resolver.
/// Every production activity-rendering surface must go through this,
/// never re-derive `name ?? sport` inline — the exact duplication this
/// round's first attempt (`title ?? ""` scattered across a dozen Views)
/// was rejected for.
///
/// Lives in `VoxtrAppShell`, not `VoxtrCoreContracts`/any `*Domain`
/// target: it needs to see BOTH an activity's own `title`/`sportId`
/// (`VoxtrCoreContracts`) AND the actual `Sport` reference row's display
/// data (`VoxtrCoreReferenceData`), and only `VoxtrAppShell` is allowed
/// to depend on both (see `Package.swift`'s own dependency comment) —
/// the same reasoning `ActivityIdentity` itself documents for why IT
/// lives one level down, never seeing `Sport` directly.
///
/// Semantic contract, exactly as approved by review:
///
/// `primaryActivityLabel = normalizedActivityName ?? resolvedSportDisplayName`
///
/// `ActivityType` is NEVER part of this — it is classification, never
/// identity (the same approved product contract `ActivityIdentity`'s
/// own doc comment states). `ActivityIdentity.isValid` guarantees at
/// least one of name/`sportId` exists for any genuinely valid activity,
/// so this resolver's own missing-reference fallback
/// (`TrainingStrings.unresolvedActivityLabel`) is reached only for
/// corrupted/missing reference data — a stale or deleted Sport row —
/// never for an ordinary Sport-only activity with intact data. Never
/// infers a Sport from a title, never matches by title/date.
///
/// Deliberately NOT `@MainActor`: neither function here touches a
/// repository directly — `resolveSport` is an opaque, already-isolated
/// closure supplied by the caller (mirroring `resolveAthleteColor` in
/// `FamilyScheduleViewModel`, which is likewise not `@MainActor`-typed
/// even though its real implementations wrap a `@MainActor` repository
/// call) — so this stays callable from any isolation context.
public enum ActivityLabelResolver {
    /// Pure form — takes an already-resolved `Sport?` (`nil` meaning
    /// "no `sportId`" or "lookup found nothing"), so it's trivially
    /// unit-testable without any persistence.
    public static func primaryLabel(name: String?, sport: Sport?) -> String {
        if let normalized = ActivityIdentity.normalizedName(name) {
            return normalized
        }
        if let sport {
            return displayName(for: sport)
        }
        return TrainingStrings.unresolvedActivityLabel
    }

    /// Convenience overload matching the established
    /// `AthleteColor.resolved(forAthlete:using:)` "closure resolver"
    /// shape (`VoxtrDesignSystem.swift`): callers pass a
    /// `(SportId) -> Sport?` lookup — usually a small closure backed by
    /// `SportRepository.fetchSport(byId:)` — rather than threading the
    /// concrete repository type through every call site. Every existing
    /// construction site not yet wired to a live resolver keeps
    /// compiling against the safe `{ _ in nil }` default, which degrades
    /// to the honest missing-reference fallback above rather than a
    /// blank string — never a silent regression back to Blocker B's
    /// bug.
    public static func primaryLabel(
        name: String?,
        sportId: SportId?,
        resolveSport: (SportId) -> Sport?
    ) -> String {
        primaryLabel(name: name, sport: sportId.flatMap(resolveSport))
    }

    /// Convenience overload matching `AthleteColor.resolved(forAthlete:using:)`'s
    /// OTHER established shape — some ViewModels (`FamilyHomeViewModel`)
    /// already hold their repository directly rather than an injected
    /// closure; this lets them call through consistently too, without
    /// re-deriving the lookup inline. `@MainActor` to match
    /// `SportRepository`'s own isolation, same reasoning
    /// `AthleteColor.resolved(forAthlete:using:)` documents for itself.
    @MainActor
    public static func primaryLabel(name: String?, sportId: SportId?, using sportRepository: SportRepository) -> String {
        primaryLabel(name: name, sportId: sportId) { try? sportRepository.fetchSport(byId: $0) }
    }

    /// Bounded to the current 3-Sport seed set's own `canonicalKey` as
    /// the English fallback, routed through `Sport.displayNameKey` via
    /// the same `String(localized:defaultValue:)` pattern every other
    /// user-facing string in this app already uses (`TrainingStrings`,
    /// `OnboardingStrings`, ...) — no real String Catalog exists for
    /// Sport names yet, so today this always resolves to the English
    /// default; wiring an actual catalog is a future localization pass,
    /// not part of this domain-foundation round.
    public static func displayName(for sport: Sport) -> String {
        String(
            localized: String.LocalizationValue(sport.displayNameKey),
            defaultValue: String.LocalizationValue(sport.canonicalKey.capitalized)
        )
    }
}
