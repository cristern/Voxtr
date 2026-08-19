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
    // Family Home athlete navigation round: `.reflection(AthleteId)` is
    // removed — its only trigger was `reflectionNavigationSection`'s
    // per-athlete "Add Reflection" shortcut, replaced by `athletesSection`
    // below (see that property's own doc comment for why). Athlete-level
    // Reflection itself is untouched and remains fully reachable via
    // `HomeDashboardView.reflectionSection`'s own "Add Reflection"/
    // "Weekly Review" links, reached through THIS destination's own
    // `.athlete(AthleteId)` case — nothing about Reflection became
    // unreachable, only this one redundant Family-Home-level shortcut.
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
                    .voxtrRowSurface()
                }

                nowNextSection

                Section {
                    if viewModel.rows.isEmpty {
                        Text("Nothing planned for today.")
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                    } else {
                        ForEach(viewModel.rows) { row in
                            todayActivityRow(row)
                        }
                    }
                } header: {
                    VoxtrSectionHeading("Today's Schedule")
                }
                .voxtrRowSurface()
                .accessibilityIdentifier("familyHome.scheduleList")

                tomorrowSection

                Section {
                    NavigationLink("View upcoming schedule", value: FamilyHomeDestination.familySchedule)
                        .accessibilityIdentifier("familyHome.familyScheduleLink")
                }
                .voxtrRowSurface()

                focusThisWeekSection
                sleepSection
                athletesSection
            }
            // Design Foundation V0.1: the screen background token —
            // structure/navigation/rows below are all unchanged, only
            // the colour underneath changes. See `voxtrScreenBackground()`'s
            // own doc comment.
            .voxtrScreenBackground()
            .tint(VoxtrColor.accent)
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
            Section {
                ForEach(viewModel.tomorrowRows) { row in
                    todayActivityRow(row)
                }
            } header: {
                VoxtrSectionHeading("Tomorrow")
            }
            .voxtrRowSurface()
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
            Section {
                ForEach(items) { todayActivityRow($0) }
            } header: {
                VoxtrSectionHeading("Now")
            }
            .voxtrRowSurface()
            .accessibilityIdentifier("familyHome.nowNext.now")
        case .next(let items):
            Section {
                ForEach(items) { todayActivityRow($0) }
            } header: {
                VoxtrSectionHeading("Next")
            }
            .voxtrRowSurface()
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
                    HStack(spacing: 6) {
                        athleteColorMarker(athleteId)
                        Text(athleteName)
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("familyHome.athleteLink.\(athleteId.rawValue.uuidString)")

                NavigationLink(value: FamilyHomeDestination.recurringOccurrence(id: suggestion.id)) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(suggestion.title)
                                .font(VoxtrTypography.cardTitle)
                                .foregroundStyle(VoxtrColor.textPrimary)
                            Text(Self.recurringRowSubtitle(for: suggestion))
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                        }
                        Spacer()
                        Text("Recurring")
                            .font(VoxtrTypography.caption)
                            .foregroundStyle(VoxtrColor.textSecondary)
                    }
                }
                .accessibilityIdentifier("familyHome.recurringRow.\(suggestion.id)")
            }
        case .unplannedLogged(let athleteId, let athleteName, let loggedActivity):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    athleteColorMarker(athleteId)
                    Text(athleteName)
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                }
                .accessibilityIdentifier("familyHome.athleteLabel.\(athleteId.rawValue.uuidString)")
                HStack {
                    VStack(alignment: .leading) {
                        Text(loggedActivity.title)
                            .font(VoxtrTypography.cardTitle)
                            .foregroundStyle(VoxtrColor.textPrimary)
                        Text("Unplanned · Logged")
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
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
                HStack(spacing: 6) {
                    athleteColorMarker(row.athleteId)
                    Text(row.athleteName)
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("familyHome.athleteLink.\(row.athleteId.rawValue.uuidString)")

            NavigationLink(value: FamilyHomeDestination.activity(rowId: row.id)) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.plannedActivity.title)
                            .font(VoxtrTypography.cardTitle)
                            .foregroundStyle(VoxtrColor.textPrimary)
                        Text(Self.rowSubtitle(for: row))
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
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
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                        }
                        if row.isFromRecurring {
                            Text("Recurring")
                                .font(VoxtrTypography.caption)
                                .foregroundStyle(VoxtrColor.textSecondary)
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

    /// Family Home athlete navigation round: replaces the former
    /// `reflectionNavigationSection` — a permanent, footer-only
    /// per-athlete "Add Reflection" shortcut — in the exact same slot
    /// at the bottom of the Form. Approved product gap this closes:
    /// Athlete Home must remain reachable even on a day an athlete has
    /// no activity (nothing in `nowNextSection`/"Today's Schedule"/
    /// Tomorrow depends on activity existing), so a permanent,
    /// activity-independent path to every active athlete's Home is
    /// needed regardless of what else is on the page.
    ///
    /// Reused, not invented: `viewModel.activeAthletes` is the same
    /// canonical, refreshed-on-appear list every other section in this
    /// file already reads from (see this type's own top-level doc
    /// comment — never `family.activeAthletes`, which goes stale).
    /// `FamilyHomeDestination.athlete(AthleteId)` is the SAME existing
    /// destination `nowNextSection`/`familyHomeRow`'s own small
    /// athlete-name links already push, resolved by the SAME existing
    /// `athleteOverview(for:)` below — no new destination, no new
    /// Athlete Home construction path.
    ///
    /// This is experience navigation only, matching the approved
    /// ownership distinction: Family Home → Athletes enters each
    /// athlete's Home/experience; Profile → Manage Athletes remains the
    /// separate people/configuration surface (`AthleteFamilyManagementView`,
    /// untouched by this round) — this section never routes to Athlete
    /// Settings and carries no edit/configuration action.
    ///
    /// Deliberately minimal for this first version: athlete name,
    /// standard `NavigationLink` chevron, and a small Athlete Color
    /// identity marker (a filled circle, never a card fill). No
    /// activity summary, readiness/status, Sleep value, ranking, or
    /// badge; still nothing beyond identity.
    ///
    /// Design Foundation V0.1 correction round: the marker colour now
    /// comes from `VoxtrAthleteColor.forAthleteId(_:)` — derived
    /// entirely from the athlete's own stable `AthleteId`, never this
    /// list's position — see that method's own doc comment for why
    /// (the previous, rejected version used list index, which could
    /// silently change an athlete's own colour whenever the roster
    /// changed elsewhere). `ForEach`'s identity (`id: \.athleteId`) was
    /// always independent of colour and remains unchanged.
    @ViewBuilder
    private var athletesSection: some View {
        if !viewModel.activeAthletes.isEmpty {
            Section {
                ForEach(viewModel.activeAthletes, id: \.athleteId) { athlete in
                    NavigationLink(value: FamilyHomeDestination.athlete(athlete.athleteId)) {
                        HStack(spacing: 8) {
                            athleteColorMarker(athlete.athleteId)
                            Text(athlete.givenName)
                                .font(VoxtrTypography.cardTitle)
                                .foregroundStyle(VoxtrColor.textPrimary)
                        }
                    }
                    .accessibilityIdentifier("familyHome.athletesSection.row.\(athlete.athleteId.rawValue.uuidString)")
                }
            } header: {
                VoxtrSectionHeading("Athletes")
            }
            .voxtrRowSurface()
            .accessibilityIdentifier("familyHome.athletesSection")
        }
    }

    /// Design Foundation V0.1 correction round: the ONE small colour
    /// marker every athlete-specific row on this shared, multi-athlete
    /// screen now prepends before the athlete's own name — Now/Next and
    /// Today's Schedule/Tomorrow's activity rows, Sleep rows, Focus
    /// this week rows, and the Athletes section itself. Applied only to
    /// rows that are genuinely athlete-specific (never the "View
    /// upcoming schedule" link, an error message, or a section
    /// heading). Identity only, per `VoxtrAthleteColor`'s own doc
    /// comment: never a fill behind text, never implying performance/
    /// readiness/warning/completion/ranking. Every call site keeps its
    /// own existing athlete-name `Text` exactly as it already was —
    /// this only adds the marker glyph beside it.
    private func athleteColorMarker(_ athleteId: AthleteId) -> some View {
        Circle()
            .fill(VoxtrAthleteColor.forAthleteId(athleteId).color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var focusThisWeekSection: some View {
        // Parent Home UX / Content Contract: shows nothing at all when
        // no athlete has a relevant prior-week focus — no placeholder,
        // no "no focus entered" text, matching the approved "absence"
        // rule exactly. The prior reflection remains the sole source
        // of truth; this section never persists anything of its own.
        if !viewModel.focusThisWeek.isEmpty {
            Section {
                ForEach(viewModel.focusThisWeek) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            athleteColorMarker(item.athleteId)
                            Text(item.athleteName)
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                        }
                        Text(item.focus)
                            .font(VoxtrTypography.body)
                            .foregroundStyle(VoxtrColor.textPrimary)
                    }
                    .accessibilityIdentifier("familyHome.focusThisWeekRow.\(item.id)")
                }
            } header: {
                VoxtrSectionHeading("Focus this week")
            }
            .voxtrRowSurface()
            .accessibilityIdentifier("familyHome.focusThisWeek")
        }
    }

    /// VX-023 (Sleep V1) UX polish, round 2: Family Home Sleep is
    /// primarily a MONITORING surface, not a second place to record
    /// Sleep — recording stays on Athlete Home, so there is still no
    /// "Log Sleep" action here. An athlete with tracking OFF simply
    /// never appears in `viewModel.sleepSummaries` (see
    /// `FamilyHomeViewModel.loadSleepSummaries()`'s own doc comment), so
    /// no per-athlete "disabled" branch is needed here — absence from
    /// the list already means absence from this section.
    ///
    /// Round 4 (TestFlight): two prior rounds tried to lay out a
    /// visible trailing "History" label next to the status text and
    /// never got it to sit at the true trailing edge cleanly. Approved
    /// correction removes that visible label entirely — the row/status
    /// itself IS the navigation affordance, exactly like this file's
    /// own `familyHomeRow` below already does for its own rows (whole
    /// row wrapped as one `NavigationLink(value:)`'s label). This also
    /// retires the entire alignment problem rather than re-fixing it:
    /// with no second interactive element competing for trailing space,
    /// there is nothing left to misalign. Same destination as before —
    /// `FamilyHomeDestination.sleepHistory(_:)`, the same canonical
    /// Sleep History `SleepHistoryView` Athlete Home already uses, no
    /// new destination.
    @ViewBuilder
    private var sleepSection: some View {
        if !viewModel.sleepSummaries.isEmpty {
            Section {
                ForEach(viewModel.sleepSummaries) { summary in
                    NavigationLink(value: FamilyHomeDestination.sleepHistory(summary.athleteId)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                athleteColorMarker(summary.athleteId)
                                Text(summary.athleteName)
                                    .font(VoxtrTypography.metadata)
                                    .foregroundStyle(VoxtrColor.textSecondary)
                            }
                            if let sleepQuality = summary.sleepQuality {
                                Text("\(sleepQuality)/5")
                                    .font(VoxtrTypography.value)
                                    .foregroundStyle(VoxtrColor.textPrimary)
                            } else {
                                Text("Not logged yet")
                                    .font(VoxtrTypography.value)
                                    .foregroundStyle(VoxtrColor.textSecondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("familyHome.sleep.row.\(summary.athleteId.rawValue.uuidString)")
                }
            } header: {
                VoxtrSectionHeading("Sleep")
            }
            .voxtrRowSurface()
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
