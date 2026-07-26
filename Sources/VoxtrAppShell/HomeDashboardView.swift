import SwiftUI
import VoxtrCoreContracts
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
        committedByActorId: ActorId
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
    }

    public var body: some View {
        NavigationStack {
            Form {
                welcomeSection
                coachingSection
                planningSection
                trainingSection
                reflectionSection
            }
            .navigationTitle("Home")
            .onAppear {
                viewModel.loadTodaysTraining()
                viewModel.loadCoachingSummary()
            }
        }
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
                        HStack {
                            Text(item.plannedActivity.title)
                            Spacer()
                            Text(item.isCompleted ? TrainingStrings.completedLabel : TrainingStrings.notCompletedLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                    )
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
