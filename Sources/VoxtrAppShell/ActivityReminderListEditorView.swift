import SwiftUI
import UIKit

/// Activity Reminder What/When: the ONE reminder-list editor, reused
/// identically by the Planned Activity CREATE flow (inline in
/// `WeeklyPlanningView`'s own "Add activity" form, against a local
/// `[ActivityReminderDraft]` with no persisted identity yet) and the
/// EDIT flow (`ActivityEditFormView`, against reminders already loaded
/// from canonical Notifications truth). Neither flow duplicates this
/// UI or its commit logic — only what happens on commit differs (the
/// caller's own `onCommit` closure), matching this slice's own "prefer
/// a simple nested reminder editor rather than a complex Notifications
/// dashboard" instruction.
///
/// Deliberately simple: each reminder is one row (What text + When
/// lead time), an "Add Reminder" button appends a new blank row, and
/// each row can be removed independently. `isAvailable` gates the
/// whole editor on "does this activity currently have a concrete start
/// time" — the same product requirement PR #37's own single-reminder
/// slice already established, generalized to the whole list rather
/// than one control.
public struct ActivityReminderListEditorView: View {
    @Binding var reminders: [ActivityReminderDraft]
    let isAvailable: Bool
    let recentTextSuggestions: [String]
    let isUpdating: Bool
    /// Fired when ONE row's text/lead time settles (text field loses
    /// focus, a suggestion is tapped, or a lead-time preset/Custom value
    /// commits) — never on every keystroke. The caller decides what
    /// "commit" means for its own flow (create: local-only until Save;
    /// edit: an immediate `upsertReminder` round trip).
    let onCommit: (ActivityReminderDraft) -> Void
    let onRemove: (ActivityReminderDraft) -> Void
    let onAdd: () -> Void

    public init(
        reminders: Binding<[ActivityReminderDraft]>,
        isAvailable: Bool,
        recentTextSuggestions: [String],
        isUpdating: Bool,
        onCommit: @escaping (ActivityReminderDraft) -> Void,
        onRemove: @escaping (ActivityReminderDraft) -> Void,
        onAdd: @escaping () -> Void
    ) {
        _reminders = reminders
        self.isAvailable = isAvailable
        self.recentTextSuggestions = recentTextSuggestions
        self.isUpdating = isUpdating
        self.onCommit = onCommit
        self.onRemove = onRemove
        self.onAdd = onAdd
    }

    @ViewBuilder
    public var body: some View {
        if !isAvailable {
            Text(PlanningStrings.reminderNeedsStartTime)
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
                .accessibilityIdentifier("activityReminder.needsStartTimeMessage")
        } else {
            ForEach($reminders) { $draft in
                ActivityReminderRowView(
                    draft: $draft,
                    recentTextSuggestions: recentTextSuggestions,
                    isUpdating: isUpdating,
                    onCommit: { onCommit(draft) },
                    onRemove: { onRemove(draft) }
                )
            }
            Button("Add Reminder") { onAdd() }
                .accessibilityIdentifier("activityReminder.addButton")
        }
    }
}

/// One reminder row: What (free text + recent-text suggestions) + When
/// (`ReminderLeadTimePickerView`, reused verbatim rather than a second,
/// list-shaped time control). Commits on text-field blur (same
/// `@FocusState`-based pattern `ReminderLeadTimePickerView`'s own Custom
/// field already establishes for a numeric-pad keyboard with no return
/// key) or a suggestion tap; the lead-time picker commits through its
/// own existing `onCommit`.
private struct ActivityReminderRowView: View {
    @Binding var draft: ActivityReminderDraft
    let recentTextSuggestions: [String]
    let isUpdating: Bool
    let onCommit: () -> Void
    let onRemove: () -> Void
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("What (e.g. Pack hockey bag)", text: $draft.text)
                    .focused($isTextFieldFocused)
                    .accessibilityIdentifier("activityReminder.textField.\(draft.id.uuidString)")
                    .onSubmit { onCommit() }
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .accessibilityIdentifier("activityReminder.removeButton.\(draft.id.uuidString)")
            }
            .onChange(of: isTextFieldFocused) { wasFocused, isFocused in
                if wasFocused, !isFocused {
                    onCommit()
                }
            }

            if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !recentTextSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(recentTextSuggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                draft.text = suggestion
                                onCommit()
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("activityReminder.suggestion.\(suggestion)")
                        }
                    }
                }
            }

            ReminderLeadTimePickerView(
                leadTimeMinutes: $draft.leadTimeMinutes,
                onCommit: { _ in onCommit() }
            )
            .disabled(isUpdating)

            if draft.authorizationDenied {
                VStack(alignment: .leading, spacing: 4) {
                    Text(PlanningStrings.reminderAuthorizationDenied)
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                        .accessibilityIdentifier("activityReminder.authorizationDeniedMessage.\(draft.id.uuidString)")
                    Button(PlanningStrings.reminderOpenSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .accessibilityIdentifier("activityReminder.openSettingsButton.\(draft.id.uuidString)")
                }
            }

            if let errorMessage = draft.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("activityReminder.errorMessage.\(draft.id.uuidString)")
            }
        }
        .accessibilityIdentifier("activityReminder.row.\(draft.id.uuidString)")
    }
}
