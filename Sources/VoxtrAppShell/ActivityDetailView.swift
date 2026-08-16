import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain

/// Sprint 1 (Daily Use Foundation), Part 3.
///
/// Review follow-up (Planned/Logged Activity lifecycle consistency
/// cleanup): the one clear UX contract for every edit/correction action
/// this screen offers, and exactly which canonical entity each one
/// mutates — never two ambiguously-named "Edit" actions:
/// - **"Edit Planned Activity"** (shown while `canEditOrDelete`, i.e.
///   the WeekPlan is still `.draft`) edits the historical PLAN only —
///   `PlannedActivity` (title, activity type, planned date, planned
///   start time, planned duration, notes, location), via
///   `PlanningService.editPlannedActivity`. This remains available even
///   after the activity has been logged, as long as the plan itself is
///   still a draft — editing the plan does NOT change what was actually
///   logged.
/// - **"Log Activity"** (shown before any outcome is resolved) CREATES
///   the `LoggedActivity` (and, if Form was entered, the linked
///   `ActivityReflection`) via `TrainingReflectionCoordinationService.logActivity`.
/// - **"Cancel Activity"** (shown before any outcome is resolved) also
///   CREATES a `LoggedActivity`, with canonical status `.cancelled` —
///   the same creation path as Log Activity, just a different outcome.
/// - **"Edit Logged Activity"** (shown once a `LoggedActivity` exists,
///   regardless of outcome) CORRECTS the actual, already-recorded
///   result — `LoggedActivity.durationMinutes`/`.perceivedExertion` and
///   the linked `ActivityReflection.bodyFeeling`, via
///   `TrainingReflectionCoordinationService.correctLoggedActivity`. This
///   is the ONLY action that touches `LoggedActivity`/`ActivityReflection`
///   after they exist — see `LoggedActivityEditFormView`'s own doc
///   comment.
public struct ActivityDetailView: View {
    @State private var viewModel: ActivityDetailViewModel
    @State private var isEditing: Bool = false
    @State private var isLogging: Bool = false
    @State private var isPresentingDeleteConfirmation: Bool = false
    @State private var isPresentingCancelConfirmation: Bool = false
    @State private var isEditingLoggedActivity: Bool = false
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
                LabeledContent("Status", value: statusText)
                    .accessibilityIdentifier("activityDetail.statusRow")
                // VX-022 closeout: factual training data actually
                // recorded — RPE from the canonical LoggedActivity
                // field, Form from ActivityReflection.bodyFeeling for
                // this exact LoggedActivity. Shown only when a value
                // exists; no interpretation, no color, no scoring.
                if let rpe = viewModel.perceivedExertion {
                    LabeledContent("RPE", value: "\(rpe) / 10")
                        .accessibilityIdentifier("activityDetail.rpeRow")
                }
                if let form = viewModel.formValue {
                    LabeledContent("Form", value: "\(form) / 5")
                        .accessibilityIdentifier("activityDetail.formRow")
                }
            }
            .accessibilityIdentifier("activityDetail.summary")

            Section {
                if viewModel.outcomeStatus != nil {
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
                    //
                    // Planned/Logged Activity lifecycle consistency
                    // cleanup: now driven by `outcomeStatus` (the
                    // canonical `LoggedActivity.status`), not the old
                    // binary `isCompleted`, so Cancelled is shown
                    // distinctly rather than as "Logged".
                    Label(statusText, systemImage: outcomeIndicatorSystemImage)
                        .foregroundStyle(outcomeIndicatorColor)
                        .accessibilityIdentifier("activityDetail.loggedIndicator")
                } else {
                    Button("Log Activity") {
                        isLogging = true
                    }
                    .accessibilityIdentifier("activityDetail.logActivityButton")
                }

                if viewModel.canEditLoggedActivity {
                    Button("Edit Logged Activity") {
                        viewModel.prefillLoggedActivityEditForm()
                        isEditingLoggedActivity = true
                    }
                    .accessibilityIdentifier("activityDetail.editLoggedActivityButton")

                    // Review follow-up: only shown when BOTH actions
                    // are simultaneously visible — the one moment the
                    // distinction actually needs spelling out for the
                    // person looking at the screen, not only in code
                    // comments.
                    if viewModel.canEditOrDelete {
                        Text("Editing the plan below does not change what was actually logged — use Edit Logged Activity to correct the result.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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

                // Planned/Logged Activity lifecycle consistency cleanup:
                // Cancel is a training-time determination, never gated
                // by the plan's draft/committed state (unlike Edit/
                // Delete above) — only by whether an outcome has
                // already been resolved (`canCancel`).
                if viewModel.canCancel {
                    Button("Cancel Activity", role: .destructive) {
                        isPresentingCancelConfirmation = true
                    }
                    .accessibilityIdentifier("activityDetail.cancelActivityButton")
                }
            }
        }
        .navigationTitle(viewModel.activity.title)
        .sheet(isPresented: $isEditing) {
            ActivityEditFormView(viewModel: viewModel)
        }
        .sheet(isPresented: $isEditingLoggedActivity) {
            LoggedActivityEditFormView(viewModel: viewModel)
        }
        .sheet(isPresented: $isLogging) {
            // Athlete Home stale-state fix, single-owner closeout:
            // `onDismiss` fires this screen's own dismiss()
            // SYNCHRONOUSLY, in the same `onLogged` closure that fires
            // `onActivityLogged()` — the moment a save genuinely
            // succeeds. This is the ONE place a successful log
            // dismisses this screen: `isCompleted` is `private(set)`
            // with exactly one mutation site in the whole codebase
            // (this same `onLogged` closure, inside
            // `makeLogActivityViewModel`), so there is no other
            // false->true transition a second, independent `.onChange`
            // observer could ever legitimately fire on — keeping one
            // here as well would just be two triggers racing to dismiss
            // the same screen for the same event. A successful log
            // therefore causes at most one dismiss() call.
            LogActivityView(viewModel: viewModel.makeLogActivityViewModel(onDismiss: { dismiss() }))
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
        .confirmationDialog(
            "Cancel this activity?",
            isPresented: $isPresentingCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Activity", role: .destructive) {
                viewModel.cancelActivity()
            }
            Button("Keep", role: .cancel) {}
        }
    }

    /// Planned/Logged Activity lifecycle consistency cleanup: the
    /// user-facing status text, driven entirely by the canonical
    /// `outcomeStatus` (`LoggedActivity.status`) rather than the old
    /// binary `isCompleted` — so Cancelled/Missed/Partially completed
    /// are all shown distinctly, not collapsed into "Completed".
    private var statusText: String {
        switch viewModel.outcomeStatus {
        case .none, .scheduled: return "Ready to log"
        case .completed: return "Completed"
        case .partiallyCompleted: return "Partially completed"
        case .missed: return "Missed"
        case .cancelled: return "Cancelled"
        }
    }

    private var outcomeIndicatorSystemImage: String {
        switch viewModel.outcomeStatus {
        case .completed, .partiallyCompleted: return "checkmark.circle.fill"
        case .missed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .none, .scheduled: return "circle"
        }
    }

    private var outcomeIndicatorColor: Color {
        switch viewModel.outcomeStatus {
        case .completed, .partiallyCompleted: return .green
        case .missed: return .orange
        case .cancelled: return .secondary
        case .none, .scheduled: return .primary
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

/// Planned/Logged Activity lifecycle consistency cleanup (Edit Logged
/// Activity -> RPE + Form), extended by review follow-up to also
/// correct actual duration: a separate sheet, matching
/// `ActivityEditFormView`'s own established shape, reusing
/// `ActivityDetailViewModel`'s own edit fields directly (no duplicate
/// editing logic). Loads the exact canonical duration/RPE/Form values
/// already displayed read-only on the parent screen (via
/// `prefillLoggedActivityEditForm()`, called before this sheet is
/// presented) and writes back through
/// `TrainingReflectionCoordinationService.correctLoggedActivity` (via
/// `saveLoggedActivityEdit()`) — never a second, locally-tracked
/// duration/status/form field.
///
/// This is the ONLY place actual (logged) duration, RPE, or Form can be
/// corrected after logging — distinct from "Edit Planned Activity"
/// above, which only ever edits the historical PLAN (title/date/type/
/// planned start time/planned duration/notes/location) and never
/// touches `LoggedActivity`/`ActivityReflection` at all. See
/// `ActivityDetailView`'s own doc comment for the full action/entity
/// mapping.
struct LoggedActivityEditFormView: View {
    @Bindable var viewModel: ActivityDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("activityDetail.editLoggedActivity.errorMessage")
                    }
                }

                Section {
                    // Review follow-up: only offered for outcomes where
                    // actual duration is meaningful (Completed/Partially
                    // completed) — `canEditLoggedDuration` mirrors the
                    // exact same rule `TrainingValidator.requiresActualDuration(for:)`
                    // applies at initial logging. Hidden entirely for
                    // Missed/Cancelled, where the stored value is only
                    // the schema's "nothing to measure" placeholder.
                    if viewModel.canEditLoggedDuration {
                        DurationPickerView(durationMinutes: $viewModel.editLoggedDurationMinutes)
                    }

                    Picker("RPE", selection: $viewModel.editLoggedPerceivedExertion) {
                        Text("Not set").tag(Int?.none)
                        ForEach(1...10, id: \.self) { value in
                            Text("\(value)").tag(Int?.some(value))
                        }
                    }
                    .accessibilityIdentifier("activityDetail.editLoggedActivity.rpePicker")

                    // Same neutral 1-5 "Form" scale as logging itself
                    // (`LogActivityView`'s `sessionFormPicker`), but
                    // WITH a "Not set" option here (unlike that initial
                    // logging picker) — the sheet may OPEN on "Not set"
                    // (a legacy activity with no historical Form value).
                    // Review follow-up: this does NOT mean Form can
                    // actually be saved as unset for an outcome that
                    // requires it — `saveLoggedActivityEdit()` runs the
                    // EXACT SAME `TrainingValidator.validateForm(_:for:)`
                    // rule initial logging uses, keyed off this
                    // activity's own canonical status, and blocks Save
                    // (never silently clears the canonical value) until
                    // a real value is chosen whenever Form is required.
                    Picker("Form", selection: $viewModel.editLoggedSessionForm) {
                        Text("Not set").tag(Int?.none)
                        ForEach(1...5, id: \.self) { value in
                            Text("\(value)").tag(Int?.some(value))
                        }
                    }
                    .accessibilityIdentifier("activityDetail.editLoggedActivity.sessionFormPicker")
                }
            }
            .navigationTitle("Edit Logged Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if viewModel.saveLoggedActivityEdit() {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("activityDetail.editLoggedActivity.saveButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("activityDetail.editLoggedActivity.cancelButton")
                }
            }
        }
    }
}
