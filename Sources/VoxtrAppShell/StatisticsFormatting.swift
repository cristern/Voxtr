import Foundation

/// Statistics V1 UI: small, shared presentation-only formatting used by
/// the root athlete cards and the Athlete Statistics detail screen.
/// Deliberately not a "business" helper — it never interprets a value
/// (no "good"/"bad" framing), only renders the numbers Statistics
/// already computed.
enum StatisticsFormatting {
    /// `0` → "0m"; under an hour → "37m"; whole hours → "2h"; mixed →
    /// "2h 15m". Never rounds away a real, non-zero minute.
    static func minutes(_ totalMinutes: Int) -> String {
        guard totalMinutes > 0 else { return "0m" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        switch (hours, minutes) {
        case (0, _):
            return "\(minutes)m"
        case (_, 0):
            return "\(hours)h"
        default:
            return "\(hours)h \(minutes)m"
        }
    }

    /// `nil` (no samples at all) reads as "No data," never a fabricated
    /// number — the same "missing excluded, never zero" rule
    /// `StatisticsAggregate` itself already documents.
    static func average(_ mean: Double?) -> String {
        guard let mean else { return "No data" }
        return String(format: "%.1f", mean)
    }
}
