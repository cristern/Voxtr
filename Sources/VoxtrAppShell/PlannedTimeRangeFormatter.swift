import Foundation
import VoxtrCoreContracts

/// Planned Activity Time Range Presentation: the one, shared way every
/// AppShell surface renders a planned activity's schedule time — a
/// start–end range (`18:00–19:30`) when a planned duration is also
/// known, start alone (`18:00`) otherwise. Introduced so end-time
/// arithmetic and the `HH:mm` format exist in exactly one place, reused
/// by Family Home, Family Schedule, Weekly Planning, Activity Detail,
/// and the Recurring Occurrence preview, rather than each screen
/// reimplementing its own version.
///
/// Deliberately pure `LocalTime` arithmetic via `LocalTime.adding(minutes:)`,
/// never `Date`/`Calendar` — a planned end time is exactly
/// `startLocalTime + plannedDurationMinutes`; going through `Date` would
/// require a time zone this computation has no reason to need. Midnight
/// crossing wraps to a valid clock time instead of crashing or
/// producing an out-of-range value.
///
/// One Truth: this NEVER derives a value that gets persisted anywhere —
/// the canonical schedule remains exactly `PlannedActivity.startLocalTime`
/// + `.plannedDurationMinutes` (or the equivalent pair on
/// `RecurringActivitySuggestion`); this type only ever formats them for
/// display, on demand, from whatever the caller currently has.
public enum PlannedTimeRangeFormatter {
    /// `18:00–19:30` when both `start` and `durationMinutes` are known;
    /// `18:00` when only `start` is known; `nil` when `start` is `nil` —
    /// a duration with no start is never used to invent a range, since
    /// there is nothing to anchor an end time to. Callers that still
    /// want a duration-only fallback in that case (e.g. "90 min") build
    /// it themselves from `durationMinutes` directly; this type never
    /// fabricates a time range from a duration alone.
    public static func label(start: LocalTime?, durationMinutes: Int?) -> String? {
        guard let start else { return nil }
        guard let durationMinutes else { return timeLabel(start) }
        let end = start.adding(minutes: durationMinutes)
        return "\(timeLabel(start))–\(timeLabel(end))"
    }

    /// `HH:mm`, zero-padded — the one existing convention every call
    /// site already used before this round (`String(format: "%02d:%02d",
    /// ...)`), now defined once.
    public static func timeLabel(_ time: LocalTime) -> String {
        String(format: "%02d:%02d", time.hour, time.minute)
    }
}
