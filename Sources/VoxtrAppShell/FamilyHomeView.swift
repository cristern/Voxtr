import SwiftUI
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// S1.4: shown when `FamilyRestorationState` is `.existingFamily`.
/// Deliberately minimal — this is not Weekly Review, not a dashboard.
/// S2.4: also links to `WeeklyPlanningView`. S3.3: also links to
/// `DailyTrainingView`, for the restored family's (sole, Sprint 1/2/3)
/// athlete.
public struct FamilyHomeView: View {
    public let family: RestoredFamily
    public let planningService: PlanningService
    public let trainingService: TrainingService
    public let trainingPlanningCoordinationService: TrainingPlanningCoordinationService

    public init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
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
                }
            }
            .navigationTitle(family.workspace.displayName)
        }
    }
}
