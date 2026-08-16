import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain

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
///
/// Sprint 1.1, P1 (athlete context): `athleteDisplayName` is required
/// from every caller — each one already has the athlete's name at hand
/// (a `FamilyHomeRow`, an `athleteDisplayName` property already on the
/// calling view, etc.), so this never duplicates athlete state or
/// re-fetches it from a repository.
public struct ActivityDetailViewLoader: View {
    let plannedActivity: PlannedActivity
    let isCompleted: Bool
    let athleteId: AthleteId
    let athleteDisplayName: String
    let actorId: ActorId
    let planningService: PlanningService
    let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    /// Post-mutation navigation and stale-state consistency audit: the
    /// caller's own reload/refresh entry point — called the moment a
    /// log genuinely succeeds inside `ActivityDetailView`, so the
    /// screen this loader was pushed from (Family Home, Athlete Home,
    /// Daily Training, Family Schedule, Weekly Planning) reflects the
    /// new completion state immediately when it becomes visible again,
    /// rather than relying solely on `.onAppear` refiring reliably
    /// after this deep a push/sheet/pop chain. Defaulted to a no-op so
    /// existing call sites/tests are unaffected.
    let onActivityLogged: () -> Void
    @State private var viewModel: ActivityDetailViewModel?

    public init(
        plannedActivity: PlannedActivity,
        isCompleted: Bool,
        athleteId: AthleteId,
        athleteDisplayName: String,
        actorId: ActorId,
        planningService: PlanningService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        onActivityLogged: @escaping () -> Void = {}
    ) {
        self.plannedActivity = plannedActivity
        self.isCompleted = isCompleted
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.actorId = actorId
        self.planningService = planningService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.onActivityLogged = onActivityLogged
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
            // VX-022 closeout: resolves the exact LoggedActivity (for
            // RPE) and its linked ActivityReflection (for Form), same
            // local-loading-step pattern as the WeekPlan fetch above —
            // nil when nothing has been logged yet, never an error.
            let loggedDetail = (try? trainingReflectionCoordinationService.loggedActivityDetail(
                forPlannedActivity: plannedActivity.plannedActivityId
            )) ?? nil
            viewModel = ActivityDetailViewModel(
                activity: plannedActivity,
                isCompleted: isCompleted,
                loggedActivity: loggedDetail?.loggedActivity,
                activityReflection: loggedDetail?.reflection,
                weekPlanId: weekPlanId,
                athleteId: athleteId,
                athleteDisplayName: athleteDisplayName,
                isWeekPlanDraft: isDraft,
                deletedByActorId: actorId,
                planningService: planningService,
                trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                onActivityLogged: onActivityLogged
            )
        }
    }
}
