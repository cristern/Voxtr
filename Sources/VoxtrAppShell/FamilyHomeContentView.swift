import SwiftUI
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Sprint 1 (Daily Use Foundation), Part 1. Each destination carries
/// its own identity directly — there is no shared, mutable "currently
/// selected athlete" anywhere in this type or its view, matching "no
/// global selected athlete state." A `NavigationLink(value:)` for one
/// row's athlete and one for its activity are both fully self-contained.
enum FamilyHomeDestination: Hashable {
    case athlete(AthleteId)
    case activity(rowId: String)
    case recurringOccurrence(id: String)
    case reflection(AthleteId)
    case familySchedule
    /// VX-023 (Sleep V1) UX polish: Family Home Sleep is a monitoring
    /// surface — Athlete Home is the one place Sleep gets recorded, so
    /// the Family Home Sleep section no longer offers a "Log Sleep"
    /// action, and nothing in `FamilyHomeContentView` currently pushes
    /// this destination. Retained (not deleted) rather than removed
    /// outright, since deleting it wasn't part of this presentation-only
    /// change; if it stays unreachable, removing it is a follow-up, not
    /// a decision to make silently here.
    case sleepCapture(AthleteId)
    /// "History" opens the same canonical Sleep History used from
    /// Athlete Home — never a second, Family-Home-specific Sleep
    /// surface; both route to the exact same `SleepHistoryView` Athlete
    /// Home already uses.
    case sleepHistory(AthleteId)
}

/// Athlete Home mounted-instance fix (post-mutation navigation and
/// stale-state consistency audit, closeout): `.navigationDestination(for:)`'s
/// closure is not guaranteed to run exactly once per push — it is an
/// ordinary `@ViewBuilder` closure SwiftUI re-invokes on ordinary body
/// re-evaluations of the enclosing `NavigationStack` scope, which keeps
/// evaluating even while a pushed screen covers it. `athleteOverview(for:)`
/// used to construct a BRAND NEW `HomeDashboardViewModel` on every such
/// re-invocation, with no reuse across repeated calls for the same
/// athlete. Traced instance identity end to end: the row inside
/// `HomeDashboardView.todayActivityRow` captures whichever
/// `HomeDashboardViewModel` was live when THAT row was last built, and
/// calls `onActivityLogged` on it; the screen actually visible after
/// returning from Activity Detail is bound to whatever `HomeDashboardView`
/// value the destination closure most recently produced. Nothing in the
/// original code guaranteed these were the same object — only
/// `@State`'s identity-preservation contract did, and that contract
/// depends on SwiftUI recognizing repeated destination-closure output
/// as the same logical view, which is not something this call chain
/// (switch → if-let → a separate helper function → a fresh
/// `HomeDashboardViewModel(...)` call) enforces or verifies. Caching
/// exactly one `HomeDashboardViewModel` per athlete removes the
/// possibility entirely: `athleteOverview(for:)` now always hands back
/// the SAME instance for the same athlete, regardless of how many times
/// the destination closure itself happens to re-run — One Truth applied
/// to object identity, not only to persisted data.
///
/// Deliberately NOT `@Observable`/`@Published` itself — a plain,
/// non-reactive lookup table SwiftUI never needs to diff. Mutating it
/// during body/destination-closure evaluation (the only time
/// `athleteOverview(for:)` ever runs) is therefore safe: it never goes
/// through a `@State` setter, unlike the individual
/// `HomeDashboardViewModel` instances it hands out, which remain
/// individually `@Observable` and are what `HomeDashboardView`'s own
/// `@State` actually tracks.
@MainActor
final class HomeDashboardViewModelCache {
    private var viewModelsByAthlete: [AthleteId: HomeDashboardViewModel] = [:]

    /// Returns the existing `HomeDashboardViewModel` for `athleteId` if
    /// this cache already created one, otherwise creates it via
    /// `make()`, stores it, and returns it. `make()` is never invoked
    /// for an athlete this cache already holds an instance for.
    func viewModel(for athleteId: AthleteId, make: () -> HomeDashboardViewModel) -> HomeDashboardViewModel {
        if let existing = viewModelsByAthlete[athleteId] {
            return existing
        }
        let created = make()
        viewModelsByAthlete[athleteId] = created
        return created
    }
}

/// The actual Family Home content — replaces the previous
/// single-athlete `HomeDashboardView` at this position in the
/// navigation hierarchy. `HomeDashboardView` itself is unchanged in
/// content and is now what Athlete Overview presents (see
/// `FamilyHomeDestination.athlete`), not what Home shows directly.
///
/// Sprint 1 integration audit: every athlete lookup in this view reads
/// from `viewModel.activeAthletes` (refreshed from `AthleteRepository`
/// on appear), never from `family.activeAthletes` directly — the
/// latter is a launch-time snapshot that goes stale the moment an
/// athlete is added, archived, or edited after launch. See
/// `FamilyHomeViewModel`'s own doc comment for the full explanation.
public struct FamilyHomeContentView: View {
    @State private var viewModel: FamilyHomeViewModel
    /// Athlete Home mounted-instance fix: see `HomeDashboardViewModelCache`'s
    /// own doc comment. Held via `@State` only so it survives this
    /// view's own re-renders as a stable object reference — never
    /// reassigned after its default value, so no `@State` write ever
    /// occurs here; only the cache's OWN internal dictionary mutates.
    @State private var homeDashboardViewModelCache = HomeDashboardViewModelCache()
    private let family: RestoredFamily
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    private let weeklyReflectionService: WeeklyReflectionService
    private let coachingApplicationService: CoachingApplicationService
    private let athleteManagementViewModel: AthleteFamilyManagementViewModel
    /// Recurring reopen stale-Athlete-Home fix (architecture round):
    /// passed straight through to every `HomeDashboardViewModel` this
    /// view constructs (`athleteOverview(for:)` below) so each one
    /// subscribes to canonical activity-lifecycle mutations regardless
    /// of which screen performs them — this view's own
    /// `.recurringOccurrence`/`.activity` destinations no longer need to
    /// know `HomeDashboardViewModelCache` exists to keep an
    /// already-mounted Athlete Home current.
    private let activityChangeBroadcaster: AthleteActivityChangeBroadcaster
    /// VX-023 (Sleep V1): threaded to every `HomeDashboardViewModel` this
    /// view constructs (`athleteOverview(for:)` below) and to this
    /// view's own `FamilyHomeViewModel` — same rationale as
    /// `activityChangeBroadcaster` above, for the separate Sleep
    /// coordination service/broadcaster pair.
    private let sleepCoordinationService: SleepCoordinationService
    private let sleepChangeBroadcaster: AthleteSleepChangeBroadcaster

    public init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteRepository: AthleteRepository,
        athleteManagementViewModel: AthleteFamilyManagementViewModel,
        activityChangeBroadcaster: AthleteActivityChangeBroadcaster,
        sleepCoordinationService: SleepCoordinationService,
        sleepChangeBroadcaster: AthleteSleepChangeBroadcaster
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteManagementViewModel = athleteManagementViewModel
        self.activityChangeBroadcaster = activityChangeBroadcaster
        self.sleepCoordinationService = sleepCoordinationService
        self.sleepChangeBroadcaster = sleepChangeBroadcaster
        _viewModel = State(initialValue: FamilyHomeViewModel(
            activeAthletes: family.activeAthletes,
            workspaceId: WorkspaceId(rawValue: family.workspace.id),
            athleteRepository: athleteRepository,
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService,
            sleepStatusProvider: sleepCoordinationService,
            sleepChangeBroadcaster: sleepChangeBroadcaster
        ))
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("familyHome.errorMessage")
                    }
                }

                nowNextSection

                Section("Today's Schedule") {
                    if viewModel.rows.isEmpty {
                        Text("Nothing planned for today.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.rows) { row in
                            todayActivityRow(row)
                        }
                    }
                }
                .accessibilityIdentifier("familyHome.scheduleList")

                tomorrowSection

                Section {
                    NavigationLink("View upcoming schedule", value: FamilyHomeDestination.familySchedule)
                        .accessibilityIdentifier("familyHome.familyScheduleLink")
                }

                focusThisWeekSection
                sleepSection
                reflectionNavigationSection
            }
            // Naming/navigation clarity: "Family Home" always, never
            // the generic "Home" — this is the family-wide screen, and
            // must read as such at a glance, distinct from Athlete
            // Overview's "<Athlete Name> Home" title.
            .navigationTitle("Family Home")
            .onAppear {
                viewModel.refresh()
            }
            .navigationDestination(for: FamilyHomeDestination.self) { destination in
                switch destination {
                case .athlete(let athleteId):
                    if let athlete = viewModel.activeAthletes.first(where: { $0.athleteId == athleteId }) {
                        athleteOverview(for: athlete)
                    }
                case .activity(let rowId):
                    let plannedRowsToday: [FamilyHomeRow] = viewModel.rows.compactMap {
                        if case .planned(let row) = $0 { return row }
                        return nil
                    }
                    let plannedRowsTomorrow: [FamilyHomeRow] = viewModel.tomorrowRows.compactMap {
                        if case .planned(let row) = $0 { return row }
                        return nil
                    }
                    if let row = (plannedRowsToday + plannedRowsTomorrow).first(where: { $0.id == rowId }) {
                        activityDetail(for: row)
                    }
                case .recurringOccurrence(let id):
                    if case .recurringOccurrence(let athleteId, let athleteName, let suggestion) = (viewModel.rows + viewModel.tomorrowRows).first(where: { $0.id == id }) {
                        RecurringOccurrencePreviewView(
                            suggestion: suggestion,
                            athleteDisplayName: athleteName,
                            planningService: planningService,
                            trainingService: trainingService,
                            trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                            actorId: ActorId(rawValue: family.participant.id),
                            onActivityLogged: { viewModel.refresh() }
                        )
                    }
                case .reflection(let athleteId):
                    ReflectionFormViewLoader(
                        athleteId: athleteId,
                        athleteDisplayName: viewModel.activeAthletes.first(where: { $0.athleteId == athleteId })?.givenName ?? "Athlete",
                        weekStart: TrainingPlanningCoordinationService.weekStart(),
                        authorId: ActorId(rawValue: family.participant.id),
                        weeklyReflectionService: weeklyReflectionService
                    )
                case .familySchedule:
                    FamilyScheduleView(
                        viewModel: FamilyScheduleViewModel(
                            activeAthletes: viewModel.activeAthletes,
                            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                            planningService: planningService
                        ),
                        actorId: ActorId(rawValue: family.participant.id),
                        planningService: planningService,
                        trainingService: trainingService,
                        trainingReflectionCoordinationService: trainingReflectionCoordinationService
                    )
                case .sleepCapture(let athleteId):
                    if let athlete = viewModel.activeAthletes.first(where: { $0.athleteId == athleteId }) {
                        let today = SleepCoordinationService.today()
                        SleepCaptureView(
                            viewModel: SleepCaptureViewModel(
                                sleepCoordinationService: sleepCoordinationService,
                                athleteId: athleteId,
                                athleteDisplayName: athlete.givenName,
                                localDate: today,
                                existingSleepQuality: viewModel.sleepSummaries.first { $0.athleteId == athleteId }?.sleepQuality,
                                today: today
                            ),
                            onSaved: { viewModel.loadSleepSummaries() }
                        )
                    }
                case .sleepHistory(let athleteId):
                    if let athlete = viewModel.activeAthletes.first(where: { $0.athleteId == athleteId }) {
                        let today = SleepCoordinationService.today()
                        SleepHistoryView(
                            viewModel: SleepHistoryViewModel(
                                sleepStatusProvider: sleepCoordinationService,
                                athleteId: athleteId,
                                today: today
                            ),
                            athleteDisplayName: athlete.givenName,
                            today: today,
                            makeCaptureViewModel: { localDate, existingSleepQuality in
                                SleepCaptureViewModel(
                                    sleepCoordinationService: sleepCoordinationService,
                                    athleteId: athleteId,
                                    athleteDisplayName: athlete.givenName,
                                    localDate: localDate,
                                    existingSleepQuality: existingSleepQuality,
                                    today: today
                                )
                            }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tomorrowSection: some View {
        if !viewModel.tomorrowRows.isEmpty {
            Section("Tomorrow") {
                ForEach(viewModel.tomorrowRows) { row in
                    todayActivityRow(row)
                }
            }
            .accessibilityIdentifier("familyHome.tomorrowList")
        }
    }

    /// Sprint 1.2B: renders any of the three `TodayActivityRow` cases.
    /// `.planned` reuses the same navigation `familyHomeRow` already
    /// established. `.recurringOccurrence` routes to the existing
    /// `RecurringOccurrencePreviewView` (via `.recurringOccurrence`),
    /// never fabricating a `PlannedActivityId`. `.unplannedLogged` has
    /// no existing detail view for a bare `LoggedActivity` with no
    /// plan — shown as a plain, non-navigable row (Part 3's "subtle
    /// existing-style indication", not a new detail screen this
    /// package wasn't asked to build).
    @ViewBuilder
    private var nowNextSection: some View {
        switch viewModel.nowNextState {
        case .now(let items):
            Section("Now") {
                ForEach(items) { todayActivityRow($0) }
            }
            .accessibilityIdentifier("familyHome.nowNext.now")
        case .next(let items):
            Section("Next") {
                ForEach(items) { todayActivityRow($0) }
            }
            .accessibilityIdentifier("familyHome.nowNext.next")
        case .empty:
            // Calm by Default: no placeholder text, no "nothing
            // scheduled" filler — genuine absence of relevant activity
            // simply shows nothing here at all.
            EmptyView()
        }
    }

    @ViewBuilder
    private func todayActivityRow(_ row: TodayActivityRow) -> some View {
        switch row {
        case .planned(let familyHomeRowValue):
            familyHomeRow(familyHomeRowValue)
        case .recurringOccurrence(let athleteId, let athleteName, let suggestion):
            VStack(alignment: .leading, spacing: 4) {
                NavigationLink(value: FamilyHomeDestination.athlete(athleteId)) {
                    Text(athleteName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("familyHome.athleteLink.\(athleteId.rawValue.uuidString)")

                NavigationLink(value: FamilyHomeDestination.recurringOccurrence(id: suggestion.id)) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(suggestion.title)
                            Text(Self.recurringRowSubtitle(for: suggestion))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Recurring")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("familyHome.recurringRow.\(suggestion.id)")
            }
        case .unplannedLogged(let athleteId, let athleteName, let loggedActivity):
            VStack(alignment: .leading, spacing: 4) {
                Text(athleteName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("familyHome.athleteLabel.\(athleteId.rawValue.uuidString)")
                HStack {
                    VStack(alignment: .leading) {
                        Text(loggedActivity.title)
                        Text("Unplanned · Logged")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .accessibilityIdentifier("familyHome.unplannedLoggedRow.\(loggedActivity.id.uuidString)")
        }
    }

    private static func recurringRowSubtitle(for suggestion: RecurringActivitySuggestion) -> String {
        var parts: [String] = []
        if let startTime = suggestion.startLocalTime {
            parts.append(String(format: "%02d:%02d", startTime.hour, startTime.minute))
        }
        if let location = suggestion.location, !location.isEmpty {
            parts.append(location)
        }
        return parts.joined(separator: " · ")
    }

    private func familyHomeRow(_ row: FamilyHomeRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            NavigationLink(value: FamilyHomeDestination.athlete(row.athleteId)) {
                Text(row.athleteName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("familyHome.athleteLink.\(row.athleteId.rawValue.uuidString)")

            NavigationLink(value: FamilyHomeDestination.activity(rowId: row.id)) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.plannedActivity.title)
                        Text(Self.rowSubtitle(for: row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        // Activity outcome consistency closeout (item B):
                        // the real outcome, not a blanket "Completed" for
                        // any resolved status — a Cancelled or Missed
                        // activity must never show as Completed here.
                        // Hidden entirely when unresolved (`outcomeStatus == nil`),
                        // matching this row's prior behavior for that
                        // case exactly — `rowSubtitle` below already
                        // conveys "Ready to log" there.
                        if let outcomeStatus = row.outcomeStatus {
                            Text(TrainingStrings.outcomeLabel(for: outcomeStatus))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if row.isFromRecurring {
                            Text("Recurring")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier("familyHome.activityRow.\(row.id)")
        }
    }

    /// Sprint 1 completion package, Item 5: location is now included
    /// where available — the field genuinely didn't exist when this
    /// comment previously said so.
    private static func rowSubtitle(for row: FamilyHomeRow) -> String {
        var parts: [String] = []
        // Activity outcome consistency closeout (item B): the planned
        // duration summary is only meaningful for a GENUINELY completed
        // outcome — showing "30 min" next to a Cancelled/Missed activity
        // (even though 30 is the plan's own value, never the placeholder)
        // would still read as if training happened. Same root cause as
        // the trailing label above, in this same function.
        switch row.outcomeStatus {
        case .completed, .partiallyCompleted:
            if let duration = row.plannedActivity.plannedDurationMinutes {
                parts.append("\(duration) min")
            }
            parts.append(row.plannedActivity.localDate.isoString)
        case .missed, .cancelled:
            parts.append(row.plannedActivity.localDate.isoString)
        case .none, .scheduled:
            if let startTime = row.plannedActivity.startLocalTime {
                parts.append(String(format: "%02d:%02d", startTime.hour, startTime.minute))
            } else {
                parts.append("Ready to log")
            }
        }
        if let location = row.plannedActivity.location, !location.isEmpty {
            parts.append(location)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var reflectionNavigationSection: some View {
        // Reduced from a full, headline "Reflection" section (one row
        // per athlete) to the minimum discoverable navigation: no
        // section header, footer text only — visually secondary, not a
        // permanent Reflection dashboard. Focus this week (below)
        // remains the actual Home content; this is only a discreet
        // route to it when useful. Per-athlete links are kept, not
        // collapsed into one, since navigating to a specific athlete's
        // reflection requires real, explicit athlete identity — no
        // "first athlete" shortcut. Access itself isn't removed merely
        // because Training also exposes it elsewhere.
        if !viewModel.activeAthletes.isEmpty {
            Section {
                ForEach(viewModel.activeAthletes, id: \.athleteId) { athlete in
                    NavigationLink(athlete.givenName, value: FamilyHomeDestination.reflection(athlete.athleteId))
                        .font(.footnote)
                        .accessibilityIdentifier("familyHome.reflectionLink.\(athlete.athleteId.rawValue.uuidString)")
                }
            } footer: {
                Text("Reflect on this week")
            }
            .accessibilityIdentifier("familyHome.reflectionNavigation")
        }
    }

    @ViewBuilder
    private var focusThisWeekSection: some View {
        // Parent Home UX / Content Contract: shows nothing at all when
        // no athlete has a relevant prior-week focus — no placeholder,
        // no "no focus entered" text, matching the approved "absence"
        // rule exactly. The prior reflection remains the sole source
        // of truth; this section never persists anything of its own.
        if !viewModel.focusThisWeek.isEmpty {
            Section("Focus this week") {
                ForEach(viewModel.focusThisWeek) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.athleteName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.focus)
                    }
                    .accessibilityIdentifier("familyHome.focusThisWeekRow.\(item.id)")
                }
            }
            .accessibilityIdentifier("familyHome.focusThisWeek")
        }
    }

    /// VX-023 (Sleep V1) UX polish (TestFlight-verified, presentation
    /// only): Family Home Sleep is primarily a MONITORING surface, not
    /// a second place to record Sleep — recording stays on Athlete Home.
    /// Recorded -> athlete name, "x/5", and "History" as a secondary
    /// action pinned to the trailing edge via `Spacer()` (no fixed
    /// widths, so this reflows normally under Dynamic Type). Missing ->
    /// athlete name and a single-line "Not logged yet" status only — no
    /// "Log Sleep" action here at all (that read as a second entry
    /// point competing with Athlete Home) and no "History" link for a
    /// day with nothing recorded yet. An athlete with tracking OFF
    /// simply never appears in `viewModel.sleepSummaries` (see
    /// `FamilyHomeViewModel.loadSleepSummaries()`'s own doc comment), so
    /// no per-athlete "disabled" branch is needed here — absence from
    /// the list already means absence from this section.
    @ViewBuilder
    private var sleepSection: some View {
        if !viewModel.sleepSummaries.isEmpty {
            Section("Sleep") {
                ForEach(viewModel.sleepSummaries) { summary in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.athleteName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let sleepQuality = summary.sleepQuality {
                            HStack {
                                Text("\(sleepQuality)/5")
                                Spacer()
                                NavigationLink("History", value: FamilyHomeDestination.sleepHistory(summary.athleteId))
                                    .accessibilityIdentifier("familyHome.sleep.historyLink.\(summary.athleteId.rawValue.uuidString)")
                            }
                        } else {
                            Text("Not logged yet")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("familyHome.sleep.row.\(summary.athleteId.rawValue.uuidString)")
                }
            }
            .accessibilityIdentifier("familyHome.sleepSection")
        }
    }

    private func athleteOverview(for athlete: AthleteProfile) -> some View {
        HomeDashboardView(
            viewModel: homeDashboardViewModelCache.viewModel(for: athlete.athleteId) {
                HomeDashboardViewModel(
                    trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                    coachingPresentationProvider: coachingApplicationService,
                    athleteId: athlete.athleteId,
                    athleteDisplayName: athlete.givenName,
                    weekStart: WeeklyPlanningViewModel.currentWeekStart(),
                    todayActivityComposer: TodayActivityComposer(
                        planningService: planningService,
                        trainingService: trainingService,
                        trainingPlanningCoordinationService: trainingPlanningCoordinationService
                    ),
                    activityChangeBroadcaster: activityChangeBroadcaster,
                    sleepStatusProvider: sleepCoordinationService,
                    sleepChangeBroadcaster: sleepChangeBroadcaster
                )
            },
            athleteDisplayName: athlete.givenName,
            planningService: planningService,
            trainingService: trainingService,
            trainingReflectionCoordinationService: trainingReflectionCoordinationService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReviewCoordinationService: weeklyReviewCoordinationService,
            weeklyReflectionService: weeklyReflectionService,
            coachingApplicationService: coachingApplicationService,
            athleteId: athlete.athleteId,
            committedByActorId: ActorId(rawValue: family.participant.id),
            athleteManagementViewModel: athleteManagementViewModel,
            activityChangeBroadcaster: activityChangeBroadcaster,
            sleepCoordinationService: sleepCoordinationService,
            sleepChangeBroadcaster: sleepChangeBroadcaster
        )
    }

    private func activityDetail(for row: FamilyHomeRow) -> some View {
        ActivityDetailViewLoader(
            plannedActivity: row.plannedActivity,
            athleteId: row.athleteId,
            athleteDisplayName: row.athleteName,
            actorId: ActorId(rawValue: family.participant.id),
            planningService: planningService,
            trainingReflectionCoordinationService: trainingReflectionCoordinationService,
            onActivityLogged: { viewModel.refresh() }
        )
    }
}
