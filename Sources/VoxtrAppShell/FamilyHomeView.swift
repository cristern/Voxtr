import SwiftUI
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// S1.4: shown when `FamilyRestorationState` is `.existingFamily`.
/// S2.4: also links to `WeeklyPlanningView`. S3.3: also links to
/// `DailyTrainingView`. Sprint 5.2: also links to `WeeklyReviewView`.
/// Sprint 9: also threads the coaching pipeline through. Sprint 11:
/// that dependency is `CoachingApplicationService`.
///
/// Sprint 12 (refactored): this view's own content (the previous
/// `List` of Parent/Athlete text and three navigation links) has been
/// replaced — this is now purely the container that receives the
/// family/services from `RootView` and hosts `HomeDashboardView`,
/// restoring `RootView → FamilyHomeView → HomeDashboardView` as the
/// actual navigation hierarchy. `RootView` no longer reaches past this
/// type directly to `HomeDashboardView`. `HomeDashboardView` itself is
/// unchanged by this refactor — it remains focused solely on the
/// dashboard UI and has no awareness of `FamilyHomeView` at all; this
/// type is the only thing that changed.
public struct FamilyHomeView: View {
    public let family: RestoredFamily
    public let planningService: PlanningService
    public let trainingService: TrainingService
    public let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    public let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    public let weeklyReflectionService: WeeklyReflectionService
    public let coachingApplicationService: CoachingApplicationService

    public init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
    }

    public var body: some View {
        HomeDashboardView(
            viewModel: HomeDashboardViewModel(
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                coachingPresentationProvider: coachingApplicationService,
                athleteId: family.athlete.athleteId,
                weekStart: WeeklyPlanningViewModel.currentWeekStart()
            ),
            athleteDisplayName: family.athlete.givenName,
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReviewCoordinationService: weeklyReviewCoordinationService,
            weeklyReflectionService: weeklyReflectionService,
            coachingApplicationService: coachingApplicationService,
            athleteId: family.athlete.athleteId,
            committedByActorId: ActorId(rawValue: family.participant.id)
        )
    }
}
