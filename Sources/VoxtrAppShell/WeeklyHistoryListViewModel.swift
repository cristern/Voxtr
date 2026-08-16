import Foundation
import VoxtrCoreContracts

/// Area 6 correction: the approved Training contract is a discoverable
/// list of weeks — "This week", "Previous week", older weeks — each
/// with a factual summary, newest first. Selecting one opens that
/// week's detailed `WeeklyHistoryView`. This is NOT the same as a
/// single "open one week, navigate with arrows" screen (the earlier,
/// insufficient implementation) — that remains available as a
/// secondary navigation aid WITHIN the detail view, but this list is
/// the actual entry surface.
///
/// Still a pure read model: every summary is derived by calling
/// `WeeklyReviewCoordinationService.weeklyReview(forAthlete:weekStart:)`
/// per week — the exact same canonical assembly `WeeklyHistoryViewModel`
/// (the detail screen) and `WeeklyReviewView` (current week) already
/// use. No persisted history entity, no new domain concept.
public struct WeeklyHistorySummary: Identifiable {
    public let weekStart: LocalDate
    public let plannedCount: Int
    public let completedFromPlanCount: Int
    public let additionalCount: Int

    public var id: String { weekStart.isoString }
}

@MainActor
@Observable
public final class WeeklyHistoryListViewModel {
    public let athleteId: AthleteId
    public private(set) var summaries: [WeeklyHistorySummary] = []
    public private(set) var errorMessage: String?
    public private(set) var canLoadMore = true

    private let coordinationService: any WeeklyReviewProviding
    private let currentWeekStart: LocalDate
    /// The oldest week already loaded — nil until the first load.
    /// `loadMore()` continues backward from here, so "no arbitrary
    /// domain-level history limit" holds: the list only ever stops
    /// because the person stops asking for more, never because of a
    /// hardcoded cutoff.
    private var oldestLoadedWeekStart: LocalDate?

    /// How many weeks to fetch per page — a UI pagination convenience,
    /// not a domain limit. `loadMore()` can always be called again.
    private static let pageSize = 8

    public init(coordinationService: any WeeklyReviewProviding, athleteId: AthleteId, currentWeekStart: LocalDate) {
        self.coordinationService = coordinationService
        self.athleteId = athleteId
        self.currentWeekStart = currentWeekStart
    }

    public func loadInitial() {
        summaries = []
        oldestLoadedWeekStart = nil
        canLoadMore = true
        loadMore()
    }

    public func loadMore() {
        guard canLoadMore else { return }
        errorMessage = nil
        let startWeek = oldestLoadedWeekStart.map { $0.adding(days: -7) } ?? currentWeekStart
        var newSummaries: [WeeklyHistorySummary] = []
        var cursor = startWeek
        for _ in 0..<Self.pageSize {
            do {
                let result = try coordinationService.weeklyReview(forAthlete: athleteId, weekStart: cursor)
                // Issue 4: a week appears only when it has at least one
                // piece of canonical data — planned, logged, or a
                // Reflection. `Focus next week` is part of Reflection
                // and never independently qualifies a week; no
                // placeholder history record is created for an empty
                // week, it's simply omitted from this list.
                let hasData = !result.plannedActivities.isEmpty
                    || !result.loggedActivities.isEmpty
                    || result.weeklyReflection != nil
                if hasData {
                    // Review follow-up (cancellation sanity check):
                    // `isGenuinelyCompleted`, not `isCompleted` — see
                    // `PlannedActivityCompletion`'s own doc comment.
                    // Missed/Cancelled must never inflate this count.
                    let completed = result.plannedActivities.filter(\.isGenuinelyCompleted).count
                    let additional = result.loggedActivities.filter { $0.plannedActivityId == nil }.count
                    newSummaries.append(WeeklyHistorySummary(
                        weekStart: cursor,
                        plannedCount: result.plannedActivities.count,
                        completedFromPlanCount: completed,
                        additionalCount: additional
                    ))
                }
            } catch {
                errorMessage = "Could not load some weeks."
            }
            cursor = cursor.adding(days: -7)
        }
        summaries.append(contentsOf: newSummaries)
        oldestLoadedWeekStart = cursor.adding(days: 7)
    }
}
