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
    private let family: RestoredFamily
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    private let weeklyReflectionService: WeeklyReflectionService
    private let coachingApplicationService: CoachingApplicationService
    private let athleteManagementViewModel: AthleteFamilyManagementViewModel

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
        athleteManagementViewModel: AthleteFamilyManagementViewModel
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
        _viewModel = State(initialValue: FamilyHomeViewModel(
            activeAthletes: family.activeAthletes,
            workspaceId: WorkspaceId(rawValue: family.workspace.id),
            athleteRepository: athleteRepository,
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
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
                        if row.isCompleted {
                            Text("Completed")
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
        if row.isCompleted {
            if let duration = row.plannedActivity.plannedDurationMinutes {
                parts.append("\(duration) min")
            }
            parts.append(row.plannedActivity.localDate.isoString)
        } else if let startTime = row.plannedActivity.startLocalTime {
            parts.append(String(format: "%02d:%02d", startTime.hour, startTime.minute))
        } else {
            parts.append("Ready to log")
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

    private func athleteOverview(for athlete: AthleteProfile) -> some View {
        HomeDashboardView(
            viewModel: HomeDashboardViewModel(
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                coachingPresentationProvider: coachingApplicationService,
                athleteId: athlete.athleteId,
                athleteDisplayName: athlete.givenName,
                weekStart: WeeklyPlanningViewModel.currentWeekStart(),
                todayActivityComposer: TodayActivityComposer(
                    planningService: planningService,
                    trainingService: trainingService,
                    trainingPlanningCoordinationService: trainingPlanningCoordinationService
                )
            ),
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
            athleteManagementViewModel: athleteManagementViewModel
        )
    }

    private func activityDetail(for row: FamilyHomeRow) -> some View {
        ActivityDetailViewLoader(
            plannedActivity: row.plannedActivity,
            isCompleted: row.isCompleted,
            athleteId: row.athleteId,
            athleteDisplayName: row.athleteName,
            actorId: ActorId(rawValue: family.participant.id),
            planningService: planningService,
            trainingReflectionCoordinationService: trainingReflectionCoordinationService,
            onActivityLogged: { viewModel.refresh() }
        )
    }
}
