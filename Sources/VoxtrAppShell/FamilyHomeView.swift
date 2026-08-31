import SwiftUI
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrCoreReferenceData

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
    public let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    public let notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService
    public let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    public let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    public let weeklyReflectionService: WeeklyReflectionService
    public let coachingApplicationService: CoachingApplicationService
    public let athleteRepository: AthleteRepository
    public let athleteFamilyManagementService: AthleteFamilyManagementService
    /// Recurring reopen stale-Athlete-Home fix (architecture round): the
    /// one shared instance every `HomeDashboardViewModel`/
    /// `TrainingReflectionCoordinationService` this app constructs
    /// ultimately traces back to — passed straight through to both
    /// branches below.
    public let activityChangeBroadcaster: AthleteActivityChangeBroadcaster
    /// VX-023 (Sleep V1): same threading rationale as
    /// `activityChangeBroadcaster` above.
    public let sleepCoordinationService: SleepCoordinationService
    public let sleepChangeBroadcaster: AthleteSleepChangeBroadcaster
    /// Calendar Planning Source V1: same threading rationale as
    /// `sleepCoordinationService` above.
    public let calendarPlanningCoordinationService: CalendarPlanningCoordinationService
    public let sportRepository: SportRepository

    public init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteRepository: AthleteRepository,
        athleteFamilyManagementService: AthleteFamilyManagementService,
        activityChangeBroadcaster: AthleteActivityChangeBroadcaster,
        sleepCoordinationService: SleepCoordinationService,
        sleepChangeBroadcaster: AthleteSleepChangeBroadcaster,
        calendarPlanningCoordinationService: CalendarPlanningCoordinationService,
        sportRepository: SportRepository
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.notificationsPlanningCoordinationService = notificationsPlanningCoordinationService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteRepository = athleteRepository
        self.athleteFamilyManagementService = athleteFamilyManagementService
        self.activityChangeBroadcaster = activityChangeBroadcaster
        self.sleepCoordinationService = sleepCoordinationService
        self.sleepChangeBroadcaster = sleepChangeBroadcaster
        self.calendarPlanningCoordinationService = calendarPlanningCoordinationService
        self.sportRepository = sportRepository
    }

    public var body: some View {
        if !family.activeAthletes.isEmpty {
            FamilyHomeContentView(
                family: family,
                planningService: planningService,
                trainingService: trainingService,
                trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                weeklyReviewCoordinationService: weeklyReviewCoordinationService,
                weeklyReflectionService: weeklyReflectionService,
                coachingApplicationService: coachingApplicationService,
                athleteRepository: athleteRepository,
                athleteManagementViewModel: makeAthleteManagementViewModel(),
                activityChangeBroadcaster: activityChangeBroadcaster,
                sleepCoordinationService: sleepCoordinationService,
                sleepChangeBroadcaster: sleepChangeBroadcaster,
                calendarPlanningCoordinationService: calendarPlanningCoordinationService,
                sportRepository: sportRepository
            )
        } else {
            NavigationStack {
                AthleteFamilyManagementView(
                    viewModel: makeAthleteManagementViewModel(),
                    presentationMode: .navigation,
                    sleepSettingsViewModel: { athlete in
                        AthleteSleepSettingsViewModel(
                            sleepCoordinationService: sleepCoordinationService,
                            athleteId: athlete.athleteId,
                            athleteDisplayName: athlete.givenName
                        )
                    },
                    calendarPlanningViewModel: { athlete in
                        AthleteCalendarPlanningViewModel(
                            athleteId: athlete.athleteId,
                            calendarPlanningCoordinationService: calendarPlanningCoordinationService,
                            sportRepository: sportRepository,
                            actorId: ActorId(rawValue: family.participant.id)
                        )
                    }
                )
            }
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
