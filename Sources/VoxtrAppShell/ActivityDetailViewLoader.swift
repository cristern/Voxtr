import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// Sprint 1 completion package, Item 3: the ONE canonical way any
/// screen navigates from a `PlannedActivity` representation to
/// `ActivityDetailView`. Previously private to `FamilyHomeContentView`
/// and duplicated as plain, non-interactive text in
/// `HomeDashboardView` (Athlete Home) and `DailyTrainingView` — this
/// extraction is what makes "if an object can be opened in one place,
/// it should lead to the same destination everywhere it is
/// represented" actually true, rather than true only on Family Home.
///
/// Resolves the WeekPlan's draft status (needed to construct
/// `ActivityDetailViewModel`) before showing `ActivityDetailView` — a
/// small, local loading step rather than fetching this eagerly for
/// every row just to support the occasional tap.
public struct ActivityDetailViewLoader: View {
    let plannedActivity: PlannedActivity
    let isCompleted: Bool
    let athleteId: AthleteId
    let actorId: ActorId
    let planningService: PlanningService
    let trainingService: TrainingService
    @State private var viewModel: ActivityDetailViewModel?

    public init(
        plannedActivity: PlannedActivity,
        isCompleted: Bool,
        athleteId: AthleteId,
        actorId: ActorId,
        planningService: PlanningService,
        trainingService: TrainingService
    ) {
        self.plannedActivity = plannedActivity
        self.isCompleted = isCompleted
        self.athleteId = athleteId
        self.actorId = actorId
        self.planningService = planningService
        self.trainingService = trainingService
    }

    public var body: some View {
        Group {
            if let viewModel {
                ActivityDetailView(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard viewModel == nil else { return }
            let weekPlanId = WeekPlanId(rawValue: plannedActivity.weekPlanId)
            let fetchedWeekPlan = try? planningService.fetchWeekPlan(byId: weekPlanId)
            let isDraft = (fetchedWeekPlan ?? nil)?.status == .draft
            viewModel = ActivityDetailViewModel(
                activity: plannedActivity,
                isCompleted: isCompleted,
                weekPlanId: weekPlanId,
                athleteId: athleteId,
                isWeekPlanDraft: isDraft,
                deletedByActorId: actorId,
                planningService: planningService,
                trainingService: trainingService
            )
        }
    }
}
