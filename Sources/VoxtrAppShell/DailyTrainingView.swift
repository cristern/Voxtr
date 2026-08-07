import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// S3.3: first functional Daily Training UI. Deliberately unpolished —
/// mirrors `WeeklyPlanningView`'s style. All state changes go through
/// `DailyTrainingViewModel`, which itself only calls `TrainingService`/
/// `TrainingPlanningCoordinationService` — this view holds no business
/// logic.
public struct DailyTrainingView: View {
    @State private var viewModel: DailyTrainingViewModel
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let actorId: ActorId

    public init(viewModel: DailyTrainingViewModel, planningService: PlanningService, trainingService: TrainingService, actorId: ActorId) {
        _viewModel = State(initialValue: viewModel)
        self.planningService = planningService
        self.trainingService = trainingService
        self.actorId = actorId
    }

    public var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("training.errorMessage")
                }
            }

            Section("Today's planned activities") {
                if viewModel.plannedActivities.isEmpty {
                    Text(TrainingStrings.noPlannedActivitiesToday)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.plannedActivities, id: \.plannedActivity.id) { item in
                        NavigationLink {
                            ActivityDetailViewLoader(
                                plannedActivity: item.plannedActivity,
                                isCompleted: item.isCompleted,
                                athleteId: viewModel.athleteId,
                                actorId: actorId,
                                planningService: planningService,
                                trainingService: trainingService
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.plannedActivity.title)
                                    if let location = item.plannedActivity.location, !location.isEmpty {
                                        Text(location)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(item.isCompleted ? TrainingStrings.completedLabel : TrainingStrings.notCompletedLabel)
                                    .font(.caption)
                                    .foregroundStyle(item.isCompleted ? .green : .secondary)
                            }
                        }
                        .accessibilityIdentifier("training.plannedActivityRow.\(item.plannedActivity.id.uuidString)")
                    }
                }
            }
            .accessibilityIdentifier("training.plannedActivitiesList")

            Section("Today's logged activities") {
                if viewModel.loggedActivities.isEmpty {
                    Text(TrainingStrings.noLoggedActivitiesToday)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.loggedActivities, id: \.id) { activity in
                        VStack(alignment: .leading) {
                            Text(activity.title)
                            Text("\(activity.durationMinutes) min")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("training.loggedActivityRow.\(activity.id.uuidString)")
                    }
                }
            }
            .accessibilityIdentifier("training.loggedActivitiesList")

            Section("Log an activity") {
                TextField("Title", text: $viewModel.newLogTitle)
                    .accessibilityIdentifier("training.newLogTitleField")

                Picker("Activity type", selection: $viewModel.newLogActivityType) {
                    Text("Team training").tag(ActivityType.teamTraining)
                    Text("Match").tag(ActivityType.match)
                    Text("Competition").tag(ActivityType.competition)
                    Text("Individual training").tag(ActivityType.individualTraining)
                    Text("Physical training").tag(ActivityType.physicalTraining)
                    Text("Recovery").tag(ActivityType.recovery)
                    Text("Test").tag(ActivityType.test)
                    Text("Other").tag(ActivityType.other)
                }
                .accessibilityIdentifier("training.newLogActivityTypePicker")

                DatePicker("Started at", selection: $viewModel.newLogStartedAt)
                    .accessibilityIdentifier("training.newLogStartedAtPicker")

                Stepper(
                    "Duration: \(viewModel.newLogDurationMinutes) min",
                    value: $viewModel.newLogDurationMinutes,
                    in: 1...1440
                )
                .accessibilityIdentifier("training.newLogDurationStepper")

                Stepper(
                    "Perceived exertion: \(viewModel.newLogPerceivedExertion.map { String($0) } ?? "—")",
                    onIncrement: {
                        viewModel.newLogPerceivedExertion = min((viewModel.newLogPerceivedExertion ?? 0) + 1, 10)
                    },
                    onDecrement: {
                        let next = (viewModel.newLogPerceivedExertion ?? 1) - 1
                        viewModel.newLogPerceivedExertion = next < 1 ? nil : next
                    }
                )
                .accessibilityIdentifier("training.newLogExertionStepper")

                TextField("Notes", text: $viewModel.newLogNotes)
                    .accessibilityIdentifier("training.newLogNotesField")

                // Requirement: allow linking only to an UNCOMPLETED
                // PlannedActivity — completed ones are shown (for
                // context) but disabled, not hidden.
                Picker("Link to planned activity", selection: $viewModel.selectedPlannedActivityId) {
                    Text(TrainingStrings.noneOptionLabel).tag(PlannedActivityId?.none)
                    ForEach(viewModel.plannedActivities, id: \.plannedActivity.id) { item in
                        Text(item.plannedActivity.title)
                            .tag(Optional(item.plannedActivity.plannedActivityId))
                            .disabled(item.isCompleted)
                    }
                }
                .accessibilityIdentifier("training.linkPlannedActivityPicker")

                Button {
                    viewModel.logActivity()
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView()
                    } else {
                        Text("Log activity")
                    }
                }
                .disabled(viewModel.isSubmitting)
                .accessibilityIdentifier("training.logActivityButton")
            }
        }
        .navigationTitle("Daily Training")
        .onAppear {
            viewModel.load()
        }
    }
}
