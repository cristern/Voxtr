import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain

/// S2.4: first functional Weekly Planning UI. Deliberately unpolished —
/// design polish is explicitly out of scope. All state changes go
/// through `WeeklyPlanningViewModel`, which itself only calls
/// `PlanningService` — this view holds no business logic.
public struct WeeklyPlanningView: View {
    @State private var viewModel: WeeklyPlanningViewModel
    @State private var isEditingActivity: Bool = false
    @State private var editingActivity: PlannedActivity?
    @State private var editTitle: String = ""
    @State private var editDate: Date = .now

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
                    .onTapGesture {
                        guard !viewModel.isCommitted else { return }
                        editingActivity = activity
                        editTitle = activity.title
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
                                    activityType: activity.activityType
                                )
                                isEditingActivity = false
                            }
                            .accessibilityIdentifier("planning.saveEditButton")
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isEditingActivity = false }
                        }
                    }
                }
            }
        }
    }
}
