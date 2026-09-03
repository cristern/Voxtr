import SwiftUI
import UIKit
import VoxtrCoreContracts
import VoxtrPlanningDomain

/// S2.4: first functional Weekly Planning UI. Deliberately unpolished —
/// design polish is explicitly out of scope. All state changes go
/// through `WeeklyPlanningViewModel`, which itself only calls
/// `PlanningService` — this view holds no business logic.
///
/// S2.5: added the activity-type picker to both the add form and the
/// edit sheet. `WeeklyPlanningViewModel.newActivityType` and
/// `editActivity(...activityType:)` already existed since S2.4 — the
/// view simply never exposed a control for them (the add form silently
/// used the default, and edit always passed the unchanged type back).
/// This completes existing declared capability; it doesn't add any.
/// Also completed accessibility identifiers on every control that was
/// missing one (delete/cancel buttons, per-row identifiers, both
/// activity-type pickers).
public struct WeeklyPlanningView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: WeeklyPlanningViewModel
    @State private var isManagingRecurringActivities: Bool = false
    @State private var isPresentingReopenPlanningConfirmation: Bool = false
    private let athleteDisplayName: String
    private let planningService: PlanningService
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    private let notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService
    private let actorId: ActorId

    public init(
        viewModel: WeeklyPlanningViewModel,
        athleteDisplayName: String,
        planningService: PlanningService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        actorId: ActorId
    ) {
        _viewModel = State(initialValue: viewModel)
        self.athleteDisplayName = athleteDisplayName
        self.planningService = planningService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.notificationsPlanningCoordinationService = notificationsPlanningCoordinationService
        self.actorId = actorId
    }

    public var body: some View {
        ScrollViewReader { proxy in
        Form {
            // TestFlight fix (empty white card above week identity):
            // the scroll-to-top anchor used to be a standalone
            // `Color.clear` row directly in the Form, not wrapped in
            // any `Section` — SwiftUI's grouped Form style renders any
            // top-level content outside a `Section` in its own
            // implicit boxed row, so that zero-height anchor still
            // produced a visible empty card above the week identity
            // bar. Fixed by dropping the standalone row and attaching
            // the same `"weeklyPlanning.top"` id directly to the week
            // identity `Section` below instead — `proxy.scrollTo`
            // still resolves the same id and lands at the same visual
            // position (the top of the Form's real content), but there
            // is no longer a separate, empty container to render.
            Section {
                HStack {
                    Text(athleteDisplayName)
                        .font(VoxtrTypography.cardTitle)
                        .foregroundStyle(VoxtrColor.textPrimary)
                    Spacer()
                    Button {
                        viewModel.switchToWeek(viewModel.weekStart.adding(days: -7))
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("planning.previousWeekButton")
                    WeekIdentityView(
                        weekStart: viewModel.weekStart,
                        referenceWeekStart: WeeklyPlanningViewModel.currentWeekStart()
                    )
                    Button {
                        viewModel.switchToWeek(viewModel.weekStart.adding(days: 7))
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("planning.nextWeekButton")
                }
                .accessibilityIdentifier("planning.weekIdentityBar")
            }
            .voxtrRowSurface()
            .id("weeklyPlanning.top")

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("planning.errorMessage")
                }
                .voxtrRowSurface()
            }

            if !viewModel.isCommitted && !viewModel.recurringSuggestions.isEmpty {
                Section {
                    ForEach(viewModel.recurringSuggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ActivityLabelResolver(modelContext: modelContext).primaryLabel(for: suggestion))
                                .font(VoxtrTypography.cardTitle)
                                .foregroundStyle(VoxtrColor.textPrimary)
                            Text(Self.suggestionSubtitle(for: suggestion))
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                            HStack {
                                Button("Add to week") {
                                    viewModel.acceptSuggestion(suggestion)
                                }
                                .accessibilityIdentifier("planning.acceptSuggestionButton.\(suggestion.id)")
                                Button("Dismiss") {
                                    viewModel.dismissSuggestion(suggestion)
                                }
                                .accessibilityIdentifier("planning.dismissSuggestionButton.\(suggestion.id)")
                            }
                        }
                        .accessibilityIdentifier("planning.suggestionRow.\(suggestion.id)")
                    }
                } header: {
                    VoxtrSectionHeading("Recurring suggestions")
                }
                .voxtrRowSurface()
                .accessibilityIdentifier("planning.suggestionList")
            }

            Section {
                ForEach(viewModel.activities, id: \.id) { activity in
                    NavigationLink {
                        ActivityDetailViewLoader(
                            plannedActivity: activity,
                            athleteId: viewModel.athleteId,
                            athleteDisplayName: athleteDisplayName,
                            actorId: actorId,
                            planningService: planningService,
                            trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                            notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                            onActivityLogged: { viewModel.refreshAfterActivityDetailMutation() }
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ActivityLabelResolver(modelContext: modelContext).primaryLabel(for: activity))
                                .font(VoxtrTypography.cardTitle)
                                .foregroundStyle(VoxtrColor.textPrimary)
                            Text(ActivityLabelResolver(modelContext: modelContext).metadataLabel(for: activity))
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                            Text(Self.rowSubtitle(for: activity))
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("planning.activityRow.\(activity.id.uuidString)")
                    .swipeActions {
                        if !viewModel.isCommitted {
                            Button("Delete", role: .destructive) {
                                viewModel.deleteActivity(activity)
                            }
                            .accessibilityIdentifier("planning.deleteActivityButton.\(activity.id.uuidString)")
                        }
                    }
                }
            } header: {
                VoxtrSectionHeading("Planned activities")
            }
            .voxtrRowSurface()
            .accessibilityIdentifier("planning.activityList")

            if !viewModel.isCommitted {
                Section {
                    ActivityIdentityInputView(
                        sportId: $viewModel.newActivitySportId,
                        activityType: $viewModel.newActivityType,
                        activityName: $viewModel.newActivityTitle,
                        accessibilityPrefix: "planning.newActivity"
                    )
                    DatePicker("Date", selection: $viewModel.newActivityDate, displayedComponents: .date)
                        .accessibilityIdentifier("planning.newActivityDatePicker")
                    Toggle("Has start time", isOn: $viewModel.newActivityHasStartTime)
                        .accessibilityIdentifier("planning.newActivityHasStartTimeToggle")
                    if viewModel.newActivityHasStartTime {
                        DatePicker("Start time", selection: $viewModel.newActivityStartTime, displayedComponents: .hourAndMinute)
                            .accessibilityIdentifier("planning.newActivityStartTimePicker")
                    }
                    Toggle("Has duration", isOn: $viewModel.newActivityHasDuration)
                        .accessibilityIdentifier("planning.newActivityHasDurationToggle")
                    if viewModel.newActivityHasDuration {
                        DurationPickerView(durationMinutes: $viewModel.newActivityDurationMinutes)
                    }
                    TextField("Location (optional)", text: $viewModel.newActivityLocation)
                        .accessibilityIdentifier("planning.newActivityLocationField")

                    VoxtrSectionHeading("Reminders")
                    ActivityReminderListEditorView(
                        reminders: $viewModel.newActivityReminders,
                        isAvailable: viewModel.isNewActivityReminderAvailable,
                        recentTextSuggestions: viewModel.newActivityReminderRecentTextSuggestions,
                        isUpdating: false,
                        onCommit: { _ in
                            // Create flow: reminders are purely local
                            // draft state until Save (see
                            // `newActivityReminders`'s own doc comment)
                            // — the two-way `$viewModel.newActivityReminders`
                            // binding above already keeps text/lead-time
                            // edits live; nothing further needs to
                            // happen on commit here.
                        },
                        onRemove: { viewModel.removeNewActivityReminderDraft($0) },
                        onAdd: { viewModel.addNewActivityReminderDraft() }
                    )

                    Button("Add activity") {
                        viewModel.addActivity()
                    }
                    .accessibilityIdentifier("planning.addActivityButton")
                } header: {
                    VoxtrSectionHeading("Add activity")
                }
                .voxtrRowSurface()
            }

            // PR #38 review follow-up: an activity created successfully
            // even though one or more of its staged reminders did not
            // (denied authorization, past fire date, generic failure).
            // The "Add activity" form above has already reset for the
            // next entry by the time this can appear — this is a
            // SEPARATE, persistent summary so that outcome is never
            // silently lost. Empty (and therefore hidden) whenever the
            // most recent add had no reminder trouble to report.
            if !viewModel.createReminderOutcomes.isEmpty {
                Section {
                    ForEach(viewModel.createReminderOutcomes) { outcome in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(outcome.text)
                                .font(VoxtrTypography.cardTitle)
                                .foregroundStyle(VoxtrColor.textPrimary)
                            Text(PlanningStrings.reminderNotSavedAfterActivitySaved)
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                            if outcome.authorizationDenied {
                                Text(PlanningStrings.reminderAuthorizationDenied)
                                    .font(VoxtrTypography.metadata)
                                    .foregroundStyle(VoxtrColor.textSecondary)
                                Button(PlanningStrings.reminderOpenSettings) {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }
                                .accessibilityIdentifier("planning.createReminderOutcome.openSettingsButton.\(outcome.id.uuidString)")
                            } else if let errorMessage = outcome.errorMessage {
                                Text(errorMessage)
                                    .font(VoxtrTypography.metadata)
                                    .foregroundStyle(.red)
                            }
                        }
                        .accessibilityIdentifier("planning.createReminderOutcome.row.\(outcome.id.uuidString)")
                    }
                    Button("Dismiss") {
                        viewModel.dismissCreateReminderOutcomes()
                    }
                    .accessibilityIdentifier("planning.createReminderOutcome.dismissButton")
                } header: {
                    VoxtrSectionHeading("Reminder not saved")
                }
                .voxtrRowSurface()
            }

            // Weekday-scan / status-placement round: moved from just
            // below the week identity bar to the bottom of the screen
            // — the plan's content (activity list, add form) now reads
            // first, and commit status/action reads as a conclusion to
            // that content rather than the leading thing the user sees.
            // Same state, same actions, same `.confirmationDialog` —
            // only the position in the Form changed.
            Section {
                HStack {
                    Text(viewModel.statusLabel)
                        .font(VoxtrTypography.cardTitle)
                        .foregroundStyle(viewModel.isCommitted ? .green : .orange)
                        .accessibilityIdentifier("planning.statusLabel")
                    Spacer()
                    if !viewModel.isCommitted {
                        Button("Commit week") {
                            viewModel.commit()
                        }
                        .accessibilityIdentifier("planning.commitButton")
                    } else if viewModel.canReopenPlanning {
                        // Reversibility principle: only offered for a
                        // committed CURRENT or FUTURE week — a
                        // committed HISTORICAL week never shows this,
                        // matching `canReopenPlanning`'s own gate
                        // exactly. Lightweight confirmation since this
                        // reopens the SAME plan in place, not a
                        // destructive action.
                        Button("Reopen Planning") {
                            isPresentingReopenPlanningConfirmation = true
                        }
                        .accessibilityIdentifier("planning.reopenPlanningButton")
                    }
                }
            }
            .voxtrRowSurface()
            .confirmationDialog(
                "Reopen this week's plan for editing?",
                isPresented: $isPresentingReopenPlanningConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reopen Planning") {
                    viewModel.reopenPlanning()
                }
                Button("Keep Committed", role: .cancel) {}
            }
        }
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle("\(athleteDisplayName) Weekly Plan")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Manage recurring activities") {
                    viewModel.loadRecurringActivities()
                    isManagingRecurringActivities = true
                }
                .accessibilityIdentifier("planning.manageRecurringActivitiesButton")
            }
        }
        .onAppear {
            viewModel.loadOrCreateWeekPlan()
        }
        .sheet(isPresented: $isManagingRecurringActivities) {
            RecurringActivityManagementView(viewModel: viewModel, athleteDisplayName: athleteDisplayName)
        }
        .onChange(of: viewModel.successfulAddActivityTrigger) { _, _ in
            // Only fires when an add genuinely succeeded — never on
            // validation failure, persistence failure, or opening the
            // form. Same rationale as DailyTrainingView's own identical
            // `.onChange(of: successfulLogTrigger)`.
            withAnimation {
                proxy.scrollTo("weeklyPlanning.top", anchor: .top)
            }
        }
        }
    }

    /// Sprint 1 completion package, Part 6: date, start time (when
    /// planned), and location (when set) — everywhere the domain model
    /// already represents these, they're shown, not replaced with a
    /// generic label.
    ///
    /// Weekday-scan round: leads with `weekdayLabel(for:)` — the same
    /// canonical formatter this file already uses for recurring
    /// suggestions/weekday multi-select below — instead of the raw ISO
    /// date string, so a row's day is legible at a glance rather than
    /// requiring the reader to parse "2026-08-19". This replaces the
    /// date text rather than adding to it, so nothing is duplicated.
    private static func rowSubtitle(for activity: PlannedActivity) -> String {
        var parts: [String] = [weekdayLabel(for: activity.localDate.weekday)]
        if let timeLabel = PlannedTimeRangeFormatter.label(start: activity.startLocalTime, durationMinutes: activity.plannedDurationMinutes) {
            parts.append(timeLabel)
        }
        if let location = activity.location, !location.isEmpty {
            parts.append(location)
        }
        return parts.joined(separator: " · ")
    }

    /// Weekday, start time (if present), and duration (if present) for
    /// one suggestion — everything the suggestion row displays besides
    /// its title.
    ///
    /// Weekday-scan round: dropped the redundant `occurrenceDate.isoString`
    /// that used to follow the weekday label here — showing both the
    /// weekday word and its raw ISO date together was exactly the
    /// "duplicate date text" this round's own presentation principle
    /// asks not to do; the weekday label alone is what
    /// `rowSubtitle(for:)` above now also settles on.
    private static func suggestionSubtitle(for suggestion: RecurringActivitySuggestion) -> String {
        var parts: [String] = [weekdayLabel(for: suggestion.occurrenceDate.weekday)]
        if let timeLabel = PlannedTimeRangeFormatter.label(start: suggestion.startLocalTime, durationMinutes: suggestion.plannedDurationMinutes) {
            parts.append(timeLabel)
        } else if let duration = suggestion.plannedDurationMinutes {
            // Duration known, no start time: never invent an end time —
            // the existing duration-only presentation is preserved.
            parts.append("\(duration) min")
        }
        return parts.joined(separator: " · ")
    }

    /// Shared with `RecurringActivityManagementView` below — same
    /// labels either way.
    static func weekdayLabel(for weekday: Weekday) -> String {
        switch weekday {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }

    /// Sprint 1.2B: compact display for one or more weekdays — e.g.
    /// "Mon, Tue, Wed, Thu, Fri" for a Monday-Friday camp. Uses a
    /// three-letter abbreviation here specifically (not the full
    /// `weekdayLabel(for:)` names) since a definition can now list up
    /// to seven days and this needs to stay compact in a single row,
    /// per this package's own "presented compactly" requirement.
    /// Deterministically ordered (`RecurringPlannedActivity.init`
    /// already stores `weekdays` sorted) — never depends on selection
    /// or insertion order.
    static func weekdaysLabel(for weekdays: [Weekday]) -> String {
        weekdays.map { weekday in
            String(weekdayLabel(for: weekday).prefix(3))
        }.joined(separator: ", ")
    }
}

/// Sprint 1.2B, Priority 3: compact Monday–Sunday multi-select for
/// recurring activity weekdays. A grid of toggle buttons rather than a
/// list-style multi-select `Picker` (SwiftUI's `Picker` doesn't support
/// multiple selection natively) — deliberately simple, not a general
/// recurrence-builder UI. At least one weekday must remain selected in
/// practice (enforced by `PlanningService`'s own validation before
/// save, not by disabling the last toggle here — the user can freely
/// toggle all off mid-edit without the UI fighting them, and only sees
/// the "at least one weekday" requirement if they actually try to save
/// with none selected).
struct WeekdayMultiSelectView: View {
    @Binding var selectedWeekdays: Set<Weekday>

    private static let orderedWeekdays: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.orderedWeekdays, id: \.self) { weekday in
                let isSelected = selectedWeekdays.contains(weekday)
                Button {
                    if isSelected {
                        selectedWeekdays.remove(weekday)
                    } else {
                        selectedWeekdays.insert(weekday)
                    }
                } label: {
                    Text(String(WeeklyPlanningView.weekdayLabel(for: weekday).prefix(1)))
                        .frame(width: 32, height: 32)
                        .background(isSelected ? VoxtrColor.accent : VoxtrColor.surfaceSubtle)
                        .foregroundStyle(isSelected ? Color.white : VoxtrColor.textPrimary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("planning.recurringFormWeekdayToggle.\(weekday.rawValue)")
                .accessibilityLabel(Text(WeeklyPlanningView.weekdayLabel(for: weekday)))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}

/// Simple management flow for recurring activities: list existing
/// definitions (with an enable/disable toggle and tap-to-edit), and a
/// form to create a new one or edit the tapped one. Deliberately plain
/// — a single sheet, no additional navigation structure, matching this
/// work package's own "keep the UI functional and simple" instruction.
struct RecurringActivityManagementView: View {
    @Bindable var viewModel: WeeklyPlanningViewModel
    let athleteDisplayName: String
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var formSheetItem: RecurringFormSheetItem?

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.recurringPlannedActivities) { recurringActivity in
                    VStack(alignment: .leading) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ActivityLabelResolver(modelContext: modelContext).primaryLabel(for: recurringActivity))
                                    .font(VoxtrTypography.cardTitle)
                                    .foregroundStyle(VoxtrColor.textPrimary)
                                Text(ActivityLabelResolver(modelContext: modelContext).metadataLabel(for: recurringActivity))
                                    .font(VoxtrTypography.metadata)
                                    .foregroundStyle(VoxtrColor.textSecondary)
                                Text(WeeklyPlanningView.weekdaysLabel(for: recurringActivity.weekdays))
                                    .font(VoxtrTypography.metadata)
                                    .foregroundStyle(VoxtrColor.textSecondary)
                                if let location = recurringActivity.location, !location.isEmpty {
                                    Text(location)
                                        .font(VoxtrTypography.metadata)
                                        .foregroundStyle(VoxtrColor.textSecondary)
                                }
                            }
                            Spacer()
                            Toggle(
                                "Enabled",
                                isOn: Binding(
                                    get: { recurringActivity.isEnabled },
                                    set: { _ in viewModel.toggleRecurringActivityEnabled(recurringActivity) }
                                )
                            )
                            .labelsHidden()
                            .accessibilityIdentifier("planning.recurringEnabledToggle.\(recurringActivity.id.uuidString)")
                        }
                    }
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("planning.recurringActivityRow.\(recurringActivity.id.uuidString)")
                    .onTapGesture {
                        viewModel.beginEditingRecurringActivity(recurringActivity)
                        formSheetItem = RecurringFormSheetItem(editingRecurringActivity: recurringActivity)
                    }
                    .voxtrRowSurface()
                }
            }
            .voxtrScreenBackground()
            .tint(VoxtrColor.accent)
            .accessibilityIdentifier("planning.recurringActivityList")
            .navigationTitle("\(athleteDisplayName) · Recurring Activities")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add") {
                        viewModel.resetRecurringForm()
                        formSheetItem = RecurringFormSheetItem(editingRecurringActivity: nil)
                    }
                    .accessibilityIdentifier("planning.addRecurringActivityButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("planning.doneManagingRecurringActivitiesButton")
                }
            }
            .sheet(item: $formSheetItem) { item in
                RecurringActivityFormView(
                    viewModel: viewModel,
                    editingRecurringActivity: item.editingRecurringActivity,
                    athleteDisplayName: athleteDisplayName
                )
            }
        }
    }
}

/// Sprint 1.1.1, Item 6 (regression audit — "no Bool + separately-
/// populated destination state"): wraps the one piece of data
/// `RecurringActivityFormView` needs (which recurring activity, if
/// any, is being edited) for `.sheet(item:)` presentation. Previously
/// this view used a `Bool` (`isPresentingForm`) plus a separately-set
/// `editingRecurringActivity: RecurringPlannedActivity?` — the exact
/// pattern already diagnosed and fixed twice elsewhere (`DailyTrainingView`
/// "Manage Recurring Activities", `RecurringOccurrencePreviewView` "Edit
/// Recurring Definition"). For "Add" (nil) this was low-risk since nil
/// is itself a valid state; for "Edit" a race could present the form
/// still in "Add" mode rather than truly blank — still a real bug this
/// fix removes entirely.
private struct RecurringFormSheetItem: Identifiable {
    let id = UUID()
    let editingRecurringActivity: RecurringPlannedActivity?
}

/// The create/edit form itself — one form, reused for both, matching
/// how `WeeklyPlanningView`'s own edit sheet already reuses its form
/// fields for add vs. edit.
struct RecurringActivityFormView: View {
    @Bindable var viewModel: WeeklyPlanningViewModel
    let editingRecurringActivity: RecurringPlannedActivity?
    let athleteDisplayName: String
    @Environment(\.dismiss) private var dismiss

    private var availableActivityTypes: [ActivityType] {
        if editingRecurringActivity?.activityType == .physicalTraining {
            return [.physicalTraining] + ActivityType.selectableCases
        } else {
            return ActivityType.selectableCases
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("planning.recurringFormErrorMessage")
                    }
                    .voxtrRowSurface()
                }

                Section {
                    ActivityIdentityInputView(
                        sportId: $viewModel.recurringFormSportId,
                        activityType: $viewModel.recurringFormActivityType,
                        activityName: $viewModel.recurringFormTitle,
                        availableActivityTypes: availableActivityTypes,
                        accessibilityPrefix: "planning.recurringForm"
                    )
                } header: {
                    VoxtrSectionHeading("Activity")
                }
                .voxtrRowSurface()

                Section {
                    WeekdayMultiSelectView(selectedWeekdays: $viewModel.recurringFormWeekdays)
                        .accessibilityIdentifier("planning.recurringFormWeekdayPicker")

                    DatePicker(
                        "Start date",
                        selection: $viewModel.recurringFormStartDate,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("planning.recurringFormStartDatePicker")

                    DatePicker(
                        "End date",
                        selection: $viewModel.recurringFormEndDate,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("planning.recurringFormEndDatePicker")

                    Toggle("Has start time", isOn: $viewModel.recurringFormHasStartTime)
                        .accessibilityIdentifier("planning.recurringFormHasStartTimeToggle")
                    if viewModel.recurringFormHasStartTime {
                        DatePicker(
                            "Start time",
                            selection: $viewModel.recurringFormStartTime,
                            displayedComponents: .hourAndMinute
                        )
                        .accessibilityIdentifier("planning.recurringFormStartTimePicker")
                    }

                    Toggle("Has duration", isOn: $viewModel.recurringFormHasDuration)
                        .accessibilityIdentifier("planning.recurringFormHasDurationToggle")
                    if viewModel.recurringFormHasDuration {
                        DurationPickerView(durationMinutes: $viewModel.recurringFormDurationMinutes)
                    }
                } header: {
                    VoxtrSectionHeading("Schedule")
                }
                .voxtrRowSurface()

                Section {
                    TextField("Location (optional)", text: $viewModel.recurringFormLocation)
                        .accessibilityIdentifier("planning.recurringFormLocationField")
                } header: {
                    VoxtrSectionHeading("Location")
                }
                .voxtrRowSurface()
            }
            .voxtrScreenBackground()
            .tint(VoxtrColor.accent)
            .navigationTitle(editingRecurringActivity == nil ? "\(athleteDisplayName) · Add Recurring Activity" : "\(athleteDisplayName) · Edit Recurring Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let succeeded: Bool
                        if let editingRecurringActivity {
                            succeeded = viewModel.editRecurringActivity(editingRecurringActivity)
                        } else {
                            succeeded = viewModel.createRecurringActivity()
                        }
                        if succeeded {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("planning.saveRecurringActivityButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("planning.cancelRecurringActivityButton")
                }
            }
        }
    }
}
