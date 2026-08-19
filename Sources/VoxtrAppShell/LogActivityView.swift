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
                    .voxtrRowSurface()
                }

                // Read-only context — already known from the plan, never
                // re-asked.
                Section {
                    LabeledContent("Athlete", value: viewModel.athleteDisplayName)
                    LabeledContent("Activity", value: viewModel.plannedActivity.title)
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

                    // Activity outcome consistency closeout (item D):
                    // `OptionalDurationPickerView` (below), not a
                    // `Binding<Int>` bridge defaulting to 60 — that
                    // bridge made the UI SHOW 60 as though it were the
                    // current value even when `viewModel.durationMinutes`
                    // was genuinely nil (no planned duration, nothing
                    // entered yet), while `save()`'s own validation
                    // still correctly rejected it — a visible value the
                    // canonical edit state didn't actually contain. Only
                    // shown for Completed — Missed never requires or
                    // asks for duration.
                    if viewModel.isCompleted {
                        OptionalDurationPickerView(durationMinutes: $viewModel.durationMinutes)
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
