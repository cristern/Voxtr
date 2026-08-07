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
            dailyFocusCard
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
                                weekStart: WeeklyPlanningViewModel.currentWeekStart()
                            ),
                            athleteDisplayName: athlete.givenName,
                            planningService: planningService,
                            trainingService: trainingService,
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
            viewModel.loadCoachingSummary()
        }
    }

    /// Sprint 13 (architecture correction): passes
    /// `viewModel.dailyFocusState` — a value already fully derived by
    /// `HomeDashboardViewModel` from `todaysTrainingState`/
    /// `coachingSummaryState` — directly to `DailyFocusCardView`. No
    /// `DailyFocusViewModel` is constructed here anymore (that type no
    /// longer exists); no third loading call is triggered anywhere in
    /// this file. `HomeDashboardViewModel`'s own `loadTodaysTraining()`/
    /// `loadCoachingSummary()` calls below are still the only two
    /// loading entry points this screen has ever had.
    private var dailyFocusCard: some View {
        DailyFocusCardView(
            dailyFocusState: viewModel.dailyFocusState,
            athleteDisplayName: athleteDisplayName,
            weeklyReviewCoordinationService: weeklyReviewCoordinationService,
            weeklyReflectionService: weeklyReflectionService,
            coachingApplicationService: coachingApplicationService,
            athleteId: athleteId,
            weekStart: viewModel.weekStart,
            committedByActorId: committedByActorId
        )
    }

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
                    )
                )
            }
            .accessibilityIdentifier("homeDashboard.weeklyPlanLink")
        }
    }

    /// Shows today's planned activities (with completion state already
    /// derived by `TrainingPlanningCoordinationService`, never
    /// recomputed here) alongside the shortcut to the full Daily
    /// Training screen.
    private var trainingSection: some View {
        Section("Training") {
            switch viewModel.todaysTrainingState {
            case .loading:
                EmptyView()
            case .failed:
                Text(CoachingPresentationStrings.unavailable)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("homeDashboard.todaysTraining.unavailable")
            case .loaded(let activities):
                if !activities.isEmpty {
                    ForEach(activities, id: \.plannedActivity.id) { item in
                        NavigationLink {
                            ActivityDetailViewLoader(
                                plannedActivity: item.plannedActivity,
                                isCompleted: item.isCompleted,
                                athleteId: athleteId,
                                actorId: committedByActorId,
                                planningService: planningService,
                                trainingService: trainingService
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.plannedActivity.title)
                                    if let location = item.plannedActivity.location, !location.isEmpty {
                                        Text(location)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(item.isCompleted ? TrainingStrings.completedLabel : TrainingStrings.notCompletedLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("homeDashboard.todaysTraining.row.\(item.plannedActivity.id.uuidString)")
                    }
                }
            }

            NavigationLink("Daily Training") {
                DailyTrainingView(
                    viewModel: DailyTrainingViewModel(
                        trainingService: trainingService,
                        coordinationService: trainingPlanningCoordinationService,
                        athleteId: athleteId
                    ),
                    planningService: planningService,
                    trainingService: trainingService,
                    actorId: committedByActorId
                )
            }
            .accessibilityIdentifier("homeDashboard.dailyTrainingLink")
        }
    }

    private var reflectionSection: some View {
        Section("Reflection") {
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
