import SwiftUI
import VoxtrCoreContracts
import VoxtrAthleteDomain

/// Multi-Athlete Family Foundation. The minimum UI this work package
/// asks for: list every athlete, add, edit, archive/delete, and a
/// clear empty state when there are no active athletes. Deliberately
/// plain — no visual redesign, matching this work package's own
/// constraint.
///
/// Sprint 1 completion package, Item 2 & the nested-NavigationStack
/// fix: this view previously (a) opened Edit directly on row tap, with
/// no way to reach Athlete Home from here at all, and (b) always
/// wrapped itself in its own `NavigationStack` — which was already
/// silently broken for one of its three real call sites
/// (`FamilyHomeContentView`'s `.manageAthletes` destination, which
/// pushes this view WITHIN an already-existing `NavigationStack`,
/// where nesting another one breaks navigation the same way
/// `HomeDashboardView`'s own former `NavigationStack` did before that
/// fix). Both are corrected together: this view no longer wraps itself
/// in a `NavigationStack` at all — each of its three call sites now
/// supplies one only where it's genuinely needed (root-level
/// presentation when zero athletes exist, or a sheet presentation),
/// and never where it isn't (a pushed destination already inside one).
/// Tapping a row now pushes `athleteHomeDestination(athlete)` — the
/// SAME canonical Athlete Home (`HomeDashboardView`) every other
/// surface uses, supplied by the caller rather than duplicated here,
/// since this view has no reason to know about the 6+ services that
/// screen needs. Edit and Archive are now separate, explicit actions,
/// never conflated with opening the athlete.
public struct AthleteFamilyManagementView: View {
    @State private var viewModel: AthleteFamilyManagementViewModel
    @State private var isPresentingForm: Bool = false
    @State private var editingAthlete: AthleteProfile?
    @Environment(\.dismiss) private var dismiss
    private let athleteHomeDestination: (AthleteProfile) -> AnyView

    public init(
        viewModel: AthleteFamilyManagementViewModel,
        athleteHomeDestination: @escaping (AthleteProfile) -> AnyView
    ) {
        _viewModel = State(initialValue: viewModel)
        self.athleteHomeDestination = athleteHomeDestination
    }

    public var body: some View {
        Group {
            if viewModel.athletes.filter({ !$0.isArchived }).isEmpty {
                emptyState
            } else {
                athleteList
            }
        }
        .navigationTitle("Manage Athletes")
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
                    if athlete.isArchived {
                        VStack(alignment: .leading) {
                            Text(athlete.givenName)
                            Text("Archived")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // A. Open athlete — pushes the SAME canonical
                        // "<Athlete Name> Home" every other surface
                        // uses. Archived athletes have no Home to open.
                        NavigationLink {
                            athleteHomeDestination(athlete)
                        } label: {
                            Text(athlete.givenName)
                        }
                        .accessibilityIdentifier("athleteManagement.openButton.\(athlete.id.uuidString)")
                    }
                    Spacer()
                    if !athlete.isArchived {
                        // B. Edit athlete — a distinct, explicit action,
                        // never conflated with opening the athlete.
                        Button("Edit") {
                            editingAthlete = athlete
                            viewModel.prefill(from: athlete)
                            isPresentingForm = true
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("athleteManagement.editButton.\(athlete.id.uuidString)")

                        // C. Archive/remove athlete — unchanged
                        // archive behavior and confirmation.
                        Button("Archive") {
                            viewModel.archiveAthlete(athlete)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("athleteManagement.archiveButton.\(athlete.id.uuidString)")
                    }
                }
                .accessibilityIdentifier("athleteManagement.athleteRow.\(athlete.id.uuidString)")
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
