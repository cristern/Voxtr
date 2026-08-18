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
///
/// Round 7 (Profile / Manage Athletes IA polish): Manage Athletes now
/// owns ONLY athlete identity + navigation into Athlete Home. Every
/// other per-athlete action (Edit, Sleep, Archive) moved off the row
/// and into the new `AthleteSettingsView` below, reached through a
/// single "Settings" secondary action — so the row/name tap can never
/// accidentally route into Sleep Settings, and configuration is never
/// duplicated across two surfaces.
///
/// Round 7 review correction: the "Done" button was first removed
/// outright, on the reasoning that swipe-to-dismiss remains available
/// wherever this view is shown as a `.sheet`. That's true, but it
/// treats an intentionally modal presentation
/// (`HomeDashboardView`'s "Manage Athletes" sheet) the same as normal
/// pushed `NavigationStack` content (`ParentTabShellView`'s Profile
/// tab, `FamilyHomeView`'s zero-athletes root) — an intentionally
/// modal screen shouldn't rely on gesture-only dismissal. Rather than
/// have this view infer its own presentation context from the
/// environment, each of the three call sites now states it explicitly
/// via `presentationMode`: `.navigation` (no Done — normal
/// NavigationStack/back behavior) for the two pushed sites, `.modal`
/// (explicit Done, calling `dismiss()`) for the one real sheet.
public struct AthleteFamilyManagementView: View {
    /// How this view is being presented — set explicitly by the
    /// caller at each construction site, never inferred. `.modal`
    /// is the only case that shows a Done control; `.navigation`
    /// participates in ordinary NavigationStack/back navigation with
    /// no artificial completion control of its own.
    public enum PresentationMode: Equatable {
        case navigation
        case modal
    }

    @State private var viewModel: AthleteFamilyManagementViewModel
    @State private var isPresentingForm: Bool = false
    @State private var editingAthlete: AthleteProfile?
    @Environment(\.dismiss) private var dismiss
    private let presentationMode: PresentationMode
    private let athleteHomeDestination: (AthleteProfile) -> AnyView
    /// VX-023 (Sleep V1): same caller-supplied-destination shape as
    /// `athleteHomeDestination` above — this view has no reason to know
    /// how to construct `SleepCoordinationService` itself.
    private let sleepSettingsDestination: (AthleteProfile) -> AnyView

    public init(
        viewModel: AthleteFamilyManagementViewModel,
        presentationMode: PresentationMode,
        athleteHomeDestination: @escaping (AthleteProfile) -> AnyView,
        sleepSettingsDestination: @escaping (AthleteProfile) -> AnyView
    ) {
        _viewModel = State(initialValue: viewModel)
        self.presentationMode = presentationMode
        self.athleteHomeDestination = athleteHomeDestination
        self.sleepSettingsDestination = sleepSettingsDestination
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
            if presentationMode == .modal {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("athleteManagement.doneButton")
                }
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
                        // Round 7: Settings is the ONE secondary action
                        // on the row — Edit, Sleep, and Archive all
                        // live inside it now, never directly on the row
                        // itself, so the row/name tap stays the sole
                        // path into Athlete Home.
                        NavigationLink("Settings") {
                            AthleteSettingsView(
                                viewModel: viewModel,
                                athlete: athlete,
                                sleepSettingsDestination: sleepSettingsDestination
                            )
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("athleteManagement.settingsButton.\(athlete.id.uuidString)")
                    }
                }
                .accessibilityIdentifier("athleteManagement.athleteRow.\(athlete.id.uuidString)")
            }
        }
        .accessibilityIdentifier("athleteManagement.athleteList")
    }
}

/// Round 7 (Profile / Manage Athletes IA polish): the ONE canonical
/// per-athlete configuration screen. Manage Athletes' row now owns
/// only identity + navigation into Athlete Home (see the doc comment
/// above `AthleteFamilyManagementView`); this screen owns everything
/// that used to sit as separate row actions — Edit profile, Sleep
/// tracking, and destructive Archive — so configuration lives in
/// exactly one place, never duplicated across both surfaces. Reuses
/// the existing `AthleteFormView` sheet, the caller-supplied
/// `sleepSettingsDestination` closure, and
/// `AthleteFamilyManagementViewModel.archiveAthlete(_:)` verbatim — no
/// new configuration surface, no new persistence path, and Archive's
/// own behavior (immediate, no confirmation dialog) is unchanged; only
/// its location moved here from the row.
struct AthleteSettingsView: View {
    @Bindable var viewModel: AthleteFamilyManagementViewModel
    let athlete: AthleteProfile
    let sleepSettingsDestination: (AthleteProfile) -> AnyView
    @State private var isPresentingForm: Bool = false

    var body: some View {
        Form {
            Section {
                Button("Edit Profile") {
                    viewModel.prefill(from: athlete)
                    isPresentingForm = true
                }
                .accessibilityIdentifier("athleteSettings.editProfileButton.\(athlete.id.uuidString)")
            }

            Section {
                NavigationLink("Sleep") {
                    sleepSettingsDestination(athlete)
                }
                .accessibilityIdentifier("athleteSettings.sleepLink.\(athlete.id.uuidString)")
            }

            // Destructive, visually separated in its own trailing
            // Section — matches this screen's own "Archive preferably
            // at the bottom" requirement without any fixed geometry.
            Section {
                Button("Archive Athlete", role: .destructive) {
                    viewModel.archiveAthlete(athlete)
                }
                .accessibilityIdentifier("athleteSettings.archiveButton.\(athlete.id.uuidString)")
            }
        }
        .navigationTitle("\(athlete.givenName) Settings")
        .sheet(isPresented: $isPresentingForm) {
            AthleteFormView(viewModel: viewModel, editingAthlete: athlete)
        }
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
