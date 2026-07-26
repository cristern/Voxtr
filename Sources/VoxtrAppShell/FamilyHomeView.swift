import SwiftUI
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// S1.4: shown when `FamilyRestorationState` is `.existingFamily`.
/// Deliberately minimal — this is not a dashboard. S2.4: also links to
/// `WeeklyPlanningView`. S3.3: also links to `DailyTrainingView`.
/// Sprint 5.2: also links to `WeeklyReviewView`, for the current
/// calendar week — the most natural existing weekly context to launch
/// it from, matching where the other weekly-scoped screen already
/// lives. Sprint 9: also threads the coaching pipeline through to
/// `WeeklyReviewViewModel`. Sprint 11: that dependency is now
/// `CoachingApplicationService` (was `WeeklyCoachingContextService`
/// directly) — this view still only passes the dependency through, it
/// doesn't orchestrate anything itself either way.
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
        NavigationStack {
            List {
                Section("Parent") {
                    Text(family.parent.givenName)
                }
                Section("Athlete") {
                    Text(family.athlete.givenName)
                }
                Section {
                    NavigationLink("Weekly Plan") {
                        WeeklyPlanningView(
                            viewModel: WeeklyPlanningViewModel(
                                service: planningService,
                                athleteId: family.athlete.athleteId,
                                committedByActorId: ActorId(rawValue: family.participant.id)
                            )
                        )
                    }
                    .accessibilityIdentifier("familyHome.weeklyPlanLink")

                    NavigationLink("Daily Training") {
                        DailyTrainingView(
                            viewModel: DailyTrainingViewModel(
                                trainingService: trainingService,
                                coordinationService: trainingPlanningCoordinationService,
                                athleteId: family.athlete.athleteId
                            )
                        )
                    }
                    .accessibilityIdentifier("familyHome.dailyTrainingLink")

                    NavigationLink("Weekly Review") {
                        WeeklyReviewView(
                            viewModel: WeeklyReviewViewModel(
                                coordinationService: weeklyReviewCoordinationService,
                                coachingPresentationProvider: coachingApplicationService,
                                athleteId: family.athlete.athleteId,
                                weekStart: WeeklyPlanningViewModel.currentWeekStart()
                            ),
                            athleteDisplayName: family.athlete.givenName,
                            reflectionService: weeklyReflectionService,
                            authorId: ActorId(rawValue: family.participant.id)
                        )
                    }
                    .accessibilityIdentifier("familyHome.weeklyReviewLink")
                }
            }
            .navigationTitle(family.workspace.displayName)
        }
    }
}
