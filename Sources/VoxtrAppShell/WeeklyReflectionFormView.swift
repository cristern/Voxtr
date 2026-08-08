import SwiftUI

/// Sprint 5.2: the first (and only) `WeeklyReflection` form. Mirrors
/// `WeeklyPlanningView`/`DailyTrainingView`'s deliberately unpolished
/// style. Used for both starting and editing — `viewModel.isEditing`
/// only changes the title, the fields are the same either way.
///
/// Sprint 1.1 (P0 fix — Family Home reflection navigation lock): this
/// view previously always wrapped itself in its own `NavigationStack`.
/// That was already wrong for one of its two real call sites —
/// `ReflectionFormViewLoader` pushes this view within
/// `FamilyHomeContentView`'s (or `HomeDashboardView`'s) own, already-
/// active `NavigationStack` — nesting a second `NavigationStack` inside
/// an already-active one is a known, severe SwiftUI failure mode: it
/// doesn't just break this screen, it can corrupt the OUTER stack's own
/// navigation state, exactly matching every symptom reported (the
/// destination rendering ambiguously, navigation across the whole app
/// going dead after one interaction, only a full restart recovering).
/// The exact same class of bug was already found and fixed twice
/// before in this codebase (`HomeDashboardView`, then
/// `AthleteFamilyManagementView`) — this is the third, previously-
/// missed instance. Fixed the same way: this view no longer wraps
/// itself in a `NavigationStack` at all. `WeeklyReviewView`'s own
/// `.sheet(...)` call site (a genuinely independent presentation
/// context, which DOES need its own stack) now supplies one itself,
/// the same way `HomeDashboardView`'s "Manage Athletes" sheet already
/// wraps `AthleteFamilyManagementView`.
public struct WeeklyReflectionFormView: View {
    @State private var viewModel: WeeklyReflectionFormViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: WeeklyReflectionFormViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("weeklyReflectionForm.errorMessage")
                }
            }

            Section("How did the week feel?") {
                Stepper(
                    "Overall satisfaction: \(viewModel.overallSatisfaction.map { String($0) } ?? "—")",
                    onIncrement: {
                        viewModel.overallSatisfaction = min((viewModel.overallSatisfaction ?? 0) + 1, 5)
                    },
                    onDecrement: {
                        let next = (viewModel.overallSatisfaction ?? 1) - 1
                        viewModel.overallSatisfaction = next < 1 ? nil : next
                    }
                )
                .accessibilityIdentifier("weeklyReflectionForm.satisfactionStepper")

                Stepper(
                    "Load felt: \(viewModel.loadFelt.map { String($0) } ?? "—")",
                    onIncrement: { viewModel.loadFelt = min((viewModel.loadFelt ?? 0) + 1, 5) },
                    onDecrement: {
                        let next = (viewModel.loadFelt ?? 1) - 1
                        viewModel.loadFelt = next < 1 ? nil : next
                    }
                )
                .accessibilityIdentifier("weeklyReflectionForm.loadFeltStepper")
            }

            Section("What worked") {
                TextField("What worked well this week", text: $viewModel.whatWorked, axis: .vertical)
                    .accessibilityIdentifier("weeklyReflectionForm.whatWorkedField")
            }
            Section("What was difficult") {
                TextField("What was difficult this week", text: $viewModel.whatWasDifficult, axis: .vertical)
                    .accessibilityIdentifier("weeklyReflectionForm.whatWasDifficultField")
            }
            Section("Learning") {
                TextField("What did you learn", text: $viewModel.learning, axis: .vertical)
                    .accessibilityIdentifier("weeklyReflectionForm.learningField")
            }
            Section("Next week") {
                TextField("Anything to consider for next week", text: $viewModel.nextWeekConsideration, axis: .vertical)
                    .accessibilityIdentifier("weeklyReflectionForm.nextWeekField")
            }
        }
        .navigationTitle(viewModel.isEditing ? "\(viewModel.athleteDisplayName) · Edit Reflection" : "\(viewModel.athleteDisplayName) · New Reflection")
        .onAppear {
            viewModel.onSaved = { dismiss() }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    viewModel.save()
                }
                .disabled(viewModel.isSubmitting)
                .accessibilityIdentifier("weeklyReflectionForm.saveButton")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("weeklyReflectionForm.cancelButton")
            }
        }
    }
}
