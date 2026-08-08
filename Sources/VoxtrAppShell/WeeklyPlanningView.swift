import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

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
    @State private var isManagingRecurringActivities: Bool = false
    private let athleteDisplayName: String
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let actorId: ActorId

    public init(
        viewModel: WeeklyPlanningViewModel,
        athleteDisplayName: String,
        planningService: PlanningService,
        trainingService: TrainingService,
        actorId: ActorId
    ) {
        _viewModel = State(initialValue: viewModel)
        self.athleteDisplayName = athleteDisplayName
        self.planningService = planningService
        self.trainingService = trainingService
        self.actorId = actorId
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

            if !viewModel.isCommitted && !viewModel.recurringSuggestions.isEmpty {
                Section("Recurring suggestions") {
                    ForEach(viewModel.recurringSuggestions) { suggestion in
                        VStack(alignment: .leading) {
                            Text(suggestion.title)
                            Text(Self.suggestionSubtitle(for: suggestion))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Add to week") {
                                    viewModel.acceptSuggestion(suggestion)
                                }
                                .accessibilityIdentifier("planning.acceptSuggestionButton.\(suggestion.id)")
                                Button("Dismiss") {
                                    viewModel.dismissSuggestion(suggestion)
                                }
                                .accessibilityIdentifier("planning.dismissSuggestionButton.\(suggestion.id)")
                            }
                        }
                        .accessibilityIdentifier("planning.suggestionRow.\(suggestion.id)")
                    }
                }
                .accessibilityIdentifier("planning.suggestionList")
            }

            Section("Planned activities") {
                ForEach(viewModel.activities, id: \.id) { activity in
                    NavigationLink {
                        ActivityDetailViewLoader(
                            plannedActivity: activity,
                            isCompleted: false,
                            athleteId: viewModel.athleteId,
                            athleteDisplayName: athleteDisplayName,
                            actorId: actorId,
                            planningService: planningService,
                            trainingService: trainingService
                        )
                    } label: {
                        VStack(alignment: .leading) {
                            Text(activity.title)
                            Text(Self.rowSubtitle(for: activity))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("planning.activityRow.\(activity.id.uuidString)")
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
                    Toggle("Has start time", isOn: $viewModel.newActivityHasStartTime)
                        .accessibilityIdentifier("planning.newActivityHasStartTimeToggle")
                    if viewModel.newActivityHasStartTime {
                        DatePicker("Start time", selection: $viewModel.newActivityStartTime, displayedComponents: .hourAndMinute)
                            .accessibilityIdentifier("planning.newActivityStartTimePicker")
                    }
                    TextField("Location (optional)", text: $viewModel.newActivityLocation)
                        .accessibilityIdentifier("planning.newActivityLocationField")
                    Button("Add activity") {
                        viewModel.addActivity()
                    }
                    .accessibilityIdentifier("planning.addActivityButton")
                }
            }
        }
        .navigationTitle("\(athleteDisplayName) Weekly Plan")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Manage recurring activities") {
                    viewModel.loadRecurringActivities()
                    isManagingRecurringActivities = true
                }
                .accessibilityIdentifier("planning.manageRecurringActivitiesButton")
            }
        }
        .onAppear {
            viewModel.loadOrCreateWeekPlan()
        }
        .sheet(isPresented: $isManagingRecurringActivities) {
            RecurringActivityManagementView(viewModel: viewModel)
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

    /// Sprint 1 completion package, Part 6: date, start time (when
    /// planned), and location (when set) — everywhere the domain model
    /// already represents these, they're shown, not replaced with a
    /// generic label.
    private static func rowSubtitle(for activity: PlannedActivity) -> String {
        var parts: [String] = [activity.localDate.isoString]
        if let startTime = activity.startLocalTime {
            parts.append(String(format: "%02d:%02d", startTime.hour, startTime.minute))
        }
        if let location = activity.location, !location.isEmpty {
            parts.append(location)
        }
        return parts.joined(separator: " · ")
    }

    /// Weekday/date, start time (if present), and duration (if present)
    /// for one suggestion — everything the suggestion row displays
    /// besides its title.
    private static func suggestionSubtitle(for suggestion: RecurringActivitySuggestion) -> String {
        var parts: [String] = [weekdayLabel(for: suggestion.occurrenceDate.weekday), suggestion.occurrenceDate.isoString]
        if let startLocalTime = suggestion.startLocalTime {
            parts.append(String(format: "%02d:%02d", startLocalTime.hour, startLocalTime.minute))
        }
        if let duration = suggestion.plannedDurationMinutes {
            parts.append("\(duration) min")
        }
        return parts.joined(separator: " · ")
    }

    /// Shared with `RecurringActivityManagementView` below — same
    /// labels either way.
    static func weekdayLabel(for weekday: Weekday) -> String {
        switch weekday {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }
}

/// Simple management flow for recurring activities: list existing
/// definitions (with an enable/disable toggle and tap-to-edit), and a
/// form to create a new one or edit the tapped one. Deliberately plain
/// — a single sheet, no additional navigation structure, matching this
/// work package's own "keep the UI functional and simple" instruction.
struct RecurringActivityManagementView: View {
    @Bindable var viewModel: WeeklyPlanningViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingForm: Bool = false
    @State private var editingRecurringActivity: RecurringPlannedActivity?

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.recurringPlannedActivities) { recurringActivity in
                    VStack(alignment: .leading) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(recurringActivity.title)
                                Text(WeeklyPlanningView.weekdayLabel(for: recurringActivity.weekday))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(
                                "Enabled",
                                isOn: Binding(
                                    get: { recurringActivity.isEnabled },
                                    set: { _ in viewModel.toggleRecurringActivityEnabled(recurringActivity) }
                                )
                            )
                            .labelsHidden()
                            .accessibilityIdentifier("planning.recurringEnabledToggle.\(recurringActivity.id.uuidString)")
                        }
                    }
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("planning.recurringActivityRow.\(recurringActivity.id.uuidString)")
                    .onTapGesture {
                        editingRecurringActivity = recurringActivity
                        viewModel.beginEditingRecurringActivity(recurringActivity)
                        isPresentingForm = true
                    }
                }
            }
            .accessibilityIdentifier("planning.recurringActivityList")
            .navigationTitle("Recurring activities")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add") {
                        editingRecurringActivity = nil
                        viewModel.resetRecurringForm()
                        isPresentingForm = true
                    }
                    .accessibilityIdentifier("planning.addRecurringActivityButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("planning.doneManagingRecurringActivitiesButton")
                }
            }
            .sheet(isPresented: $isPresentingForm) {
                RecurringActivityFormView(viewModel: viewModel, editingRecurringActivity: editingRecurringActivity)
            }
        }
    }
}

/// The create/edit form itself — one form, reused for both, matching
/// how `WeeklyPlanningView`'s own edit sheet already reuses its form
/// fields for add vs. edit.
struct RecurringActivityFormView: View {
    @Bindable var viewModel: WeeklyPlanningViewModel
    let editingRecurringActivity: RecurringPlannedActivity?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("planning.recurringFormErrorMessage")
                    }
                }

                TextField("Title", text: $viewModel.recurringFormTitle)
                    .accessibilityIdentifier("planning.recurringFormTitleField")

                Picker("Activity type", selection: $viewModel.recurringFormActivityType) {
                    Text("Team training").tag(ActivityType.teamTraining)
                    Text("Match").tag(ActivityType.match)
                    Text("Competition").tag(ActivityType.competition)
                    Text("Individual training").tag(ActivityType.individualTraining)
                    Text("Physical training").tag(ActivityType.physicalTraining)
                    Text("Recovery").tag(ActivityType.recovery)
                    Text("Test").tag(ActivityType.test)
                    Text("Other").tag(ActivityType.other)
                }
                .accessibilityIdentifier("planning.recurringFormActivityTypePicker")

                Picker("Weekday", selection: $viewModel.recurringFormWeekday) {
                    ForEach(Weekday.allCases, id: \.self) { weekday in
                        Text(WeeklyPlanningView.weekdayLabel(for: weekday)).tag(weekday)
                    }
                }
                .accessibilityIdentifier("planning.recurringFormWeekdayPicker")

                DatePicker(
                    "Start date",
                    selection: $viewModel.recurringFormStartDate,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("planning.recurringFormStartDatePicker")

                DatePicker(
                    "End date",
                    selection: $viewModel.recurringFormEndDate,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("planning.recurringFormEndDatePicker")

                Toggle("Has start time", isOn: $viewModel.recurringFormHasStartTime)
                    .accessibilityIdentifier("planning.recurringFormHasStartTimeToggle")
                if viewModel.recurringFormHasStartTime {
                    DatePicker(
                        "Start time",
                        selection: $viewModel.recurringFormStartTime,
                        displayedComponents: .hourAndMinute
                    )
                    .accessibilityIdentifier("planning.recurringFormStartTimePicker")
                }

                Toggle("Has duration", isOn: $viewModel.recurringFormHasDuration)
                    .accessibilityIdentifier("planning.recurringFormHasDurationToggle")
                if viewModel.recurringFormHasDuration {
                    Stepper(
                        "Duration: \(viewModel.recurringFormDurationMinutes) min",
                        value: $viewModel.recurringFormDurationMinutes,
                        in: 1...1440
                    )
                    .accessibilityIdentifier("planning.recurringFormDurationStepper")
                }
            }
            .navigationTitle(editingRecurringActivity == nil ? "Add recurring activity" : "Edit recurring activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let succeeded: Bool
                        if let editingRecurringActivity {
                            succeeded = viewModel.editRecurringActivity(editingRecurringActivity)
                        } else {
                            succeeded = viewModel.createRecurringActivity()
                        }
                        if succeeded {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("planning.saveRecurringActivityButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("planning.cancelRecurringActivityButton")
                }
            }
        }
    }
}
