import Testing
import Foundation
import VoxtrCoreContracts
import VoxtrCalendarPlanningDomain

// Calendar Import Review V1.2 (Similar-Event Suggestions): unlike most of
// this project's other tests, `ExternalEventTitleSimilarity` is a pure,
// stateless, Foundation-only helper with no SwiftData/@Model dependency —
// these tests need no Xcode/macOS SwiftData runtime and are expected to
// actually run wherever the Swift toolchain is available.

@Suite("ExternalEventTitleSimilarity (Calendar Import Review V1.2)")
struct ExternalEventTitleSimilarityTests {

    private static let athleteId = AthleteId()
    private static let secondAthleteId = AthleteId()
    private static let sportId = SportId()

    private func candidate(
        title: String,
        athleteId: AthleteId = ExternalEventTitleSimilarityTests.athleteId,
        sportId: SportId? = nil,
        activityType: ActivityType = .teamTraining
    ) throws -> HistoricalTitleClassification {
        let normalized = try #require(ExternalEventTitleNormalization.normalize(title))
        return HistoricalTitleClassification(
            normalizedTitle: normalized, originalTitle: title, athleteId: athleteId, sportId: sportId, activityType: activityType
        )
    }

    // MARK: - areSimilar(_:_:) — the raw matcher

    @Test("Required test 3: a title with an added trailing word ('tirsdag') is similar to its shorter form")
    func trailingWordAdditionIsSimilar() {
        #expect(ExternalEventTitleSimilarity.areSimilar("Hockeytrening U14", "Hockeytrening U14 tirsdag"))
        #expect(ExternalEventTitleSimilarity.areSimilar("Hockeytrening U14 tirsdag", "Hockeytrening U14"))
    }

    @Test("Required test 4: token reorder produces the same similarity verdict")
    func tokenReorderIsSimilar() {
        #expect(ExternalEventTitleSimilarity.areSimilar("U14 Hockeytrening", "Hockeytrening U14"))
        #expect(ExternalEventTitleSimilarity.areSimilar("Fotballtrening G2013", "G2013 Fotballtrening"))
    }

    @Test("Required test 5: a clearly different intent sharing only one word ('U14') is NOT similar")
    func differentIntentSharingOneWordIsNotSimilar() {
        #expect(!ExternalEventTitleSimilarity.areSimilar("Hockeytrening U14", "Foreldremøte U14"))
    }

    @Test("Required test 6: training vs match for the same sport is NOT similar")
    func trainingVersusMatchIsNotSimilar() {
        #expect(!ExternalEventTitleSimilarity.areSimilar("Hockeytrening U14", "Hockeykamp U14"))
        #expect(!ExternalEventTitleSimilarity.areSimilar("Fotballtrening Oliver", "Fotballkamp Oliver"))
    }

    @Test("A single shared word alone is never sufficient evidence, even if it is the entirety of one title")
    func singleSharedWordIsNeverSufficient() {
        #expect(!ExternalEventTitleSimilarity.areSimilar("U14", "Hockeytrening U14"))
    }

    @Test("Unrelated titles sharing no meaningful words are not similar")
    func unrelatedTitlesAreNotSimilar() {
        #expect(!ExternalEventTitleSimilarity.areSimilar("Hockeytrening U14", "Piano Lesson"))
    }

    @Test("A nil or blank title is never similar to anything, including another blank title")
    func blankTitlesAreNeverSimilar() {
        #expect(!ExternalEventTitleSimilarity.areSimilar(nil, "Hockeytrening U14"))
        #expect(!ExternalEventTitleSimilarity.areSimilar("Hockeytrening U14", "   "))
        #expect(!ExternalEventTitleSimilarity.areSimilar(nil, nil))
    }

    @Test("A longer title pair clearing the 75% overlap threshold (4 of 5 tokens shared) is still vetoed when the differing token is a conflicting activity marker (training vs match)")
    func markerConflictVetoesAnOtherwiseQualifyingLongerTitlePair() {
        // Overlap alone: {hockey, u14, lag, a} shared = 4/5 = 80%, clears
        // the 75% threshold — this specific case is REJECTED only
        // because of the explicit marker-group veto (step 4), not
        // because of the overlap ratio itself.
        #expect(!ExternalEventTitleSimilarity.areSimilar("Hockey training U14 Lag A", "Hockey match U14 Lag A"))
    }

    @Test("A longer title pair differing only in a non-marker word still clears both overlap and the (non-triggered) marker veto")
    func nonMarkerWordDifferenceOnLongerTitleIsStillSimilar() {
        // Same shape as the marker-conflict case above (4 of 5 tokens
        // shared, 80% overlap) but the differing word ("Oslo"/"Bergen")
        // is not a recognized activity marker, so no veto applies —
        // documents the deliberate, accepted limitation that this
        // matcher does not distinguish location words from the sport/
        // activity name itself without a dedicated marker for it.
        #expect(ExternalEventTitleSimilarity.areSimilar("Weekly Hockey Practice Oslo", "Weekly Hockey Practice Bergen"))
    }

    // MARK: - suggestedMatch(forEventTitle:among:) — the end-to-end suggestion

    @Test("Required test 3: an unambiguous historical classification produces a suggestion for a similar new title")
    func unambiguousHistoryProducesSuggestion() throws {
        let candidates = [try candidate(title: "Hockeytrening U14")]
        let match = ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14 tirsdag", among: candidates)
        let unwrapped = try #require(match)
        #expect(unwrapped.athleteId == Self.athleteId)
        #expect(unwrapped.activityType == .teamTraining)
        #expect(unwrapped.matchedOriginalTitle == "Hockeytrening U14")
    }

    @Test("Required test 4: token-reordered history still produces the same suggestion")
    func tokenReorderedHistoryProducesSuggestion() throws {
        let candidates = [try candidate(title: "U14 Hockeytrening")]
        let match = ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14", among: candidates)
        #expect(match?.athleteId == Self.athleteId)
    }

    @Test("Required test 5: a clearly different historical title produces no suggestion")
    func differentIntentHistoryProducesNoSuggestion() throws {
        let candidates = [try candidate(title: "Foreldremøte U14")]
        #expect(ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14", among: candidates) == nil)
    }

    @Test("Required test 6: a training-vs-match historical title produces no suggestion")
    func trainingVersusMatchHistoryProducesNoSuggestion() throws {
        let candidates = [try candidate(title: "Hockeykamp U14")]
        #expect(ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14", among: candidates) == nil)
    }

    @Test("Required test 7: two plausible-similar historical titles with DIFFERING classifications produce no suggestion")
    func conflictingSimilarHistoryProducesNoSuggestion() throws {
        let candidates = [
            try candidate(title: "Hockeytrening U14 Lag A", athleteId: Self.athleteId),
            try candidate(title: "Hockeytrening U14 Lag B", athleteId: Self.secondAthleteId)
        ]
        #expect(ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14", among: candidates) == nil)
    }

    @Test("Two plausible-similar historical titles that AGREE on classification still produce a suggestion")
    func agreeingSimilarHistoryProducesSuggestion() throws {
        let candidates = [
            try candidate(title: "Hockeytrening U14 Lag A", athleteId: Self.athleteId, sportId: Self.sportId, activityType: .teamTraining),
            try candidate(title: "Hockeytrening U14 Lag B", athleteId: Self.athleteId, sportId: Self.sportId, activityType: .teamTraining)
        ]
        let match = try #require(ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14", among: candidates))
        #expect(match.athleteId == Self.athleteId)
        #expect(match.sportId == Self.sportId)
    }

    @Test("A candidate whose normalized title exactly matches the event's own is never used for a SIMILAR suggestion — exact matching is a separate, upstream path")
    func exactNormalizedTitleCandidateIsIgnoredBySimilarPath() throws {
        let candidates = [try candidate(title: "Hockeytrening U14")]
        #expect(ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14", among: candidates) == nil)
    }

    @Test("Empty candidate history produces no suggestion")
    func emptyHistoryProducesNoSuggestion() {
        #expect(ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: "Hockeytrening U14 tirsdag", among: []) == nil)
    }
}
