import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrReflectionDomain

/// VX-023 (Sleep V1): one day in Sleep History — unlike
/// `WeeklyHistorySummary` (which OMITS empty weeks), a date with no
/// Sleep recorded still produces a row here, with `sleepQuality == nil`
/// — "include dates with no Sleep record as explicit 'Not logged' rows"
/// is part of the approved contract, not an oversight to fix later.
public struct SleepHistoryRow: Identifiable {
    public let localDate: LocalDate
    public let sleepQuality: Int?

    public var id: String { localDate.isoString }

    public init(localDate: LocalDate, sleepQuality: Int?) {
        self.localDate = localDate
        self.sleepQuality = sleepQuality
    }
}

/// VX-023: "Today"/"Yesterday"/"Aug 15" row-date labels — same
/// short-month-symbol `DateFormatter` technique `WeekIdentityFormatter.dateRangeLabel`
/// already establishes, reused rather than a second implementation.
/// Deliberately locale-independent for the day/month digits themselves
/// (driven by `LocalDate`'s own `year`/`month`/`day`, never `Calendar.current`),
/// matching this file's and package's "no locale-dependent Date/week
/// assumptions" contract.
public enum SleepHistoryDateFormatter {
    public static func label(for localDate: LocalDate, today: LocalDate) -> String {
        if localDate == today { return "Today" }
        if localDate == today.adding(days: -1) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        let month = formatter.shortMonthSymbols[localDate.month - 1]
        return "\(month) \(localDate.day)"
    }
}

/// VX-023: same cursor-based pagination shape as
/// `WeeklyHistoryListViewModel`, adapted for daily (not weekly) rows and
/// for the "no gaps" requirement above. Initial load is "today +
/// previous 13 days = 14 days"; `loadMore()` continues backward from
/// whatever date was oldest so far — "do not hard-limit canonical data
/// to 14 days," matching `WeeklyHistoryListViewModel`'s own "never stops
/// because of a hardcoded cutoff" philosophy (`canLoadMore` here is
/// always `true`; there is no natural end to how far back Sleep History
/// can be paged).
@MainActor
@Observable
public final class SleepHistoryViewModel {
    public let athleteId: AthleteId
    public private(set) var rows: [SleepHistoryRow] = []
    public private(set) var errorMessage: String?
    public private(set) var canLoadMore = true

    private let sleepStatusProvider: any SleepStatusProviding
    private let today: LocalDate
    /// The oldest date already loaded — `nil` until the first load.
    private var oldestLoadedDate: LocalDate?

    private static let pageSize = 14

    public init(sleepStatusProvider: any SleepStatusProviding, athleteId: AthleteId, today: LocalDate) {
        self.sleepStatusProvider = sleepStatusProvider
        self.athleteId = athleteId
        self.today = today
    }

    public func loadInitial() {
        rows = []
        oldestLoadedDate = nil
        errorMessage = nil
        loadMore()
    }

    /// One canonical range fetch per page (never one fetch per day) —
    /// missing dates within `[oldestDate, newestDate]` are filled in
    /// locally as `sleepQuality: nil` rows, so History never silently
    /// skips a day the way `WeeklyHistoryListViewModel` intentionally
    /// skips empty weeks.
    public func loadMore() {
        errorMessage = nil
        let newestDate = oldestLoadedDate?.adding(days: -1) ?? today
        let oldestDate = newestDate.adding(days: -(Self.pageSize - 1))
        do {
            let statuses = try sleepStatusProvider.fetchDailyStatuses(forAthlete: athleteId, from: oldestDate, to: newestDate)
            let byDate = Dictionary(uniqueKeysWithValues: statuses.map { ($0.localDate, $0) })
            var newRows: [SleepHistoryRow] = []
            var cursor = newestDate
            while cursor >= oldestDate {
                newRows.append(SleepHistoryRow(localDate: cursor, sleepQuality: byDate[cursor]?.sleepQuality))
                cursor = cursor.adding(days: -1)
            }
            rows.append(contentsOf: newRows)
        } catch {
            errorMessage = "Could not load Sleep history."
        }
        oldestLoadedDate = oldestDate
    }

    /// VX-023 (historical edit closeout): re-reads exactly one date's
    /// canonical value and replaces that ONE row in place — "edit
    /// history date rereads the corrected canonical value" without
    /// requiring a full `loadInitial()`/re-page. A no-op if that date
    /// isn't currently loaded (e.g. it's further back than what's been
    /// paged in yet).
    public func refreshRow(for localDate: LocalDate) {
        guard let index = rows.firstIndex(where: { $0.localDate == localDate }) else { return }
        let status = try? sleepStatusProvider.fetchDailyStatus(forAthlete: athleteId, localDate: localDate)
        rows[index] = SleepHistoryRow(localDate: localDate, sleepQuality: status?.sleepQuality)
    }
}
