import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain

/// Sprint 1 (Daily Use Foundation), Part 3.
public struct ActivityDetailView: View {
    @State private var viewModel: ActivityDetailViewModel
    @State private var isEditing: Bool = false
    @State private var isLogging: Bool = false
    @State private var isPresentingDeleteConfirmation: Bool = false
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: ActivityDetailViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("activityDetail.errorMessage")
                }
            }

            Section {
                LabeledContent("Athlete", value: viewModel.athleteDisplayName)
                LabeledContent("Activity", value: viewModel.activity.title)
                LabeledContent("Date", value: viewModel.activity.localDate.isoString)
                if let startTime = viewModel.activity.startLocalTime {
                    LabeledContent("Time", value: String(format: "%02d:%02d", startTime.hour, startTime.minute))
                }
                if let location = viewModel.activity.location, !location.isEmpty {
                    LabeledContent("Location", value: location)
                }
                if let notes = viewModel.activity.notes, !notes.isEmpty {
                    LabeledContent("Notes", value: notes)
                }
                LabeledContent("Status", value: viewModel.isCompleted ? "Completed" : "Ready to log")
            }
            .accessibilityIdentifier("activityDetail.summary")

            Section {
                if viewModel.isCompleted {
                    // Activity Completion & Review Flow package: the
                    // "Log Activity" button used to remain visible and
                    // tappable even after the activity was already
                    // logged — the only feedback was a small "Status"
                    // label easy to miss among several other fields.
                    // Since TrainingService.logActivity already
                    // prevents the same PlannedActivity from being
                    // linked twice (S3.2, the correct application/
                    // domain boundary — preserved, not rewritten here),
                    // re-tapping "Log Activity" would only surface that
                    // failure after the user filled the form out again.
                    // Replacing the button with a clear, non-actionable
                    // confirmation closes that gap at the UI layer,
                    // where it belongs alongside the existing service-
                    // layer protection.
                    Label("Logged", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("activityDetail.loggedIndicator")
                } else {
                    Button("Log Activity") {
                        isLogging = true
                    }
                    .accessibilityIdentifier("activityDetail.logActivityButton")
                }

                if viewModel.canEditOrDelete {
                    Button("Edit Planned Activity") {
                        viewModel.prefillEditForm()
                        isEditing = true
                    }
                    .accessibilityIdentifier("activityDetail.editButton")

                    Button("Delete Planned Activity", role: .destructive) {
                        isPresentingDeleteConfirmation = true
                    }
                    .accessibilityIdentifier("activityDetail.deleteButton")
                } else {
                    Text("This week's plan is committed — editing and deleting are no longer available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(viewModel.activity.title)
        .sheet(isPresented: $isEditing) {
            ActivityEditFormView(viewModel: viewModel)
        }
        .sheet(isPresented: $isLogging) {
            LogActivityView(viewModel: viewModel.makeLogActivityViewModel())
        }
        .onChange(of: viewModel.isCompleted) { wasCompleted, isCompleted in
            // Fires only on the true transition from not-yet-logged to
            // logged (the moment a save actually succeeds) — never on
            // initial appearance, so opening an already-completed
            // activity to review it never auto-dismisses.
            if !wasCompleted && isCompleted {
                dismiss()
            }
        }
        .confirmationDialog(
            "Delete this planned activity?",
            isPresented: $isPresentingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if viewModel.deleteActivity() {
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The edit form — a separate sheet, reusing
/// `ActivityDetailViewModel`'s own edit fields directly (no duplicate
/// editing logic, matching this work's own constraint).
struct ActivityEditFormView: View {
    @Bindable var viewModel: ActivityDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $viewModel.editTitle)
                    .accessibilityIdentifier("activityDetail.editTitleField")
                DatePicker("Date", selection: $viewModel.editDate, displayedComponents: .date)
                    .accessibilityIdentifier("activityDetail.editDatePicker")
                Picker("Activity type", selection: $viewModel.editActivityType) {
                    Text("Team training").tag(ActivityType.teamTraining)
                    Text("Match").tag(ActivityType.match)
                    Text("Competition").tag(ActivityType.competition)
                    Text("Individual training").tag(ActivityType.individualTraining)
                    Text("Physical training").tag(ActivityType.physicalTraining)
                    Text("Recovery").tag(ActivityType.recovery)
                    Text("Test").tag(ActivityType.test)
                    Text("Other").tag(ActivityType.other)
                }
                .accessibilityIdentifier("activityDetail.editActivityTypePicker")

                Toggle("Has start time", isOn: $viewModel.editHasStartTime)
                if viewModel.editHasStartTime {
                    DatePicker("Start time", selection: $viewModel.editStartTime, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("activityDetail.editStartTimePicker")
                }

                Toggle("Has duration", isOn: $viewModel.editHasDuration)
                if viewModel.editHasDuration {
                    DurationPickerView(durationMinutes: $viewModel.editDurationMinutes)
                }

                TextField("Notes", text: $viewModel.editNotes, axis: .vertical)
                    .accessibilityIdentifier("activityDetail.editNotesField")

                TextField("Location", text: $viewModel.editLocation)
                    .accessibilityIdentifier("activityDetail.editLocationField")
            }
            .navigationTitle("Edit Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if viewModel.saveEdit() {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("activityDetail.saveEditButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("activityDetail.cancelEditButton")
                }
            }
        }
    }
}
