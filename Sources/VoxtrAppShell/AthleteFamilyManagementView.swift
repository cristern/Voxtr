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
/// (Superseded by round 8 below: a row no longer opens Athlete Home at
/// all — see that note for the current, corrected destination.) Edit
/// and Archive are now separate, explicit actions, never conflated
/// with opening the athlete.
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
///
/// Round 8 (TestFlight IA correction): round 7's separate row + Settings
/// link ("Oliver > Settings") competed for attention and made the
/// hierarchy unclear. Approved correction — Profile owns People &
/// Configuration entirely: tapping an athlete row here now opens that
/// athlete's CONFIGURATION HUB (`AthleteSettingsView`) directly, never
/// Athlete Home. Athlete Home stays reachable only through the Home
/// experience (`FamilyHomeContentView.athleteOverview(for:)`), exactly
/// as this app's own pre-round-7 architecture doc comment already
/// intended (see `FamilyHomeView`'s own doc comment: "`AthleteFamilyManagementView`
/// is deliberately administrative-only... it does not navigate into
/// Athlete Overview, and that is the intended separation, not a
/// regression to fix" — round 7 had drifted from this; this round
/// restores it). `athleteHomeDestination` is therefore removed
/// entirely — dead parameter, dead closures, and (in `FamilyHomeView`)
/// a now-dead private helper that existed only to feed it — rather
/// than left wired to an unused destination.
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
    /// This view has no reason to know how to construct
    /// `SleepCoordinationService` itself — the caller supplies the
    /// destination, reused unchanged by `AthleteSettingsView` below.
    private let sleepSettingsDestination: (AthleteProfile) -> AnyView

    public init(
        viewModel: AthleteFamilyManagementViewModel,
        presentationMode: PresentationMode,
        sleepSettingsDestination: @escaping (AthleteProfile) -> AnyView
    ) {
        _viewModel = State(initialValue: viewModel)
        self.presentationMode = presentationMode
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
                if athlete.isArchived {
                    VStack(alignment: .leading) {
                        Text(athlete.givenName)
                        Text("Archived")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("athleteManagement.athleteRow.\(athlete.id.uuidString)")
                } else {
                    // Round 8 (TestFlight IA correction): the athlete
                    // row is now the SINGLE destination — Manage
                    // Athletes is a people/configuration index, not
                    // another Athlete Home launcher, so tapping an
                    // athlete opens their configuration hub directly.
                    // No separate "Settings" action alongside it.
                    NavigationLink {
                        AthleteSettingsView(
                            viewModel: viewModel,
                            athlete: athlete,
                            sleepSettingsDestination: sleepSettingsDestination
                        )
                    } label: {
                        Text(athlete.givenName)
                    }
                    .accessibilityIdentifier("athleteManagement.athleteRow.\(athlete.id.uuidString)")
                }
            }
        }
        .accessibilityIdentifier("athleteManagement.athleteList")
    }
}

/// Round 7 (Profile / Manage Athletes IA polish), evolved in round 8
/// into the canonical ATHLETE CONFIGURATION HUB — the ONE screen
/// `AthleteFamilyManagementView`'s athlete row now opens directly (see
/// that struct's own doc comment). Owns everything that used to sit as
/// separate row actions — Profile, Sleep tracking, and destructive
/// Archive — so configuration lives in exactly one place, never
/// duplicated. Reuses the existing `AthleteFormView` sheet, the
/// caller-supplied `sleepSettingsDestination` closure, and
/// `AthleteFamilyManagementViewModel.archiveAthlete(_:)` verbatim — no
/// new configuration surface, no new persistence path, and Archive's
/// own behavior (immediate, no confirmation dialog) is unchanged.
///
/// Round 9 (TestFlight IA correction): a plain "Profile >" navigation
/// row read as an unnecessary extra hierarchy level. Approved
/// correction — the athlete's core profile facts (Name, Family name,
/// Birth date) are now shown directly, read-only, in a tappable card
/// at the top of this hub; tapping it opens the same `AthleteFormView`
/// sheet as before. This is presentation only: the values shown are
/// read straight off the SAME canonical `AthleteProfile` reference
/// this hub was handed (a SwiftData `@Model` reference type, so a
/// successful edit — which mutates that exact managed object in
/// place — is reflected here automatically on return, with no manual
/// refresh/reload needed). Development Stage moved OUT of this card —
/// it is configuration, not identity, and now sits in its own row at
/// the same level as Sleep (see the doc comment on that row below for
/// why it still opens the same edit sheet under the hood).
///
/// Each concept gets its own `Form` `Section`, Archive last and
/// visually separated — this is deliberate so a future concept (e.g.
/// Notifications, explicitly NOT implemented this round) can be added
/// as one more row without touching Manage Athletes or this hub's own
/// structure again.
struct AthleteSettingsView: View {
    @Bindable var viewModel: AthleteFamilyManagementViewModel
    let athlete: AthleteProfile
    let sleepSettingsDestination: (AthleteProfile) -> AnyView
    @State private var isPresentingForm: Bool = false

    var body: some View {
        Form {
            // PROFILE CARD — identity/profile facts only (Name, Family
            // name, Birth date), reused directly off `athlete`, never a
            // second copy of this data. Tapping anywhere on the card
            // opens the existing Edit Athlete form.
            Section {
                Button {
                    viewModel.prefill(from: athlete)
                    isPresentingForm = true
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 12) {
                            profileField(label: "Name", value: athlete.givenName)
                            // "Not set" matches this app's own existing
                            // vocabulary for an absent optional value
                            // (see `OptionalDurationPickerView`'s "Not
                            // set" row) — calm, not a fabricated name.
                            profileField(label: "Family name", value: athlete.familyName ?? "Not set")
                            profileField(label: "Birth date", value: AthleteBirthDateFormatter.label(for: athlete.birthDate))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("athleteSettings.profileCard.\(athlete.id.uuidString)")
            }

            // Configuration — deliberately separate from the identity
            // facts above (see this hub's own doc comment). Development
            // Stage has no dedicated edit screen of its own; the
            // smallest existing canonical mechanism that already
            // supports editing it is the very same `AthleteFormView`
            // the Profile card above opens, so this row reuses that
            // sheet rather than inventing a new, separate
            // Development-Stage-only edit surface this round wasn't
            // asked to build. Reported as a known tradeoff, not a
            // silent shortcut: opening either row currently shows the
            // same full form.
            Section {
                Button {
                    viewModel.prefill(from: athlete)
                    isPresentingForm = true
                } label: {
                    HStack {
                        Text("Development stage")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("athleteSettings.developmentStageButton.\(athlete.id.uuidString)")

                NavigationLink("Sleep") {
                    sleepSettingsDestination(athlete)
                }
                .accessibilityIdentifier("athleteSettings.sleepLink.\(athlete.id.uuidString)")
            }

            // Destructive, visually separated in its own trailing
            // Section — matches this screen's own "Archive preferably
            // at the bottom" requirement without any fixed geometry.
            Section {
                Button("Archive athlete", role: .destructive) {
                    viewModel.archiveAthlete(athlete)
                }
                .accessibilityIdentifier("athleteSettings.archiveButton.\(athlete.id.uuidString)")
            }
        }
        .navigationTitle(athlete.givenName)
        .sheet(isPresented: $isPresentingForm) {
            AthleteFormView(viewModel: viewModel, editingAthlete: athlete)
        }
    }

    private func profileField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
    }
}

/// TestFlight IA correction (Athlete configuration hub): "day Month
/// year" formatting for the read-only birth date on the Profile card —
/// same locale-independent technique `SleepHistoryDateFormatter`/
/// `WeekIdentityFormatter` already establish elsewhere in this app (a
/// fresh `DateFormatter` supplies only the calendar's month-name
/// table; the day/year digits always come from `LocalDate`'s own
/// stored `Int`s, never `Calendar.current`) — extended here to the one
/// shape neither of those existing formatters produces (an absolute
/// date with its year), not a new, unrelated convention.
enum AthleteBirthDateFormatter {
    static func label(for localDate: LocalDate) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        let month = formatter.monthSymbols[localDate.month - 1]
        return "\(localDate.day) \(month) \(localDate.year)"
    }
}

/// The create/edit form itself — one form, reused for both, matching
/// this project's established pattern (e.g.
/// `RecurringActivityFormView`) of reusing one form's fields for add
/// vs. edit rather than building two.
///
/// TestFlight simplification round: "Preferred name" is removed from
/// this UI — approved V1 editable profile fields are Name, Family name
/// (optional), and Birth date only. `AthleteProfile.preferredName` IS a
/// persisted field (confirmed by inspecting `AthleteEntities.swift`),
/// so this is deliberately UI-only: no schema change, no data deletion.
/// `AthleteFamilyManagementViewModel.preferredName`/`prefill(from:)`/
/// `editAthlete(_:)`/`addAthlete()` are left completely unchanged —
/// `prefill(from:)` still captures an existing athlete's persisted
/// `preferredName` into that ViewModel field even though no control
/// here edits it, so a Save with this field simply absent from the UI
/// round-trips the athlete's existing value unchanged rather than
/// erasing it (a new athlete added through this form gets `nil`,
/// exactly as if a user had left the old optional field blank). The
/// underlying `preferredName` column itself is retained as
/// technical/domain cleanup debt — reported, not touched, this round.
///
/// This form is also reused, unchanged, as the destination for BOTH
/// the athlete configuration hub's "Profile" card AND its "Development
/// stage" row (see `AthleteSettingsView` above) — there is no separate,
/// dedicated Development-Stage-only edit screen, and this round's
/// instructions explicitly call for reusing "the smallest existing
/// canonical presentation/edit pattern if already supported" rather
/// than inventing one. This is a deliberate, reported tradeoff (see
/// this task's delivery report): opening either entry point currently
/// shows this same full form, Development Stage picker included.
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
