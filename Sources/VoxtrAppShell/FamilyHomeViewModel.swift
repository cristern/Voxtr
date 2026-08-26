import Foundation
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Sprint 1 (Daily Use Foundation), Part 1. One row in the family-wide
/// Today's Schedule — a `PlannedActivity` tagged with which athlete it
/// belongs to. Never carries a "selected athlete" of its own; each row
/// is self-contained, matching "no global selected athlete state."
public struct FamilyHomeRow: Identifiable, Hashable {
    public let id: String
    public let athleteId: AthleteId
    public let athleteName: String
    public let plannedActivity: PlannedActivity
    public let isCompleted: Bool
    /// Activity outcome consistency closeout: the exact `LoggedActivity`
    /// this row resolved to, if any — carried through directly from
    /// `PlannedActivityCompletion.loggedActivity` (never a second,
    /// separate lookup). `isCompleted` above only ever meant "an
    /// outcome was resolved" (any status, including Missed/Cancelled) —
    /// correct for gating "is there still something to log," but wrong
    /// for display, which needs the REAL outcome. `outcomeStatus` below
    /// is what every display consumer must use instead.
    public let loggedActivity: LoggedActivity?

    /// The canonical outcome — `nil` exactly when nothing has been
    /// logged yet, matching `isCompleted == false`. Never a second,
    /// locally-derived flag; mirrors `ActivityDetailViewModel.outcomeStatus`'s
    /// own exact reasoning for the same problem on that screen.
    public var outcomeStatus: ActivityStatus? {
        loggedActivity?.status
    }

    public init(
        id: String,
        athleteId: AthleteId,
        athleteName: String,
        plannedActivity: PlannedActivity,
        isCompleted: Bool,
        loggedActivity: LoggedActivity? = nil
    ) {
        self.id = id
        self.athleteId = athleteId
        self.athleteName = athleteName
        self.plannedActivity = plannedActivity
        self.isCompleted = isCompleted
        self.loggedActivity = loggedActivity
    }

    /// Recurring cancel/materialization fix: identifies a
    /// `PlannedActivity` that originated from a recurring definition —
    /// e.g. one materialized by "Log Activity" on a recurring
    /// occurrence but not yet logged (the exact state after the user
    /// cancels), which must still present as recurring through any
    /// fresh recomposition.
    ///
    /// Compares `externalSourceType` against `RecurringPlannedActivity`'s
    /// own constant — deliberately NOT `externalSourceId != nil`.
    /// Repository-wide inspection confirmed `externalSourceId`/
    /// `externalSourceType` are a GENERIC external-provenance pair (the
    /// `type` half exists precisely because more than one source kind is
    /// anticipated); recurring materialization merely happens to be the
    /// only producer today. Treating any non-nil `externalSourceId` as
    /// "recurring" would silently mislabel every future external source.
    ///
    /// Read directly from the persisted `PlannedActivity` on every
    /// access — never cached, so it cannot go stale across
    /// recomposition.
    public var isFromRecurring: Bool {
        plannedActivity.externalSourceType == RecurringPlannedActivity.externalSourceType
    }

    /// White-screen-after-Save (stable navigation destination) fix:
    /// `Hashable`/`Equatable` by `id` alone — the same stable string
    /// identity `Identifiable` above already uses, derived from
    /// `PlannedActivity.id`, never a deep comparison of every field.
    /// This row is now carried DIRECTLY inside `FamilyHomeDestination`/
    /// `HomeDashboardDestination`'s own `.activity` case (see those
    /// types' own doc comments) so `.navigationDestination(for:)` never
    /// needs to look this row back up in a mutable, refreshable
    /// collection to resolve an already-pushed destination. Hashing only
    /// `id` — rather than deriving conformance from every stored
    /// property, which would also require `PlannedActivity`/
    /// `LoggedActivity` (SwiftData `@Model` reference types) to
    /// participate — means the SAME logical activity still hashes/
    /// compares equal across a refresh even though `isCompleted`/
    /// `loggedActivity` legitimately changed; SwiftUI's own navigation
    /// identity for this destination should track "which activity," not
    /// "what did it look like at push time."
    public static func == (lhs: FamilyHomeRow, rhs: FamilyHomeRow) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Parent Home UX / Content Contract package: "Focus this week" — the
/// SAME persisted `nextWeekConsideration` value from the PRIOR week's
/// reflection, presented on Family Home under a new label. Never a
/// duplicate, Home-specific focus field — the prior reflection remains
/// the sole source of truth (this struct carries no ID of its own
/// distinct from the athlete/reflection it's drawn from).
///
/// Deliberately excludes any athlete with no relevant prior focus —
/// see `loadFocusThisWeek()`'s own `compactMap`: absence must show
/// nothing, not an empty/placeholder state. Also carries no
/// "incomplete" or "missing" notion at all — Focus ≠ Goal, and there
/// is no completion state to be missing.
public struct AthleteFocusThisWeek: Identifiable {
    public let id: String
    public let athleteId: AthleteId
    public let athleteName: String
    public let focus: String
}

/// VX-023 (Sleep V1): one row in Family Home's dedicated Sleep section —
/// one per athlete with Sleep tracking ON. An athlete with tracking OFF
/// never produces a row here at all ("no Family Home Sleep action" when
/// disabled), rather than a row with some "disabled" state to render
/// around. `sleepQuality == nil` means today's Sleep is missing — the UI
/// layer, not this struct, decides what action(s) that implies (e.g.
/// "Log Sleep" + "History" vs. "History" only).
public struct AthleteSleepSummary: Identifiable {
    public let id: String
    public let athleteId: AthleteId
    public let athleteName: String
    public let sleepQuality: Int?
}

/// Sprint 1 integration audit fix: `RestoredFamily.activeAthletes` is a
/// launch-time snapshot — it is never re-queried after app launch (see
/// `AthleteFamilyManagementViewModel`'s own established doc comment on
/// exactly this limitation, written when the multi-athlete foundation
/// was built, well before this sprint). Family Home was built directly
/// on top of that stale snapshot, with no refresh of its own — so an
/// athlete added, archived, or edited after launch silently never
/// appeared (or a stale one silently failed to resolve, e.g. the
/// reflection reminder's "Add reflection" link going dead once the
/// snapshot's athlete no longer matched anything meaningful). This is
/// the actual architectural gap behind those symptoms, not a collection
/// of unrelated bugs: `FamilyHomeViewModel` now owns a refreshable
/// `activeAthletes` list, re-fetched from `AthleteRepository` on every
/// appearance, and is the single source of truth `FamilyHomeContentView`
/// reads from for every athlete lookup — `family.activeAthletes` is no
/// longer read anywhere in that view.
@MainActor
@Observable
public final class FamilyHomeViewModel: AthleteSleepChangeSubscriber {
    public private(set) var activeAthletes: [AthleteProfile]
    /// Parent Home UX / Content Contract: derived from the PRIOR
    /// week's reflection only — never the current week's. See
    /// `AthleteFocusThisWeek`'s own doc comment.
    public private(set) var focusThisWeek: [AthleteFocusThisWeek] = []
    public private(set) var errorMessage: String?

    public private(set) var rows: [TodayActivityRow] = []
    public private(set) var tomorrowRows: [TodayActivityRow] = []
    /// VX-023: Family Home's dedicated Sleep section — see
    /// `AthleteSleepSummary`'s own doc comment.
    public private(set) var sleepSummaries: [AthleteSleepSummary] = []
    /// Design Foundation V0.1 (Athlete Color canonical preference
    /// round): one RESOLVED colour per active athlete — explicit
    /// `AthleteSettings.preferredColor` if the athlete has ever set one,
    /// otherwise the stable `AthleteColor.forAthleteId(_:)` fallback.
    /// Refreshed in `refresh()`, alongside everything else that depends
    /// on the active-athlete roster. `resolvedAthleteColor(for:)` below
    /// is the one function every Family Home row actually calls — it
    /// still falls back safely even for an `AthleteId` this map hasn't
    /// been populated for yet (e.g. between `refreshActiveAthletes()`
    /// and this map's own load completing).
    public private(set) var athleteColors: [AthleteId: AthleteColor] = [:]
    private let workspaceId: WorkspaceId
    private let athleteRepository: AthleteRepository
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let weeklyReflectionService: WeeklyReflectionService
    private let todayActivityComposer: TodayActivityComposer
    /// VX-023: optional/defaulted `nil`, same "one dependency's absence
    /// never corrupts the rest of this ViewModel" reasoning
    /// `HomeDashboardViewModel.sleepStatusProvider` already establishes
    /// — every pre-existing construction site (production and test)
    /// predates Sleep and doesn't need updating; `loadSleepSummaries()`
    /// simply produces an empty list if none was supplied.
    private let sleepStatusProvider: (any SleepStatusProviding)?
    /// VX-023 (live invalidation): optional/defaulted `nil`, same
    /// reasoning as `sleepStatusProvider` above — no broadcaster
    /// supplied means Family Home's Sleep section simply never
    /// subscribes, and only refreshes on explicit `refresh()` calls
    /// (e.g. `.onAppear`), same as every pre-Sleep behavior on this
    /// screen already works.
    private let sleepChangeBroadcaster: AthleteSleepChangeBroadcaster?
    /// One `SleepChangeSubscription` per currently-active athlete,
    /// reconciled in `refreshActiveAthletes()` below whenever the
    /// roster changes — never left dangling for an athlete that's no
    /// longer active (removing a key here drops the last strong
    /// reference, whose own `deinit` unsubscribes deterministically,
    /// the same mechanism `HomeDashboardViewModel`'s own subscriptions
    /// already rely on). `FamilyHomeViewModel` itself has no `deinit`
    /// of its own — same reasoning as `HomeDashboardViewModel`'s own
    /// doc comment on why: an `@MainActor`-isolated class's `deinit` is
    /// `nonisolated` and cannot read its own isolated stored properties.
    private var sleepChangeSubscriptions: [AthleteId: SleepChangeSubscription] = [:]

    public init(
        activeAthletes: [AthleteProfile],
        workspaceId: WorkspaceId,
        athleteRepository: AthleteRepository,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        sleepStatusProvider: (any SleepStatusProviding)? = nil,
        sleepChangeBroadcaster: AthleteSleepChangeBroadcaster? = nil
    ) {
        self.activeAthletes = activeAthletes
        self.workspaceId = workspaceId
        self.athleteRepository = athleteRepository
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.todayActivityComposer = TodayActivityComposer(
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        self.sleepStatusProvider = sleepStatusProvider
        self.sleepChangeBroadcaster = sleepChangeBroadcaster
        // Subscribe for whatever roster was passed in at construction —
        // refreshActiveAthletes() reconciles this further on every
        // refresh(). Must run after every other stored property is set
        // (subscribe(self) requires full initialization), same ordering
        // constraint HomeDashboardViewModel's own init documents.
        reconcileSleepSubscriptions()
    }

    /// VX-023 (live invalidation): subscribes any active athlete not
    /// already subscribed, and drops the subscription (via dictionary
    /// removal — see `sleepChangeSubscriptions`'s own doc comment) for
    /// any athlete no longer active. A no-op when no broadcaster was
    /// supplied.
    private func reconcileSleepSubscriptions() {
        guard let sleepChangeBroadcaster else { return }
        let activeIds = Set(activeAthletes.map(\.athleteId))
        for athleteId in activeIds where sleepChangeSubscriptions[athleteId] == nil {
            let token = sleepChangeBroadcaster.subscribe(athleteId: athleteId, self)
            sleepChangeSubscriptions[athleteId] = SleepChangeSubscription(
                athleteId: athleteId, token: token, broadcaster: sleepChangeBroadcaster
            )
        }
        for athleteId in sleepChangeSubscriptions.keys where !activeIds.contains(athleteId) {
            sleepChangeSubscriptions.removeValue(forKey: athleteId)
        }
    }

    /// `AthleteSleepChangeSubscriber` conformance: any active athlete's
    /// Sleep change reloads the whole section — Family Home's Sleep
    /// section is family-wide, not per-athlete, so there is no
    /// per-athlete partial reload to do.
    public func athleteSleepDidChange() {
        loadSleepSummaries()
    }

    /// The single entry point the view calls on appear — refreshes the
    /// athlete roster first, then loads everything that depends on it,
    /// in that order, so today's schedule and the reflection reminder
    /// never operate against a stale roster.
    public func refresh() {
        refreshActiveAthletes()
        loadHome()
        loadTomorrow()
        loadFocusThisWeek()
        loadSleepSummaries()
        loadAthleteColors()
    }

    /// Design Foundation V0.1 (Athlete Color canonical preference
    /// round): resolves and caches each active athlete's colour —
    /// "explicit preference wins, otherwise the stable fallback," read
    /// fresh from `AthleteSettings` on every refresh so a colour change
    /// made in Athlete Settings shows up here the next time Family Home
    /// appears (same "re-fetch on appear, no live push" freshness model
    /// every other section on this screen already uses). One athlete's
    /// fetch failure never blocks another's — falls back to the stable
    /// mapping for that athlete only, same per-athlete isolation
    /// `loadHome()`/`loadTomorrow()` already establish.
    public func loadAthleteColors() {
        var resolved: [AthleteId: AthleteColor] = [:]
        for athlete in activeAthletes {
            resolved[athlete.athleteId] = AthleteColor.resolved(forAthlete: athlete.athleteId, using: athleteRepository)
        }
        athleteColors = resolved
    }

    /// The one function every Family Home row calls for an athlete's
    /// colour — never `AthleteColor.forAthleteId(_:)` directly, so a
    /// row can never accidentally skip an athlete's explicit
    /// preference. Falls back to the same stable mapping directly if
    /// `athleteColors` hasn't been populated for this id yet, so a row
    /// is never left with no colour at all.
    public func resolvedAthleteColor(for athleteId: AthleteId) -> AthleteColor {
        athleteColors[athleteId] ?? AthleteColor.forAthleteId(athleteId)
    }

    /// VX-023: one `AthleteSleepSummary` per active athlete with Sleep
    /// tracking ON — an athlete with tracking OFF, or whose tracking
    /// check itself fails, is simply excluded (same per-athlete failure
    /// isolation `loadHome()`/`loadTomorrow()` already establish; one
    /// athlete's failure never blocks another's row).
    public func loadSleepSummaries(referenceDate: Date = .now, calendar: Calendar = .current) {
        guard let sleepStatusProvider else {
            sleepSummaries = []
            return
        }
        let today = SleepCoordinationService.today(referenceDate: referenceDate, calendar: calendar)
        sleepSummaries = activeAthletes.compactMap { athlete in
            guard let enabled = try? sleepStatusProvider.isSleepTrackingEnabled(for: athlete.athleteId), enabled else {
                return nil
            }
            let status = try? sleepStatusProvider.fetchDailyStatus(forAthlete: athlete.athleteId, localDate: today)
            return AthleteSleepSummary(
                id: athlete.athleteId.rawValue.uuidString,
                athleteId: athlete.athleteId,
                athleteName: athlete.givenName,
                sleepQuality: status?.sleepQuality
            )
        }
    }

    /// Re-fetches from persistence — the same repository method and
    /// active-only filter `AthleteFamilyManagementViewModel.loadAthletes()`
    /// already established, kept deterministically ordered the same way
    /// (createdAt, then id) so this list's order never surprises a
    /// caller relying on "first active athlete."
    public func refreshActiveAthletes() {
        do {
            let fetched = try athleteRepository.fetchAthletes(forWorkspace: workspaceId)
            activeAthletes = fetched
                .filter { !$0.isArchived }
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
        } catch {
            // Keep whatever roster was already known (the launch-time
            // snapshot, or a previous successful refresh) rather than
            // clearing it on a transient failure.
        }
        reconcileSleepSubscriptions()
    }

    /// Calls the already-existing, per-athlete
    /// `todaysPlannedActivitiesWithCompletion(forAthlete:)` once per
    /// active athlete and merges the results — no new persistence
    /// query, no schema change; this is a pure application-layer
    /// aggregation over an already-existing capability.
    public func loadHome() {
        errorMessage = nil
        var merged: [TodayActivityRow] = []
        var anyFailed = false
        for athlete in activeAthletes {
            do {
                let athleteRows = try todayActivityComposer.todayActivities(
                    forAthlete: athlete.athleteId, athleteName: athlete.givenName
                )
                merged.append(contentsOf: athleteRows)
            } catch {
                // One athlete's failure must never block the others —
                // same principle HomeDashboardViewModel's own two
                // independent load states already establish.
                anyFailed = true
            }
        }
        // Family Home presentation ordering (fix: this grouping was lost
        // when loadHome() moved from its own per-athlete fetch to
        // TodayActivityComposer, which only sorts chronologically — see
        // TodayActivityComposer.todayActivities(...)'s own doc comment).
        // Not-completed rows first (chronological), completed/logged
        // rows last (chronological) — the same pre-existing contract
        // FamilyHomeViewModel.sorted(_:) below still applies to
        // tomorrowRows. This is presentation ordering on top of the
        // composer's already-composed data, not a second aggregation —
        // the composer itself remains the single source of what rows
        // exist; only their order here is Family-Home-specific.
        let notCompleted = merged.filter { !$0.isCompletedOrLogged }.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
        let completed = merged.filter { $0.isCompletedOrLogged }.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
        rows = notCompleted + completed
        if anyFailed && rows.isEmpty {
            errorMessage = "Could not load today's activities."
        }
    }

    /// Sprint 1 completion package, Part 4: tomorrow's activities
    /// across every active athlete — same aggregation shape as
    /// `loadHome()`, over the generalized, date-parameterized
    /// coordination-service method rather than a new one hardcoded to
    /// "tomorrow." No new persisted model, no duplicated activities —
    /// this reads the same `PlannedActivity` rows `loadHome()` and
    /// every other surface already read.
    public func loadTomorrow() {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) else {
            tomorrowRows = []
            return
        }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: tomorrow)
        let tomorrowDate = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)

        var merged: [TodayActivityRow] = []
        for athlete in activeAthletes {
            let athleteRows = (try? todayActivityComposer.activities(
                forAthlete: athlete.athleteId, athleteName: athlete.givenName,
                on: tomorrowDate, includeUnplannedLogged: false
            )) ?? []
            merged.append(contentsOf: athleteRows)
        }
        // Same presentation ordering as loadHome() above — not-completed
        // first (chronological), completed/logged last (chronological).
        let notCompleted = merged.filter { !$0.isCompletedOrLogged }.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
        let completed = merged.filter { $0.isCompletedOrLogged }.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
        tomorrowRows = notCompleted + completed
    }


    /// Parent Home UX / Content Contract: "Focus this week" — the SAME
    /// persisted `nextWeekConsideration` value from the PRIOR week's
    /// reflection (never the current week's, and never a duplicate,
    /// Home-specific field). `compactMap`, not `map`: an athlete with
    /// no prior reflection, or a prior reflection with no
    /// `nextWeekConsideration` text, is simply absent from the result —
    /// no "reflection incomplete"/"no focus entered" placeholder is
    /// ever constructed for them. Same per-athlete failure isolation
    /// as `loadHome()`/`loadTomorrow()` above.
    ///
    /// Privacy: excludes any reflection whose own `visibility` is
    /// `.privateToAthlete`. This is not a new restriction invented
    /// here — it's the conservative choice that avoids broadening
    /// access: this method displays the reflection's actual text
    /// content on Parent Home, which the reflection's own visibility
    /// setting must authorize. (This package's audit found the prior,
    /// now-removed reminder never rendered reflection text in its UI
    /// at all — only a bare "Recorded"/"not yet" status — so it never
    /// had to make this check; this method does, since it surfaces the
    /// content itself.) Long-term Reflection privacy architecture is
    /// explicitly out of scope here — this is the minimum conservative
    /// gate against the visibility rule that already exists today.
    public func loadFocusThisWeek() {
        let priorWeekStart = TrainingPlanningCoordinationService.weekStart().adding(days: -7)
        focusThisWeek = activeAthletes.compactMap { athlete in
            let reflection = (try? weeklyReflectionService.fetchWeeklyReflection(forAthlete: athlete.athleteId, weekStart: priorWeekStart)) ?? nil
            guard let reflection, reflection.visibility != .privateToAthlete else {
                return nil
            }
            guard let focus = reflection.nextWeekConsideration,
                  !focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AthleteFocusThisWeek(
                id: athlete.athleteId.rawValue.uuidString,
                athleteId: athlete.athleteId,
                athleteName: athlete.givenName,
                focus: focus
            )
        }
    }

    /// Parent Home UX / Content Contract, Now/Next: computed, not a
    /// separately loaded/cached state — derives entirely from `rows`/
    /// `tomorrowRows` above, the SAME canonical composed activities
    /// Today/Tomorrow already display. No parallel activity identity
    /// or lifecycle logic, no new query, no materialization: this is
    /// purely a different slice/ordering of data already loaded by
    /// `loadHome()`/`loadTomorrow()`. `@Observable` re-evaluates this
    /// automatically whenever those change.
    ///
    /// "Underway" (NOW) is `start <= current time < end` — genuinely
    /// in progress right now, not merely "started at some point,
    /// whenever that was." `end` is derived from each row's own
    /// `endLocalTimeSortKey` (start + duration, see that property's
    /// own doc comment) — not inferred from completion state alone: an
    /// activity that ended hours ago but hasn't been logged yet must
    /// not still occupy NOW.
    ///
    /// Planned/Logged Activity lifecycle consistency cleanup (NOW
    /// fallback): a row with a start time but genuinely unknown
    /// duration used to NEVER be classified NOW at all, no matter how
    /// long ago it started — a real presentation gap, not a faithful
    /// "we don't know," since a parent watching the schedule has no way
    /// to tell "not happening" from "duration wasn't entered." NOW now
    /// uses `nowPresentationEndLocalTimeSortKey(fallbackDurationMinutes:)`
    /// instead of `endLocalTimeSortKey` directly (see that method's own
    /// doc comment): a real planned/logged duration still wins whenever
    /// one exists; only when duration is genuinely absent does a
    /// `nowFallbackDurationMinutes`-minute presentation window apply,
    /// and only when a start time exists at all — a row with no start
    /// time is still never NOW. This fallback is read/presentation-only:
    /// never written to `PlannedActivity.plannedDurationMinutes` or
    /// `LoggedActivity.durationMinutes`, and never reaches Statistics.
    /// It also can't be NEXT once its start has passed (NEXT requires
    /// `start > now`) — a row with no start time simply falls out of
    /// Now/Next entirely, remaining visible in Today's own full list,
    /// just not occupying this slot.
    /// NEXT/TOMORROW both take every row sharing the single earliest
    /// remaining start time — not one arbitrary winner — so genuinely
    /// simultaneous/closely-timed activities across different children
    /// are never hidden from
    /// each other.
    public var nowNextState: NowNextState {
        nowNextState(referenceDate: .now, calendar: .current)
    }

    /// Planned/Logged Activity lifecycle consistency cleanup: the
    /// presentation-only NOW window applied when a row has a start time
    /// but no real planned/logged duration — see `nowNextState`'s own
    /// doc comment. Never persisted, never read by anything outside
    /// this NOW/NEXT computation.
    private static let nowFallbackDurationMinutes = 60

    /// Maintainability fix: the underlying logic, with an injectable
    /// `referenceDate`/`calendar` — exists so tests can construct a
    /// genuinely deterministic scenario (a fixed reference instant)
    /// rather than depending on wall-clock `.now` in a way that could
    /// theoretically cross a day boundary mid-test. `nowNextState`
    /// above is the one public, unchanged API every existing caller
    /// already uses — this defaults to the exact same `.now`/`.current`
    /// it always used, so no existing behavior changes.
    func nowNextState(referenceDate: Date, calendar: Calendar) -> NowNextState {
        let components = calendar.dateComponents([.hour, .minute], from: referenceDate)
        let nowMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        let activeToday = rows.filter { !$0.isCompletedOrLogged && $0.startLocalTimeSortKey != Int.max }

        let underway = activeToday.filter { row in
            guard let end = row.nowPresentationEndLocalTimeSortKey(fallbackDurationMinutes: Self.nowFallbackDurationMinutes) else { return false }
            return row.startLocalTimeSortKey <= nowMinutes && nowMinutes < end
        }
        if !underway.isEmpty {
            return .now(underway.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey })
        }

        let upcomingToday = activeToday.filter { $0.startLocalTimeSortKey > nowMinutes }
        if let earliestKey = upcomingToday.map(\.startLocalTimeSortKey).min() {
            return .next(upcomingToday.filter { $0.startLocalTimeSortKey == earliestKey })
        }

        // Fix: NEXT must never fall forward into tomorrow — Tomorrow
        // already owns tomorrow's own preview (tomorrowSection), and
        // showing the same activity here too duplicated it on screen.
        // When nothing relevant remains today, the correct result is
        // .empty, not a synthetic "next (tomorrow)" fallback.
        return .empty
    }
}

/// Parent Home UX / Content Contract: the Now/Next surface's own
/// state — carries `TodayActivityRow`s directly (never a new wrapper
/// type), so the UI layer reuses the exact same row-rendering
/// component Today/Tomorrow already use. Visually repeating an
/// activity also present in Today is presentation of the SAME
/// activity identity, not duplicate domain data — no new `Identifiable`
/// conformance/ID is introduced here.
public enum NowNextState {
    case now([TodayActivityRow])
    case next([TodayActivityRow])
    case empty
}
