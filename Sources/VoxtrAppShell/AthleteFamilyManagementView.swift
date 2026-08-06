import SwiftUI
import VoxtrCoreContracts
import VoxtrAthleteDomain

/// Multi-Athlete Family Foundation. The minimum UI this work package
/// asks for: list every athlete, add, edit, archive/delete, and a
/// clear empty state when there are no active athletes. Deliberately
/// plain — no visual redesign, matching this work package's own
/// constraint.
public struct AthleteFamilyManagementView: View {
    @State private var viewModel: AthleteFamilyManagementViewModel
    @State private var isPresentingForm: Bool = false
    @State private var editingAthlete: AthleteProfile?
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: AthleteFamilyManagementViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if viewModel.athletes.filter({ !$0.isArchived }).isEmpty {
                    emptyState
                } else {
                    athleteList
                }
            }
            .navigationTitle("Athletes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add") {
                        editingAthlete = nil
                        viewModel.resetForm()
                        isPresentingForm = true
                    }
                    .accessibilityIdentifier("athleteManagement.addAthleteButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("athleteManagement.doneButton")
                }
            }
            .onAppear {
                viewModel.loadAthletes()
            }
            .sheet(isPresented: $isPresentingForm) {
                AthleteFormView(viewModel: viewModel, editingAthlete: editingAthlete)
            }
        }
    }

    /// Shown whenever `activeAthletes` (see `RestoredFamily`'s own
    /// property of the same name) is empty — no active athletes,
    /// whether because none was ever added or every one has been
    /// archived. The "Add" button in the toolbar above is always
    /// available regardless, so this is never a dead end.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No active athletes yet.")
                .foregroundStyle(.secondary)
            Button("Add athlete") {
                editingAthlete = nil
                viewModel.resetForm()
                isPresentingForm = true
            }
            .accessibilityIdentifier("athleteManagement.emptyStateAddButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var athleteList: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("athleteManagement.errorMessage")
                }
            }

            ForEach(viewModel.athletes, id: \.id) { athlete in
                HStack {
                    VStack(alignment: .leading) {
                        Text(athlete.givenName)
                        if athlete.isArchived {
                            Text("Archived")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !athlete.isArchived {
                        Button("Archive") {
                            viewModel.archiveAthlete(athlete)
                        }
                        .accessibilityIdentifier("athleteManagement.archiveButton.\(athlete.id.uuidString)")
                    }
                }
                .contentShape(Rectangle())
                .accessibilityIdentifier("athleteManagement.athleteRow.\(athlete.id.uuidString)")
                .onTapGesture {
                    guard !athlete.isArchived else { return }
                    editingAthlete = athlete
                    viewModel.prefill(from: athlete)
                    isPresentingForm = true
                }
            }
        }
        .accessibilityIdentifier("athleteManagement.athleteList")
    }
}

/// The create/edit form itself — one form, reused for both, matching
/// this project's established pattern (e.g.
/// `RecurringActivityFormView`) of reusing one form's fields for add
/// vs. edit rather than building two.
struct AthleteFormView: View {
    @Bindable var viewModel: AthleteFamilyManagementViewModel
    let editingAthlete: AthleteProfile?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("athleteManagement.formErrorMessage")
                    }
                }

                Section("Athlete") {
                    TextField("Given name", text: $viewModel.givenName)
                        .accessibilityIdentifier("athleteManagement.givenNameField")
                    TextField("Family name (optional)", text: $viewModel.familyName)
                        .accessibilityIdentifier("athleteManagement.familyNameField")
                    TextField("Preferred name (optional)", text: $viewModel.preferredName)
                        .accessibilityIdentifier("athleteManagement.preferredNameField")
                    DatePicker("Birth date", selection: $viewModel.birthDate, displayedComponents: .date)
                        .accessibilityIdentifier("athleteManagement.birthDatePicker")
                    Picker("Development stage", selection: $viewModel.developmentStage) {
                        Text("Parent-led").tag(DevelopmentStage.parentLed)
                        Text("Shared ownership").tag(DevelopmentStage.sharedOwnership)
                        Text("Guided independence").tag(DevelopmentStage.guidedIndependence)
                        Text("Athlete-led").tag(DevelopmentStage.athleteLed)
                    }
                    .accessibilityIdentifier("athleteManagement.developmentStagePicker")
                }
            }
            .navigationTitle(editingAthlete == nil ? "Add Athlete" : "Edit Athlete")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let succeeded: Bool
                        if let editingAthlete {
                            succeeded = viewModel.editAthlete(editingAthlete)
                        } else {
                            succeeded = viewModel.addAthlete()
                        }
                        if succeeded {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("athleteManagement.saveButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("athleteManagement.cancelButton")
                }
            }
        }
    }
}
