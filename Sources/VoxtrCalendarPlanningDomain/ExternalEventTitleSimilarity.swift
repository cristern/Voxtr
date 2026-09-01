import Foundation
import VoxtrCoreContracts

/// Calendar Import Review V1.2 (Similar-Event Suggestions): ONE prior
/// distinct normalized title's own unambiguous historical classification
/// — the raw evidence `ExternalEventTitleSimilarity.suggestedMatch(forEventTitle:among:)`
/// below reasons over. Built ONLY from `.imported` `CalendarImportDecision`
/// history with a still-resolving linked `PlannedActivity`, already
/// collapsed to a single (athlete, sport, activityType) combination per
/// normalized title (an ambiguous title never produces one of these —
/// see `CalendarPlanningCoordinationService.historicalTitleClassifications(for:)`'s
/// own doc comment for the full derivation/ambiguity/workspace contract,
/// which this type's own initializer does not itself enforce). Carries
/// the ORIGINAL (non-normalized) title purely for the Parent-facing
/// "Based on: <title>" explanation — never used for matching itself.
public struct HistoricalTitleClassification: Sendable, Equatable {
    public let normalizedTitle: String
    public let originalTitle: String
    public let athleteId: AthleteId
    public let sportId: SportId?
    public let activityType: ActivityType

    public init(normalizedTitle: String, originalTitle: String, athleteId: AthleteId, sportId: SportId?, activityType: ActivityType) {
        self.normalizedTitle = normalizedTitle
        self.originalTitle = originalTitle
        self.athleteId = athleteId
        self.sportId = sportId
        self.activityType = activityType
    }
}

/// Calendar Import Review V1.2: the classification `ExternalEventTitleSimilarity.suggestedMatch(forEventTitle:among:)`
/// proposes for a NEW event, plus which prior title it was matched
/// against — assistance only (see that method's own doc comment for
/// what this can and cannot be used for by a caller).
public struct SimilarEventMatch: Sendable, Equatable {
    public let athleteId: AthleteId
    public let sportId: SportId?
    public let activityType: ActivityType
    public let matchedOriginalTitle: String
}

/// Calendar Import Review V1.2 (Similar-Event Suggestions): the ONE
/// deterministic, explainable, conservative title-similarity rule this
/// feature uses — never AI/LLM, embeddings, opaque confidence scores, or
/// edit-distance fuzzy guessing. A pure function of its String inputs;
/// owns no business truth, persists nothing, and knows nothing about
/// `ExternalPlanningSource`/workspace/decision history — that scoping
/// stays entirely the service layer's job (see
/// `CalendarPlanningCoordinationService.historicalTitleClassifications(for:)`).
///
/// ALGORITHM (conservative, token-set based, order-independent):
///   1. Both titles are run through `ExternalEventTitleNormalization.normalize(_:)`
///      (trim/collapse whitespace, lowercase) — the SAME normalization
///      exact-title remembering already uses, so a title that already
///      matches EXACTLY is never treated as merely "similar" by a
///      caller that checks exact-remembered first (see `suggestedMatch`'s
///      own doc comment).
///   2. Each normalized title is split into TOKENS on any non-
///      alphanumeric boundary (whitespace, punctuation) — e.g.
///      "Hockeytrening U14, tirsdag!" tokenizes to
///      ["hockeytrening", "u14", "tirsdag"]. Compared as SETS, so word
///      order never matters ("U14 Hockeytrening" and "Hockeytrening U14"
///      tokenize to the same set).
///   3. Two titles are a candidate match ONLY if the SMALLER token set
///      has at least 2 tokens (a single shared word, e.g. just "u14", is
///      never sufficient evidence on its own) AND at least 75% of the
///      smaller title's own tokens also appear in the larger title
///      (`|intersection| / |smaller|`). This is intentionally NOT a
///      strict "every token must be present" rule: it is exactly the
///      natural shape of "the same activity, with a trailing/leading
///      word added or one incidental word changed" — e.g. "Hockeytrening
///      U14" plus a weekday suffix ("...tirsdag") stays a match (ratio
///      1.0, every shorter token present); two SHORT (2-token) titles
///      that share only one word (ratio 0.5) fall below the threshold on
///      their own already.
///   4. Even when step 3's ratio threshold passes, the two titles are
///      REJECTED as similar if they carry DIFFERENT protected "activity
///      marker" words — training/trening, match/kamp, meeting/møte,
///      tournament/cup — recognized as an exact token or a compound-word
///      suffix (so "hockeytrening" and "hockeykamp" are each recognized
///      as carrying a marker, and a DIFFERENT one). This is the layer
///      that actually matters for a LONGER title differing in only its
///      activity-type word — e.g. "Hockey training U14 Lag A" vs "Hockey
///      match U14 Lag A" clears step 3's 75% threshold (4 of 5 tokens
///      shared) but is vetoed here. A title with NO recognized marker on
///      either side is never blocked by this rule — only a genuine,
///      opposing marker conflict vetoes a match.
///
/// Intentionally does NOT maintain a large domain-language dictionary —
/// only the handful of marker groups this feature's own product contract
/// names. General token overlap (steps 2-3) does the rest of the work.
public enum ExternalEventTitleSimilarity {
    /// Protected "activity marker" word groups (see this type's own doc
    /// comment, step 4) — kept intentionally small; each entry is
    /// recognized as either a whole token or a compound-word suffix
    /// (`"hockeytrening".hasSuffix("trening")`).
    private static let activityMarkerGroups: [[String]] = [
        ["training", "trening", "øving", "øvelse", "practice"],
        ["match", "kamp", "game"],
        ["meeting", "møte", "meet"],
        ["tournament", "turnering", "cup"]
    ]

    /// Whole-string, order-independent title similarity — the public
    /// entry point for direct unit testing against raw title pairs, and
    /// the same rule `suggestedMatch(forEventTitle:among:)` below uses
    /// internally against already-normalized candidate titles. `false`
    /// for a `nil`/blank/whitespace-only title on either side, matching
    /// `ExternalEventTitleNormalization.normalize(_:)`'s own "no title,
    /// no participation" rule.
    public static func areSimilar(_ titleA: String?, _ titleB: String?) -> Bool {
        guard let normalizedA = ExternalEventTitleNormalization.normalize(titleA),
              let normalizedB = ExternalEventTitleNormalization.normalize(titleB) else {
            return false
        }
        return isSimilar(normalizedA: normalizedA, normalizedB: normalizedB)
    }

    /// Finds a conservative similar-event classification suggestion for
    /// `eventTitle` among `candidates` — the "SIMILAR" tier of this
    /// feature's own `EXACT -> SIMILAR -> no match` precedence (exact
    /// remembering is a SEPARATE, unchanged V1.1 path a caller must
    /// check FIRST; this method deliberately ignores any candidate whose
    /// `normalizedTitle` exactly equals `eventTitle`'s own, so it never
    /// re-derives what the exact path already owns).
    ///
    /// ATHLETE SAFETY: if more than one MATCHING candidate resolves to a
    /// different (athleteId, sportId, activityType) combination, this
    /// returns `nil` — human judgement wins over guessing, exactly like
    /// exact-title remembering's own ambiguity rule, just applied across
    /// the SET of similar (not identical) prior titles instead of one.
    /// `nil` for a `nil`/blank event title, or when no candidate is
    /// similar per `areSimilar(_:_:)`.
    ///
    /// Never persists anything, never creates a `PlannedActivity` or
    /// `CalendarImportDecision`, and never marks anything Ready — this is
    /// a pure classification PREFILL proposal; the caller decides what,
    /// if anything, to do with it (see
    /// `CalendarImportReviewViewModel.refreshQueueAndStaging()` for the
    /// actual staging behavior this feeds).
    public static func suggestedMatch(forEventTitle eventTitle: String?, among candidates: [HistoricalTitleClassification]) -> SimilarEventMatch? {
        guard let normalizedEventTitle = ExternalEventTitleNormalization.normalize(eventTitle) else { return nil }

        let matched = candidates.filter { candidate in
            candidate.normalizedTitle != normalizedEventTitle
                && isSimilar(normalizedA: normalizedEventTitle, normalizedB: candidate.normalizedTitle)
        }
        guard let first = matched.first else { return nil }

        struct ClassificationIdentity: Hashable {
            let athleteId: AthleteId
            let sportId: SportId?
            let activityType: ActivityType
        }
        let identities = Set(matched.map { ClassificationIdentity(athleteId: $0.athleteId, sportId: $0.sportId, activityType: $0.activityType) })
        guard identities.count == 1 else { return nil }

        return SimilarEventMatch(athleteId: first.athleteId, sportId: first.sportId, activityType: first.activityType, matchedOriginalTitle: first.originalTitle)
    }

    /// Calendar Import Review V1.3 (Suggested Ignore): finds a
    /// conservative suggested-ignore match for `eventTitle` among the
    /// ORIGINAL (non-normalized) titles of events the Parent has
    /// explicitly ignored before — reuses the EXACT SAME `areSimilar(_:_:)`
    /// rule V1.2's classification suggestion uses (see this type's own
    /// doc comment); this is deliberately not a second, unrelated
    /// matcher. Unlike `suggestedMatch(forEventTitle:among:)`, there is
    /// no classification VALUE to agree/disagree on here — an Ignore
    /// decision carries none (see `CalendarImportDecision`'s own doc
    /// comment) — so an exact-title match and a similar-title match
    /// behave IDENTICALLY: both simply return the FIRST matching prior
    /// title, for a caller's own "Based on: <title>" display. Never
    /// itself persists, creates, or suggests anything be marked Ready —
    /// a pure read the caller decides what, if anything, to do with.
    ///
    /// `nil` for a `nil`/blank event title, or when no previously-
    /// ignored title is similar (`areSimilar(_:_:)`'s own conservative
    /// token-overlap-plus-marker-veto rule, unchanged).
    public static func suggestedIgnoreMatch(forEventTitle eventTitle: String?, amongPreviouslyIgnoredTitles ignoredTitles: [String]) -> String? {
        guard eventTitle != nil else { return nil }
        return ignoredTitles.first { areSimilar(eventTitle, $0) }
    }

    // MARK: - Private

    /// See this type's own doc comment, step 3, for why 75% of the
    /// SMALLER title's tokens (never a symmetric ratio) is the
    /// threshold: conservative enough to reject two short titles that
    /// differ by one of only two meaningful words (ratio 0.5), while
    /// still tolerant of a single extra/changed word on a longer title
    /// — which step 4's marker veto then independently guards.
    private static let minimumOverlapRatio = 0.75

    private static func isSimilar(normalizedA: String, normalizedB: String) -> Bool {
        guard normalizedA != normalizedB else { return true }

        let tokensA = Set(tokens(fromNormalized: normalizedA))
        let tokensB = Set(tokens(fromNormalized: normalizedB))
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return false }

        let smaller = tokensA.count <= tokensB.count ? tokensA : tokensB
        let larger = tokensA.count <= tokensB.count ? tokensB : tokensA
        guard smaller.count >= 2 else { return false }

        let overlapRatio = Double(smaller.intersection(larger).count) / Double(smaller.count)
        guard overlapRatio >= Self.minimumOverlapRatio else { return false }

        let groupsA = markerGroups(in: tokensA)
        let groupsB = markerGroups(in: tokensB)
        if !groupsA.isEmpty, !groupsB.isEmpty, groupsA.isDisjoint(with: groupsB) {
            return false
        }
        return true
    }

    private static func tokens(fromNormalized normalized: String) -> [String] {
        normalized.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func markerGroups(in tokens: Set<String>) -> Set<Int> {
        var found: Set<Int> = []
        for token in tokens {
            for (index, group) in activityMarkerGroups.enumerated() where group.contains(where: { token == $0 || token.hasSuffix($0) }) {
                found.insert(index)
            }
        }
        return found
    }
}
