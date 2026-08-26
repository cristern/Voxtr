import SwiftUI

/// Sprint 1 (Daily Use Foundation), Part 4. Athlete, activity, date, and
/// planned start time are never shown as editable fields here — they
/// are already known from the planned activity and displayed only as
/// read-only context.
public struct LogActivityView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: LogActivityViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: LogActivityViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            Form {
                // Read-only context — already known from the plan, never
                // re-asked.
                Section {
                    LabeledContent("Athlete", value: viewModel.athleteDisplayName)
                    LabeledContent("Activity", value: ActivityLabelResolver(modelContext: modelContext).primaryLabel(for: viewModel.plannedActivity))
                    LabeledContent("Date", value: viewModel.plannedActivity.localDate.isoString)
                }
                .voxtrRowSurface()
                .accessibilityIdentifier("logActivity.plannedContext")

                Section {
                    // Activity outcome consistency closeout (item C):
                    // an explicit, clearly-labelled "Outcome" control —
                    // the previous "Completed" Toggle gave no visible
                    // way to discover Missed at all (off just read as
                    // "not yet marked completed", not as a distinct
                    // outcome). Persistence is UNCHANGED: `isCompleted`
                    // still drives `save()`'s own canonical `.completed`/
                    // `.missed` derivation exactly as before — only the
                    // control's presentation changed. Cancelled remains
                    // its own separate action (Activity Detail's "Cancel
                    // Activity"), never duplicated here; Partially
                    // Completed stays unexposed — no reachable flow
                    // produces it yet.
                    Picker("Outcome", selection: $viewModel.isCompleted) {
                        Text("Completed").tag(true)
                        Text("Missed").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("logActivity.outcomePicker")

                    // Completed requires actual duration. Nil remains
                    // visibly "Not set" until an explicit Set duration
                    // action; once set, the picker binds directly to the
                    // ViewModel and cannot be cleared. Missed hides this
                    // required-only control while retaining transient edit
                    // state if the user switches back to Completed.
                    if viewModel.isCompleted {
                        RequiredDurationPickerView(durationMinutes: $viewModel.durationMinutes)
                    }

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

                    TextField("Notes", text: $viewModel.notes, axis: .vertical)
                        .accessibilityIdentifier("logActivity.notesField")

                    // TestFlight closeout: validation/error feedback lives
                    // right where the user is acting — the last row of
                    // this same section, immediately above the Save
                    // action in the toolbar — rather than a detached
                    // message at the top of the screen the user has to
                    // scroll back up to notice. Same local-placement
                    // convention DailyTrainingView's own manual log form
                    // already establishes for its own `logErrorMessage`
                    // (right before that flow's own inline Save button).
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("logActivity.errorMessage")
                    }
                } header: {
                    VoxtrSectionHeading("How did it go?")
                }
                .voxtrRowSurface()
            }
            .voxtrScreenBackground()
            .tint(VoxtrColor.accent)
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
