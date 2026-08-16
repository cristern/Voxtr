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

    /// Planned/Logged Activity lifecycle consistency cleanup:
    /// `DurationPickerView` binds to a non-optional `Int` (the same
    /// shared component reused everywhere duration is entered — not
    /// rewritten for this one case). `viewModel.durationMinutes` is
    /// `Int?` (unset unless the plan prefilled it), so this bridges the
    /// two: displays a sensible starting value when nothing has been
    /// entered yet, but only WRITES to `durationMinutes` once the user
    /// actually interacts with the picker — an untouched nil is exactly
    /// what `save()`'s own required-for-completed validation is there
    /// to catch, not something this binding papers over.
    private var durationMinutesBinding: Binding<Int> {
        Binding(
            get: { viewModel.durationMinutes ?? 60 },
            set: { viewModel.durationMinutes = $0 }
        )
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
                    LabeledContent("Athlete", value: viewModel.athleteDisplayName)
                    LabeledContent("Activity", value: viewModel.plannedActivity.title)
                    LabeledContent("Date", value: viewModel.plannedActivity.localDate.isoString)
                }
                .accessibilityIdentifier("logActivity.plannedContext")

                Section("How did it go?") {
                    DurationPickerView(durationMinutes: durationMinutesBinding)

                    Picker("RPE", selection: $viewModel.perceivedExertion) {
                        Text("Not set").tag(Int?.none)
                        ForEach(1...10, id: \.self) { value in
                            Text("\(value)").tag(Int?.some(value))
                        }
                    }
                    .accessibilityIdentifier("logActivity.rpePicker")

                    // VX-022: "Form" — required when Completed is on
                    // (nothing to rate for a not-completed log). Neutral
                    // 1-5 scale, no failure/success labeling, no scoring
                    // or readiness language, same Picker shape as RPE
                    // above. No "Not set" option — Form is required, not
                    // optional, for the V1 contract.
                    Picker("Form", selection: $viewModel.sessionForm) {
                        ForEach(1...5, id: \.self) { value in
                            Text("\(value)").tag(Int?.some(value))
                        }
                    }
                    .accessibilityIdentifier("logActivity.sessionFormPicker")

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
