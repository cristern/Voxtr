import Foundation

/// Calendar Import Review V1.1 (Remembered Exact Choices): the ONE
/// deterministic, conservative normalization rule "exact title" matching
/// uses — never scattered inline in a ViewModel or View. Deliberately
/// does NOT do anything beyond whitespace/case normalization: no
/// substring, prefix/suffix, token-similarity, or fuzzy-distance
/// matching belongs here (see
/// `CalendarPlanningCoordinationService.rememberedClassifications(for:)`'s
/// own doc comment for the full V1.1 product contract this exists to
/// keep conservative and explainable).
public enum ExternalEventTitleNormalization {
    /// `nil` for a `nil`/blank/whitespace-only title — a titleless event
    /// can never participate in exact-title remembering, matching or
    /// matched against.
    ///
    /// Steps, in order: trim leading/trailing whitespace and newlines;
    /// collapse every run of internal whitespace (spaces, tabs,
    /// newlines) to a single space; lowercase for case-insensitive
    /// comparison. Two titles that normalize to the same string are
    /// considered the SAME exact title for remembered-choice purposes —
    /// nothing looser than that.
    public static func normalize(_ title: String?) -> String? {
        guard let title else { return nil }
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.lowercased()
    }
}
