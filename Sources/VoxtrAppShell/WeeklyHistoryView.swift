import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// Area 6: "Week by Week" — presents ONE historical week's factual
/// truth. Deliberately no hero percentage/score (e.g. never "83%
/// achieved") — only plain counts, per the approved contract. No
/// sibling comparison, no ratings, no gamification.
public struct WeeklyHistoryView: View {
    @State private var viewModel: WeeklyHistoryViewModel
    let athleteDisplayName: String

    public init(viewModel: WeeklyHistoryViewModel, athleteDisplayName: String) {
        _viewModel = State(initialValue: viewModel)
        self.athleteDisplayName = athleteDisplayName
    }

    public var body: some View {
        Form {
            Section {
                Text(athleteDisplayName)
                    .font(.headline)
                    .accessibilityIdentifier("weeklyHistory.athleteName")
                HStack {
                    Button {
                        viewModel.switchToWeek(viewModel.weekStart.adding(days: -7))
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityIdentifier("weeklyHistory.previousWeekButton")
                    WeekIdentityView(
                        weekStart: viewModel.weekStart,
                        referenceWeekStart: WeeklyPlanningViewModel.currentWeekStart()
                    )
                    Button {
                        viewModel.switchToWeek(viewModel.weekStart.adding(days: 7))
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityIdentifier("weeklyHistory.nextWeekButton")
                }
            }
            .accessibilityIdentifier("weeklyHistory.weekIdentityBar")

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section("What happened") {
                LabeledContent("Planned", value: "\(viewModel.plannedCount)")
                    .accessibilityIdentifier("weeklyHistory.plannedCount")
                LabeledContent("Completed from plan", value: "\(viewModel.completedFromPlanCount)")
                    .accessibilityIdentifier("weeklyHistory.completedCount")
                LabeledContent("Additional", value: "\(viewModel.additionalCount)")
                    .accessibilityIdentifier("weeklyHistory.additionalCount")
            }

            if let plannedActivities = viewModel.result?.plannedActivities, !plannedActivities.isEmpty {
                Section("Planned activities") {
                    ForEach(plannedActivities, id: \.plannedActivity.id) { completion in
                        HStack {
                            Text(completion.plannedActivity.title)
                            Spacer()
                            if completion.isCompleted {
                                Text("Completed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("weeklyHistory.plannedActivitiesSection")
            }

            if !viewModel.additionalLoggedActivities.isEmpty {
                Section("Additional (unplanned)") {
                    ForEach(viewModel.additionalLoggedActivities, id: \.id) { logged in
                        Text(logged.title)
                    }
                }
                .accessibilityIdentifier("weeklyHistory.additionalActivitiesSection")
            }

            if let reflection = viewModel.result?.weeklyReflection {
                Section("Reflection") {
                    if let whatWorked = reflection.whatWorked, !whatWorked.isEmpty {
                        LabeledContent("What worked", value: whatWorked)
                    }
                    if let whatWasDifficult = reflection.whatWasDifficult, !whatWasDifficult.isEmpty {
                        LabeledContent("What was difficult", value: whatWasDifficult)
                    }
                    if let focus = viewModel.focusNextWeekIfPermitted, !focus.isEmpty {
                        LabeledContent("Focus next week", value: focus)
                    }
                }
                .accessibilityIdentifier("weeklyHistory.reflectionSection")
            }
        }
        .navigationTitle("Week by Week")
        .onAppear {
            viewModel.load()
        }
    }
}
