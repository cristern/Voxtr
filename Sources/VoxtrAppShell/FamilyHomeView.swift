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
/// Sprint 1 (Daily Use Foundation) integration audit: the doc comment
/// that used to be here described a "hosts HomeDashboardView,
/// family.activeAthletes.first" architecture that Sprint 1 replaced —
/// leaving that description in place after the replacement is exactly
/// the kind of stale documentation that makes old and new architecture
/// look mixed even when the actual code isn't. Corrected: when any
/// active athlete exists, this hosts `FamilyHomeContentView` — the
/// family-wide "Family Home" screen showing every active athlete's
/// today, not one athlete's dashboard. `HomeDashboardView` is now
/// reached only from within `FamilyHomeContentView`, as Athlete
/// Overview (a per-athlete screen a parent navigates INTO, titled
/// "<Athlete Name> Home" — see that view's own title logic), never
/// shown directly from here. When there is no active athlete at all
/// (every athlete archived, or none ever added), this shows
/// `AthleteFamilyManagementView` directly instead of an empty Family
/// Home — the family is never actually locked out, since the
/// management screen it always falls back to is exactly where "add
/// athlete" lives. A "Manage Athletes" entry point is also available
/// from the normal Family Home case (inside `FamilyHomeContentView`),
/// so a parent doesn't have to archive their only athlete just to reach
/// the multi-athlete screen. Per the same audit: `AthleteFamilyManagementView`
/// is deliberately administrative-only (list/add/edit/archive) — it
/// does not navigate into Athlete Overview, and that is the intended
/// separation, not a regression to fix.
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
                athleteRepository: athleteRepository,
                athleteManagementViewModel: makeAthleteManagementViewModel()
            )
        } else {
            NavigationStack {
                AthleteFamilyManagementView(
                    viewModel: makeAthleteManagementViewModel(),
                    athleteHomeDestination: { athlete in AnyView(self.athleteOverview(for: athlete)) }
                )
            }
        }
    }

    /// Reused verbatim from `FamilyHomeContentView`'s own
    /// `athleteOverview(for:)` — the same canonical Athlete Home
    /// (`HomeDashboardView`), never a second implementation. This
    /// exists here only because the zero-active-athletes branch above
    /// is a separate root-level presentation from
    /// `FamilyHomeContentView`, not because Athlete Home itself
    /// differs in any way.
    private func athleteOverview(for athlete: AthleteProfile) -> some View {
        HomeDashboardView(
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
            committedByActorId: ActorId(rawValue: family.participant.id),
            athleteManagementViewModel: makeAthleteManagementViewModel()
        )
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
