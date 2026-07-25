import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Sprint 5.2: presents one athlete's week for review. Deliberately
/// unpolished, mirroring `WeeklyPlanningView`/`DailyTrainingView`'s
/// style. Every value shown comes directly from
/// `WeeklyReviewViewModel.loadState`'s `WeeklyReviewResult` — this view
/// recomputes no completion state, no ordering, no date scoping.
public struct WeeklyReviewView: View {
    @State private var viewModel: WeeklyReviewViewModel
    @State private var isShowingReflectionForm = false
    private let athleteDisplayName: String
    private let reflectionService: WeeklyReflectionService
    private let authorId: ActorId

    public init(
        viewModel: WeeklyReviewViewModel,
        athleteDisplayName: String,
        reflectionService: WeeklyReflectionService,
        authorId: ActorId
    ) {
        _viewModel = State(initialValue: viewModel)
        self.athleteDisplayName = athleteDisplayName
        self.reflectionService = reflectionService
        self.authorId = authorId
    }

    public var body: some View {
        Form {
            header

            switch viewModel.loadState {
            case .loading:
                Section {
                    ProgressView()
                        .accessibilityIdentifier("weeklyReview.loadingIndicator")
                }
            case .failed:
                Section {
                    Text(WeeklyReviewStrings.genericError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("weeklyReview.errorMessage")
                }
            case .loaded(let result):
                weekPlanSection(result)
                plannedActivitiesSection(result)
                loggedActivitiesSection(result)
                reflectionSection(result)
            }
        }
        .navigationTitle("Weekly Review")
        .onAppear {
            viewModel.load()
        }
        .sheet(isPresented: $isShowingReflectionForm, onDismiss: {
            // Requirement: reload after returning from the reflection
            // form, whether the user saved or cancelled — reloading on
            // any dismissal is simpler than tracking save-vs-cancel
            // separately, and idempotent if nothing actually changed.
            viewModel.load()
        }) {
            if case .loaded(let result) = viewModel.loadState {
                WeeklyReflectionFormView(
                    viewModel: WeeklyReflectionFormViewModel(
                        service: reflectionService,
                        athleteId: viewModel.athleteId,
                        weekStart: viewModel.weekStart,
                        authorId: authorId,
                        existing: result.weeklyReflection
                    )
                )
            }
        }
    }

    private var header: some View {
        Section {
            Text(athleteDisplayName)
                .accessibilityIdentifier("weeklyReview.athleteName")
            Text(viewModel.weekStart.isoString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("weeklyReview.weekStart")
        }
    }

    private func weekPlanSection(_ result: WeeklyReviewResult) -> some View {
        Section("Weekly plan") {
            if let weekPlan = result.weekPlan {
                Text(weekPlan.status == .committed ? "Committed" : "Draft")
                    .accessibilityIdentifier("weeklyReview.weekPlanStatus")
            } else {
                Text(WeeklyReviewStrings.noWeekPlan)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyReview.noWeekPlan")
            }
        }
    }

    private func plannedActivitiesSection(_ result: WeeklyReviewResult) -> some View {
        Section("Planned activities") {
            if result.plannedActivities.isEmpty {
                Text(WeeklyReviewStrings.noPlannedActivities)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyReview.noPlannedActivities")
            } else {
                ForEach(result.plannedActivities, id: \.plannedActivity.id) { item in
                    HStack {
                        Text(item.plannedActivity.title)
                        Spacer()
                        Text(item.isCompleted ? TrainingStrings.completedLabel : TrainingStrings.notCompletedLabel)
                            .font(.caption)
                            .foregroundStyle(item.isCompleted ? .green : .secondary)
                            .accessibilityLabel(
                                Text(item.isCompleted ? TrainingStrings.completedLabel : TrainingStrings.notCompletedLabel)
                            )
                    }
                    .accessibilityIdentifier("weeklyReview.plannedActivityRow.\(item.plannedActivity.id.uuidString)")
                }
            }
        }
    }

    private func loggedActivitiesSection(_ result: WeeklyReviewResult) -> some View {
        Section("Logged activities") {
            if result.loggedActivities.isEmpty {
                Text(WeeklyReviewStrings.noLoggedActivities)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyReview.noLoggedActivities")
            } else {
                ForEach(result.loggedActivities, id: \.id) { activity in
                    VStack(alignment: .leading) {
                        Text(activity.title)
                        Text("\(activity.durationMinutes) min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("weeklyReview.loggedActivityRow.\(activity.id.uuidString)")
                }
            }
        }
    }

    private func reflectionSection(_ result: WeeklyReviewResult) -> some View {
        Section("Weekly reflection") {
            if let reflection = result.weeklyReflection {
                if let satisfaction = reflection.overallSatisfaction {
                    Text("Overall satisfaction: \(satisfaction)/5")
                }
                if let learning = reflection.learning {
                    Text(learning)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(WeeklyReviewStrings.noReflection)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyReview.noReflection")
            }

            Button(result.weeklyReflection == nil ? WeeklyReviewStrings.startReflectionAction : WeeklyReviewStrings.editReflectionAction) {
                isShowingReflectionForm = true
            }
            .accessibilityIdentifier("weeklyReview.reflectionAction")
            .accessibilityLabel(
                Text(result.weeklyReflection == nil ? WeeklyReviewStrings.startReflectionAction : WeeklyReviewStrings.editReflectionAction)
            )
        }
    }
}
