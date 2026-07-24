import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain

/// S2.4: first functional Weekly Planning UI. Deliberately unpolished —
/// design polish is explicitly out of scope. All state changes go
/// through `WeeklyPlanningViewModel`, which itself only calls
/// `PlanningService` — this view holds no business logic.
///
/// S2.5: added the activity-type picker to both the add form and the
/// edit sheet. `WeeklyPlanningViewModel.newActivityType` and
/// `editActivity(...activityType:)` already existed since S2.4 — the
/// view simply never exposed a control for them (the add form silently
/// used the default, and edit always passed the unchanged type back).
/// This completes existing declared capability; it doesn't add any.
/// Also completed accessibility identifiers on every control that was
/// missing one (delete/cancel buttons, per-row identifiers, both
/// activity-type pickers).
public struct WeeklyPlanningView: View {
    @State private var viewModel: WeeklyPlanningViewModel
    @State private var isEditingActivity: Bool = false
    @State private var editingActivity: PlannedActivity?
    @State private var editTitle: String = ""
    @State private var editDate: Date = .now
    @State private var editActivityType: ActivityType = .individualTraining

    public init(viewModel: WeeklyPlanningViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            Section {
                HStack {
                    Text(viewModel.statusLabel)
                        .font(.headline)
                        .foregroundStyle(viewModel.isCommitted ? .green : .orange)
                        .accessibilityIdentifier("planning.statusLabel")
                    Spacer()
                    if !viewModel.isCommitted {
                        Button("Commit week") {
                            viewModel.commit()
                        }
                        .accessibilityIdentifier("planning.commitButton")
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("planning.errorMessage")
                }
            }

            Section("Planned activities") {
                ForEach(viewModel.activities, id: \.id) { activity in
                    VStack(alignment: .leading) {
                        Text(activity.title)
                        Text(activity.localDate.isoString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("planning.activityRow.\(activity.id.uuidString)")
                    .onTapGesture {
                        guard !viewModel.isCommitted else { return }
                        editingActivity = activity
                        editTitle = activity.title
                        editActivityType = activity.activityType
                        editDate = Calendar.current.date(
                            from: DateComponents(
                                year: activity.localDate.year,
                                month: activity.localDate.month,
                                day: activity.localDate.day
                            )
                        ) ?? .now
                        isEditingActivity = true
                    }
                    .swipeActions {
                        if !viewModel.isCommitted {
                            Button("Delete", role: .destructive) {
                                viewModel.deleteActivity(activity)
                            }
                            .accessibilityIdentifier("planning.deleteActivityButton.\(activity.id.uuidString)")
                        }
                    }
                }
            }
            .accessibilityIdentifier("planning.activityList")

            if !viewModel.isCommitted {
                Section("Add activity") {
                    TextField("Title", text: $viewModel.newActivityTitle)
                        .accessibilityIdentifier("planning.newActivityTitleField")
                    DatePicker("Date", selection: $viewModel.newActivityDate, displayedComponents: .date)
                        .accessibilityIdentifier("planning.newActivityDatePicker")
                    activityTypePicker(selection: $viewModel.newActivityType)
                        .accessibilityIdentifier("planning.newActivityTypePicker")
                    Button("Add activity") {
                        viewModel.addActivity()
                    }
                    .accessibilityIdentifier("planning.addActivityButton")
                }
            }
        }
        .navigationTitle("Weekly Plan")
        .onAppear {
            viewModel.loadOrCreateWeekPlan()
        }
        .sheet(isPresented: $isEditingActivity) {
            if let activity = editingActivity {
                NavigationStack {
                    Form {
                        TextField("Title", text: $editTitle)
                            .accessibilityIdentifier("planning.editActivityTitleField")
                        DatePicker("Date", selection: $editDate, displayedComponents: .date)
                            .accessibilityIdentifier("planning.editActivityDatePicker")
                        activityTypePicker(selection: $editActivityType)
                            .accessibilityIdentifier("planning.editActivityTypePicker")
                    }
                    .navigationTitle("Edit activity")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                let components = Calendar.current.dateComponents([.year, .month, .day], from: editDate)
                                let localDate = LocalDate(
                                    year: components.year ?? 1970,
                                    month: components.month ?? 1,
                                    day: components.day ?? 1
                                )
                                viewModel.editActivity(
                                    activity,
                                    title: editTitle,
                                    localDate: localDate,
                                    activityType: editActivityType
                                )
                                isEditingActivity = false
                            }
                            .accessibilityIdentifier("planning.saveEditButton")
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isEditingActivity = false }
                                .accessibilityIdentifier("planning.cancelEditButton")
                        }
                    }
                }
            }
        }
    }

    /// Shared between the add form and the edit sheet — same set of
    /// cases either way, so this avoids two copies drifting apart.
    private func activityTypePicker(selection: Binding<ActivityType>) -> some View {
        Picker("Activity type", selection: selection) {
            Text("Team training").tag(ActivityType.teamTraining)
            Text("Match").tag(ActivityType.match)
            Text("Competition").tag(ActivityType.competition)
            Text("Individual training").tag(ActivityType.individualTraining)
            Text("Physical training").tag(ActivityType.physicalTraining)
            Text("Recovery").tag(ActivityType.recovery)
            Text("Test").tag(ActivityType.test)
            Text("Other").tag(ActivityType.other)
        }
    }
}
