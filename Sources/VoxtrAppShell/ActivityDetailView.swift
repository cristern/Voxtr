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
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: ActivityDetailViewModel
    @State private var isEditing: Bool = false
    @State private var isLogging: Bool = false
    @State private var isPresentingDeleteConfirmation: Bool = false
    @State private var isPresentingCancelConfirmation: Bool = false
    @State private var isEditingLoggedActivity: Bool = false
    @State private var isPresentingSplit: Bool = false
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: ActivityDetailViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        // P0 crash fix: once `deleteActivity()` succeeds, `viewModel.activity`
        // refers to a SwiftData `@Model` instance already hard-deleted
        // from the persistent store (`PlanningRepository.deletePlannedActivity`
        // calls `modelContext.delete(activity)` then `save()`) — reading
        // ANY of its properties afterward (`.title`, `.localDate`,
        // `.startLocalTime`, `.location`, `.notes`, all read directly
        // below and in `.navigationTitle`) is a fatal SwiftData runtime
        // crash, not a catchable Swift error. `dismiss()` does not
        // synchronously tear this view down: `deleteActivity()`'s own
        // `errorMessage`/`isDeleted` mutations, plus the enclosing
        // `.confirmationDialog`'s own dismissal, both drive at least one
        // more `body` evaluation before the NavigationStack pop actually
        // completes — ordinary SwiftUI dismiss-transition behavior, not
        // something this screen can suppress. `isDeleted` already
        // existed on `ActivityDetailViewModel` for exactly this signal;
        // it was set but never consulted here. Checked first, before
        // anything below ever touches `viewModel.activity`.
        if viewModel.isDeleted {
            EmptyView()
        } else {
            activityDetailForm
        }
    }

    private var activityDetailForm: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("activityDetail.errorMessage")
                }
                .voxtrRowSurface()
            }

            Section {
                LabeledContent("Athlete", value: viewModel.athleteDisplayName)
                LabeledContent("Activity", value: ActivityLabelResolver(modelContext: modelContext).primaryLabel(for: viewModel.activity))
                LabeledContent("Identity", value: ActivityLabelResolver(modelContext: modelContext).metadataLabel(for: viewModel.activity))
                LabeledContent("Date", value: viewModel.activity.localDate.isoString)
                if let timeLabel = viewModel.plannedTimeRangeLabel {
                    LabeledContent("Time", value: timeLabel)
                }
                if let durationLabel = viewModel.plannedDurationLabel {
                    LabeledContent("Duration", value: durationLabel)
                        .accessibilityIdentifier("activityDetail.plannedDurationRow")
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
            .voxtrRowSurface()
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

                    // Reversibility principle: offered ONLY for a
                    // .cancelled outcome (`canReopen`) — never
                    // Completed/PartiallyCompleted/Missed. Deliberately
                    // NOT "Edit cancellation" — this undoes the lifecycle
                    // outcome entirely, returning the activity to
                    // unresolved, not editing details of the
                    // cancellation itself.
                    if viewModel.canReopen {
                        Button("Reopen Activity") {
                            viewModel.reopenActivity()
                        }
                        .accessibilityIdentifier("activityDetail.reopenActivityButton")
                    }
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
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
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
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
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
            .voxtrRowSurface()
        }
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle(ActivityLabelResolver(modelContext: modelContext).primaryLabel(for: viewModel.activity))
        .sheet(isPresented: $isEditing) {
            ActivityEditFormView(viewModel: viewModel, isPresentingSplit: $isPresentingSplit)
        }
        .sheet(isPresented: $isEditingLoggedActivity) {
            LoggedActivityEditFormView(viewModel: viewModel)
        }
        // Activity Edit -> Split Activity: a SIBLING sheet to `isEditing`
        // above, not nested inside it — `ActivityEditFormView`'s own
        // "Split Activity" button dismisses that sheet and flips this
        // flag in the same action (see its own doc comment). `onDismiss`
        // reads `viewModel.didSplitSuccessfully` — the explicit success
        // signal set only inside `splitActivity()` — to decide whether
        // to ALSO pop this whole screen back to the list the split's new
        // sibling activities are now visible in; tapping "Cancel" inside
        // the split form (never setting that flag) just closes this
        // sheet and leaves `ActivityDetailView` showing the unchanged
        // activity, the same as any other cancelled edit.
        .sheet(isPresented: $isPresentingSplit, onDismiss: {
            if viewModel.didSplitSuccessfully {
                dismiss()
            }
        }) {
            SplitActivityFormView(viewModel: viewModel)
        }
        .sheet(isPresented: $isLogging) {
            // TestFlight closeout: logging is an in-context correction/
            // update flow — a successful Save dismisses ONLY this sheet
            // (`LogActivityView`'s own `@Environment(\.dismiss)`, called
            // from its Save button once `save()` returns `true`).
            // `ActivityDetailView` itself never dismisses in response to
            // a log; `makeLogActivityViewModel()`'s own `onLogged`
            // closure already refreshes `loggedActivity`/
            // `activityReflection` from canonical state before the sheet
            // closes, so this screen shows the real logged outcome the
            // moment it becomes visible again — see that method's own
            // doc comment for the full reasoning.
            LogActivityView(viewModel: viewModel.makeLogActivityViewModel())
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

    // Status/outcome colour audit (Design Foundation extension round):
    // `.green`/`.orange` are kept as the literal, already-established
    // semantic "genuinely completed"/"missed" colours — the same
    // meaning `DailyTrainingView`'s own completed-label colouring
    // already uses. `VoxtrColor` has no status/outcome token, and this
    // task explicitly forbids inventing one or silently remapping these
    // onto an unrelated accent/athlete colour, so they stay literal
    // system colours. Only the two NEUTRAL cases (`.secondary`/`.primary`)
    // move to the direct `VoxtrColor` token equivalents already used
    // everywhere else on this screen — see this round's own delivery
    // report for a note on whether a future small semantic-status token
    // pair would be worth adding.
    private var outcomeIndicatorColor: Color {
        switch viewModel.outcomeStatus {
        case .completed, .partiallyCompleted: return .green
        case .missed: return .orange
        case .cancelled: return VoxtrColor.textSecondary
        case .none, .scheduled: return VoxtrColor.textPrimary
        }
    }
}

/// The edit form — a separate sheet, reusing
/// `ActivityDetailViewModel`'s own edit fields directly (no duplicate
/// editing logic, matching this work's own constraint).
struct ActivityEditFormView: View {
    @Bindable var viewModel: ActivityDetailViewModel
    @Binding var isPresentingSplit: Bool
    @Environment(\.dismiss) private var dismiss

    private var availableActivityTypes: [ActivityType] {
        if viewModel.activity.activityType == .physicalTraining {
            return [.physicalTraining] + ActivityType.selectableCases
        } else {
            return ActivityType.selectableCases
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("activityDetail.editErrorMessage")
                }
                ActivityIdentityInputView(
                    sportId: $viewModel.editSportId,
                    activityType: $viewModel.editActivityType,
                    activityName: $viewModel.editTitle,
                    availableActivityTypes: availableActivityTypes,
                    accessibilityPrefix: "activityDetail.edit"
                )
                DatePicker("Date", selection: $viewModel.editDate, displayedComponents: .date)
                    .accessibilityIdentifier("activityDetail.editDatePicker")

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

                reminderSection

                structuralActionsSection
            }
            .voxtrScreenBackground()
            .tint(VoxtrColor.accent)
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

    /// Activity Reminder What/When: Reminders are deliberately NOT wired
    /// to this sheet's own "Save" button — every row's own commit
    /// mutates canonical reminder intent immediately, through
    /// `ActivityDetailViewModel.commitReminder(_:)`, the same
    /// "decoupled from Save, fires immediately" design the rest of this
    /// screen's actions (Cancel, Delete, Log) already use. Gated on
    /// `viewModel.canSetReminder` — the CANONICAL, already-saved
    /// `activity.startLocalTime`, not this form's own in-progress edit
    /// draft — so a start time added in this same session becomes
    /// available for reminders only once Save has actually persisted
    /// it, never a moment earlier as if it already existed.
    @ViewBuilder
    private var reminderSection: some View {
        Section {
            ActivityReminderListEditorView(
                reminders: $viewModel.reminders,
                isAvailable: viewModel.canSetReminder,
                recentTextSuggestions: viewModel.recentReminderTextSuggestions,
                isUpdating: viewModel.reminderListIsUpdating,
                onCommit: { viewModel.commitReminder($0) },
                onRemove: { viewModel.removeReminder($0) },
                onAdd: { viewModel.addReminder() }
            )
        } header: {
            VoxtrSectionHeading("Reminders")
        }
    }

    /// Activity Edit -> Split Activity: a clearly SEPARATE, structural
    /// section, deliberately placed last — never alongside title/date/
    /// duration/notes/location/reminders above, so Split does not read
    /// as just another field on this form. Calm wording ("Split
    /// Activity", not destructive-red) since this is a restructuring,
    /// approved correction of Planning truth, not a destructive action
    /// in the sense Delete/Cancel are.
    ///
    /// Tapping it dismisses THIS sheet and asks the presenting
    /// `ActivityDetailView` to open the Split editor next (via
    /// `isPresentingSplit`, a `@Binding` it owns) — a flat sibling-sheet
    /// hand-off, matching how `isEditing`/`isLogging`/
    /// `isEditingLoggedActivity` already sit side by side on that same
    /// screen, rather than nesting a second sheet inside this one.
    @ViewBuilder
    private var structuralActionsSection: some View {
        Section {
            if viewModel.canSplit {
                Button("Split Activity") {
                    viewModel.beginSplit()
                    isPresentingSplit = true
                    dismiss()
                }
                .accessibilityIdentifier("activityDetail.edit.splitActivityButton")
            } else {
                Text(PlanningStrings.splitBlockedByLoggedActivity)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
        } header: {
            VoxtrSectionHeading("Structural Actions")
        }
    }
}

/// Activity Edit -> Split Activity: lets a Parent carve one
/// already-persisted `PlannedActivity` into `splitChildren.count`
/// activities. A separate sheet, presented as a SIBLING of
/// `ActivityEditFormView` (never nested inside it) from
/// `ActivityDetailView` — see that view's own `isPresentingSplit`
/// wiring. Reuses `ActivityDetailViewModel`'s own split draft/commit
/// methods directly (`splitChildren`/`addSplitChild`/`removeSplitChild`/
/// `splitActivity()`) — no duplicated validation, no direct repository
/// access from this view.
struct SplitActivityFormView: View {
    @Bindable var viewModel: ActivityDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("activityDetail.split.errorMessage")
                    }
                    .voxtrRowSurface()
                }

                ForEach($viewModel.splitChildren) { $child in
                    Section {
                        Picker("Activity Type", selection: $child.activityType) {
                            ForEach(ActivityType.selectableCases, id: \.self) { activityType in
                                Text(activityType.displayName).tag(activityType)
                            }
                        }
                        Stepper(
                            "Starts \(child.startOffsetMinutes) min after original start",
                            value: $child.startOffsetMinutes,
                            in: 0...1439,
                            step: 5
                        )
                        DurationPickerView(durationMinutes: $child.durationMinutes)

                        if viewModel.splitChildren.count > 2 {
                            Button("Remove", role: .destructive) {
                                viewModel.removeSplitChild(child.id)
                            }
                            .accessibilityIdentifier("activityDetail.split.removeChildButton")
                        }
                    }
                    .voxtrRowSurface()
                }

                Section {
                    Button("Add Another") {
                        viewModel.addSplitChild()
                    }
                    .accessibilityIdentifier("activityDetail.split.addChildButton")
                }
                .voxtrRowSurface()
            }
            .voxtrScreenBackground()
            .tint(VoxtrColor.accent)
            .navigationTitle("Split Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Split") {
                        if viewModel.splitActivity() {
                            dismiss()
                        }
                    }
                    .disabled(!viewModel.canConfirmSplit)
                    .accessibilityIdentifier("activityDetail.split.confirmButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("activityDetail.split.cancelButton")
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
                    .voxtrRowSurface()
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
                .voxtrRowSurface()
            }
            .voxtrScreenBackground()
            .tint(VoxtrColor.accent)
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
