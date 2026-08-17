import SwiftUI
import VoxtrCoreContracts
import VoxtrCoachingDomain
import VoxtrMotivationDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Sprint 12: the application's first Home Dashboard — the primary
/// entry point after onboarding. Deliberately minimal: native SwiftUI
/// components only, no custom styling system, no decoration. This
/// sprint establishes the architecture (ViewModel → existing
/// application services → domain), not a finished dashboard
/// experience.
///
/// Sprint 15: reordered to Welcome → Daily Quote → Daily Focus →
/// existing cards, per that sprint's explicit recommended order.
/// `DailyQuoteView()` is self-contained — it owns its own
/// `DailyQuoteViewModel` (default-constructed, no dependency threaded
/// through `FamilyHomeView`/`RootView`/`CompositionRoot` needed) since
/// Daily Quote has no overlap with anything `HomeDashboardViewModel`
/// already loads. Coaching logic and Daily Focus are unmodified by
/// this sprint — only their position in this list changed.
///
/// Every section here reuses an already-existing destination or
/// service — `WeeklyPlanningView`/`DailyTrainingView`/`WeeklyReviewView`
/// are exactly the same screens `FamilyHomeView` already linked to,
/// constructed the same way. This view adds no new navigation
/// destinations, only a new place to reach the existing ones from,
/// plus two small summaries (today's training, coaching) built purely
/// from what `HomeDashboardViewModel` already loaded.
public struct HomeDashboardView: View {
    @State private var viewModel: HomeDashboardViewModel
    private let athleteDisplayName: String
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    private let weeklyReflectionService: WeeklyReflectionService
    private let coachingApplicationService: CoachingApplicationService
    private let athleteId: AthleteId
    private let committedByActorId: ActorId
    private let athleteManagementViewModel: AthleteFamilyManagementViewModel
    @State private var isManagingAthletes: Bool = false

    public init(
        viewModel: HomeDashboardViewModel,
        athleteDisplayName: String,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteId: AthleteId,
        committedByActorId: ActorId,
        athleteManagementViewModel: AthleteFamilyManagementViewModel
    ) {
        _viewModel = State(initialValue: viewModel)
        self.athleteDisplayName = athleteDisplayName
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteId = athleteId
        self.committedByActorId = committedByActorId
        self.athleteManagementViewModel = athleteManagementViewModel
    }

    public var body: some View {
        Form {
            welcomeSection
            trainingSection
            DailyQuoteView()
            coachingSection
            planningSection
            reflectionSection
        }
        .navigationTitle("\(athleteDisplayName) Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Manage Athletes") {
                    isManagingAthletes = true
                }
                .accessibilityIdentifier("home.manageAthletesButton")
            }
        }
        .sheet(isPresented: $isManagingAthletes) {
            NavigationStack {
                AthleteFamilyManagementView(
                    viewModel: athleteManagementViewModel,
                    athleteHomeDestination: { athlete in
                        AnyView(HomeDashboardView(
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
                            committedByActorId: committedByActorId,
                            athleteManagementViewModel: athleteManagementViewModel
                        ))
                    }
                )
            }
        }
        .onAppear {
            viewModel.loadTodaysTraining()
            viewModel.loadTodayActivityRows()
            viewModel.loadCoachingSummary()
        }
    }

    /// Sprint 1.1, P2: the `dailyFocusCard` UI section that used to live
    /// here (`DailyFocusCardView`) was removed — it duplicated
    /// `trainingSection`'s own "Strength — Not yet logged" content with
    /// no additional information, exactly the redundancy this work
    /// package identified. Removed the VIEW only:
    /// `HomeDashboardViewModel.dailyFocusState`,
    /// `loadCoachingSummary()`, and `DailyFocusComposer` are all
    /// untouched — no domain concept or persistence was deleted, and
    /// nothing was invented to replace this section, per this work
    /// package's own explicit constraint. A future, genuinely
    /// contextual Daily Focus (reflection/load/recommendation-based) is
    /// out of scope here.

    private var welcomeSection: some View {
        Section {
            Text(athleteDisplayName)
                .accessibilityIdentifier("homeDashboard.athleteName")
            Text(viewModel.weekStart.isoString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("homeDashboard.weekStart")
        }
    }

    /// A summary, not the entire Weekly Review — shows only the
    /// highest-priority section. "Highest-priority" here means
    /// `sections.first`: `CoachingPresentation.sections` is already in
    /// a fixed, deterministic order (Planned Activities → Weekly
    /// Reflection → Parent Observations — see
    /// `CoachingPresentationMapper`), and that existing order is reused
    /// as the priority signal rather than this view inventing a new
    /// ranking. No new coaching logic is introduced here — the section
    /// is simply reused, not recomputed or reinterpreted.
    @ViewBuilder
    private var coachingSection: some View {
        switch viewModel.coachingSummaryState {
        case .loading:
            EmptyView()
        case .failed:
            Section("Coaching") {
                Text(CoachingPresentationStrings.unavailable)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("homeDashboard.coaching.unavailable")
            }
        case .loaded(let presentation):
            if let topSection = presentation.sections.first {
                Section("Coaching") {
                    NavigationLink {
                        WeeklyReviewView(
                            viewModel: WeeklyReviewViewModel(
                                coordinationService: weeklyReviewCoordinationService,
                                coachingPresentationProvider: coachingApplicationService,
                                athleteId: athleteId,
                                weekStart: viewModel.weekStart
                            ),
                            athleteDisplayName: athleteDisplayName,
                            reflectionService: weeklyReflectionService,
                            authorId: committedByActorId
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(topSection.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ForEach(topSection.items, id: \.insight) { item in
                                Text(item.text)
                            }
                        }
                    }
                    .accessibilityIdentifier("homeDashboard.coaching.summary")
                }
            }
            // An empty presentation (no findings) renders nothing here
            // — no invented "everything looks good" message, matching
            // the same rule `WeeklyReviewView`'s own coaching section
            // already follows.
        }
    }

    private var planningSection: some View {
        Section("Planning") {
            NavigationLink("Weekly Plan") {
                WeeklyPlanningView(
                    viewModel: WeeklyPlanningViewModel(
                        service: planningService,
                        athleteId: athleteId,
                        committedByActorId: committedByActorId
                    ),
                    athleteDisplayName: athleteDisplayName,
                    planningService: planningService,
                    trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                    actorId: committedByActorId
                )
            }
            .accessibilityIdentifier("homeDashboard.weeklyPlanLink")
        }
    }

    /// Shows today's planned activities (with completion state already
    /// derived by `TrainingPlanningCoordinationService`, never
    /// recomputed here) alongside the shortcut to the full Daily
    /// Training screen.
    @ViewBuilder
    private func todayActivityRow(_ row: TodayActivityRow) -> some View {
        switch row {
        case .planned(let familyHomeRow):
            NavigationLink {
                ActivityDetailViewLoader(
                    plannedActivity: familyHomeRow.plannedActivity,
                    athleteId: athleteId,
                    athleteDisplayName: athleteDisplayName,
                    actorId: committedByActorId,
                    planningService: planningService,
                    trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                    onActivityLogged: {
                        viewModel.loadTodaysTraining()
                        viewModel.loadTodayActivityRows()
                    }
                )
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(familyHomeRow.plannedActivity.title)
                        if let location = familyHomeRow.plannedActivity.location, !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        // Activity outcome consistency closeout (item B):
                        // the real outcome — a Cancelled or Missed
                        // activity must never show as Completed here,
                        // the same fix already applied to Family Home's
                        // equivalent row label.
                        Text(TrainingStrings.outcomeLabel(for: familyHomeRow.outcomeStatus))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if familyHomeRow.isFromRecurring {
                            Text("Recurring")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier("homeDashboard.todaysTraining.row.\(familyHomeRow.id)")
        case .recurringOccurrence(_, _, let suggestion):
            NavigationLink {
                RecurringOccurrencePreviewView(
                    suggestion: suggestion,
                    athleteDisplayName: athleteDisplayName,
                    planningService: planningService,
                    trainingService: trainingService,
                    trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                    actorId: committedByActorId,
                    onActivityLogged: {
                        viewModel.loadTodaysTraining()
                        viewModel.loadTodayActivityRows()
                    }
                )
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(suggestion.title)
                        if let location = suggestion.location, !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("Recurring")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("homeDashboard.todaysTraining.recurringRow.\(suggestion.id)")
        case .unplannedLogged(_, _, let loggedActivity):
            HStack {
                VStack(alignment: .leading) {
                    Text(loggedActivity.title)
                    Text("Unplanned · Logged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityIdentifier("homeDashboard.todaysTraining.unplannedLoggedRow.\(loggedActivity.id.uuidString)")
        }
    }

    private var trainingSection: some View {
        Section("Training") {
            switch viewModel.todayActivityState {
            case .loading:
                EmptyView()
            case .failed:
                Text(CoachingPresentationStrings.unavailable)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("homeDashboard.todaysTraining.unavailable")
            case .loaded(let rows):
                if !rows.isEmpty {
                    ForEach(rows) { row in
                        todayActivityRow(row)
                    }
                }
            }

            NavigationLink("Daily Training") {
                DailyTrainingView(
                    viewModel: DailyTrainingViewModel(
                        trainingService: trainingService,
                        coordinationService: trainingPlanningCoordinationService,
                        trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                        authorId: committedByActorId,
                        athleteId: athleteId,
                        athleteDisplayName: athleteDisplayName,
                        todayActivityComposer: TodayActivityComposer(
                            planningService: planningService,
                            trainingService: trainingService,
                            trainingPlanningCoordinationService: trainingPlanningCoordinationService
                        )
                    ),
                    planningService: planningService,
                    trainingService: trainingService,
                    trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                    actorId: committedByActorId,
                    athleteDisplayName: athleteDisplayName
                )
            }
            .accessibilityIdentifier("homeDashboard.dailyTrainingLink")
        }
    }

    private var reflectionSection: some View {
        Section("Reflection") {
            NavigationLink("Add Reflection") {
                ReflectionFormViewLoader(
                    athleteId: athleteId,
                    athleteDisplayName: athleteDisplayName,
                    weekStart: viewModel.weekStart,
                    authorId: committedByActorId,
                    weeklyReflectionService: weeklyReflectionService
                )
            }
            .accessibilityIdentifier("homeDashboard.addReflectionLink")

            NavigationLink("Weekly Review") {
                WeeklyReviewView(
                    viewModel: WeeklyReviewViewModel(
                        coordinationService: weeklyReviewCoordinationService,
                        coachingPresentationProvider: coachingApplicationService,
                        athleteId: athleteId,
                        weekStart: viewModel.weekStart
                    ),
                    athleteDisplayName: athleteDisplayName,
                    reflectionService: weeklyReflectionService,
                    authorId: committedByActorId
                )
            }
            .accessibilityIdentifier("homeDashboard.weeklyReviewLink")
        }
    }
}
