import SwiftUI

/// Sprint 1 (Daily Use Foundation), Part 4. Athlete, activity, date, and
/// planned start time are never shown as editable fields here — they
/// are already known from the planned activity and displayed only as
/// read-only context.
public struct LogActivityView: View {
    @State private var viewModel: LogActivityViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: LogActivityViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("logActivity.errorMessage")
                    }
                }

                // Read-only context — already known from the plan, never
                // re-asked.
                Section {
                    LabeledContent("Activity", value: viewModel.plannedActivity.title)
                    LabeledContent("Date", value: viewModel.plannedActivity.localDate.isoString)
                }
                .accessibilityIdentifier("logActivity.plannedContext")

                Section("How did it go?") {
                    Stepper("Duration: \(viewModel.durationMinutes) min", value: $viewModel.durationMinutes, in: 1...1440)
                        .accessibilityIdentifier("logActivity.durationStepper")

                    Picker("RPE", selection: $viewModel.perceivedExertion) {
                        Text("Not set").tag(Int?.none)
                        ForEach(1...10, id: \.self) { value in
                            Text("\(value)").tag(Int?.some(value))
                        }
                    }
                    .accessibilityIdentifier("logActivity.rpePicker")

                    Toggle("Completed", isOn: $viewModel.isCompleted)
                        .accessibilityIdentifier("logActivity.completedToggle")

                    TextField("Notes", text: $viewModel.notes, axis: .vertical)
                        .accessibilityIdentifier("logActivity.notesField")
                }
            }
            .navigationTitle("Log Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if viewModel.save() {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("logActivity.saveButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("logActivity.cancelButton")
                }
            }
        }
    }
}
