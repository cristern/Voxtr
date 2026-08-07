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
/// actual navigation hierarchy.
///
/// Multi-Athlete Family Foundation: `family.athletes` may now hold
/// zero, one, or several athletes — this work package explicitly does
/// not redesign Home into a multi-athlete agenda (that is future work),
/// so `HomeDashboardView` itself is unchanged and still shows exactly
/// one athlete: `family.activeAthletes.first`, deterministically
/// ordered by `FamilyRestorationService`. When there is no active
/// athlete at all (every athlete archived, or none ever added), this
/// shows `AthleteFamilyManagementView` directly instead of an empty
/// dashboard — the family is never actually locked out, since the
/// management screen it always falls back to is exactly where "add
/// athlete" lives. A "Manage Athletes" entry point is also available
/// from the normal dashboard case (threaded into `HomeDashboardView`),
/// so a parent doesn't have to delete their only athlete just to reach
/// the multi-athlete screen.
public struct FamilyHomeView: View {
    public let family: RestoredFamily
    public let planningService: PlanningService
    public let trainingService: TrainingService
    public let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    public let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    public let weeklyReflectionService: WeeklyReflectionService
    public let coachingApplicationService: CoachingApplicationService
    public let athleteRepository: AthleteRepository
    public let athleteFamilyManagementService: AthleteFamilyManagementService

    public init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteRepository: AthleteRepository,
        athleteFamilyManagementService: AthleteFamilyManagementService
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteRepository = athleteRepository
        self.athleteFamilyManagementService = athleteFamilyManagementService
    }

    public var body: some View {
        if !family.activeAthletes.isEmpty {
            FamilyHomeContentView(
                family: family,
                planningService: planningService,
                trainingService: trainingService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                weeklyReviewCoordinationService: weeklyReviewCoordinationService,
                weeklyReflectionService: weeklyReflectionService,
                coachingApplicationService: coachingApplicationService,
                athleteManagementViewModel: makeAthleteManagementViewModel()
            )
        } else {
            AthleteFamilyManagementView(viewModel: makeAthleteManagementViewModel())
        }
    }

    private func makeAthleteManagementViewModel() -> AthleteFamilyManagementViewModel {
        AthleteFamilyManagementViewModel(
            workspaceId: WorkspaceId(rawValue: family.workspace.id),
            participantId: family.participant.id,
            athleteRepository: athleteRepository,
            athleteFamilyManagementService: athleteFamilyManagementService
        )
    }
}
