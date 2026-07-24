import SwiftUI
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain

/// S1.4: shown when `FamilyRestorationState` is `.existingFamily`.
/// Deliberately minimal — this is not Weekly Review, not a dashboard.
/// S2.4: now also links to `WeeklyPlanningView` for the restored
/// family's (sole, Sprint 1/2) athlete.
public struct FamilyHomeView: View {
    public let family: RestoredFamily
    public let planningService: PlanningService

    public init(family: RestoredFamily, planningService: PlanningService) {
        self.family = family
        self.planningService = planningService
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
                }
            }
            .navigationTitle(family.workspace.displayName)
        }
    }
}
