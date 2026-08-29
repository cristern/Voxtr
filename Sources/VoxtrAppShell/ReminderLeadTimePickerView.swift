import SwiftUI

/// Notifications V1 Activity Reminder UI slice: lead-time input for the
/// Activity Reminder control — the SAME "wheel Picker of presets, with
/// Custom revealing a numeric `TextField`" interaction `DurationPickerView`
/// already establishes for duration input elsewhere in this app (Log
/// Activity, Edit Activity, Daily Training, Recurring Activity). Reused
/// here as a PATTERN, not by generalizing that existing, already-in-use
/// component's API for a second, different preset set and valid range —
/// same reasoning `DurationPickerView` itself gives for staying a single
/// reused component rather than several ad hoc ones, applied here in the
/// other direction (a genuinely different domain concept gets its own
/// small component, not a forced shared one).
///
/// `leadTimeMinutes: Int` binds directly to the persisted domain
/// representation (`ActivityReminder.leadTimeMinutes` — unchanged
/// foundation persistence) — this is presentation only.
public struct ReminderLeadTimePickerView: View {
    @Binding var leadTimeMinutes: Int
    @State private var isCustomSelected: Bool = false
    @State private var customText: String = ""
    @State private var hasInitialized: Bool = false
    @FocusState private var isCustomFieldFocused: Bool

    /// This UI slice's own approved contract: 15 minutes / 30 minutes /
    /// 1 hour before, plus Custom.
    private static let presets = [15, 30, 60]
    /// `ActivityReminder`'s own persisted bound (`0...10080`, 7 days) —
    /// Custom's valid range, deliberately not an artificial 60-minute
    /// ceiling.
    private static let customValidRange = 1...10080

    /// Fired only on a genuinely COMMITTED change — a preset tap
    /// (always a discrete, deliberate action), or the Custom field's
    /// keyboard return/blur — never on every keystroke while typing a
    /// Custom value. `leadTimeMinutes` itself still updates live so the
    /// control's own display stays correct as the user types; the
    /// caller's actual reminder mutation (which re-checks notification
    /// authorization and re-schedules) only needs to run once the value
    /// is settled, not once per digit.
    private let onCommit: (Int) -> Void

    public init(leadTimeMinutes: Binding<Int>, onCommit: @escaping (Int) -> Void) {
        _leadTimeMinutes = leadTimeMinutes
        self.onCommit = onCommit
    }

    public var body: some View {
        Picker("Remind me", selection: pickerSelection) {
            ForEach(Self.presets, id: \.self) { preset in
                Text(Self.label(forMinutes: preset)).tag(Int?.some(preset))
            }
            Text("Custom").tag(Int?.none)
        }
        .pickerStyle(.wheel)
        .frame(height: 110)
        .accessibilityIdentifier("reminderLeadTimePicker.presetPicker")
        .onAppear {
            // Runs once, matching `DurationPickerView`'s own established
            // fix for this exact class of bug (see that file's own doc
            // comment): establishes selection state from the current
            // value exactly one time, covering "reopening an existing
            // non-preset lead time" (e.g. 20 minutes: Custom is
            // selected, the field shows 20).
            guard !hasInitialized else { return }
            hasInitialized = true
            isCustomSelected = !Self.presets.contains(leadTimeMinutes)
            if isCustomSelected {
                customText = String(leadTimeMinutes)
            }
        }

        if isCustomSelected {
            HStack {
                Text("Minutes before")
                Spacer()
                TextField("Minutes", text: $customText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .accessibilityIdentifier("reminderLeadTimePicker.customMinutesField")
                    .focused($isCustomFieldFocused)
                    .onSubmit {
                        commitCustomText(customText)
                    }
            }
            .onChange(of: customText) { _, newValue in
                // Live-updates the displayed/bound value on every
                // keystroke (so the field always shows what's typed and
                // a caller reading `leadTimeMinutes` sees the latest
                // valid value), but deliberately does NOT call
                // `onCommit` here — see this property's own doc comment.
                updateLiveValue(newValue)
            }
            .onChange(of: isCustomFieldFocused) { wasFocused, isFocused in
                // A numeric-pad keyboard has no return key, so `.onSubmit`
                // above never fires in practice — losing focus (tapping
                // away, or the "Done" toolbar button if one is added
                // later) is this field's real commit signal.
                if wasFocused, !isFocused {
                    commitCustomText(customText)
                }
            }
        }
    }

    private var pickerSelection: Binding<Int?> {
        Binding<Int?>(
            get: { isCustomSelected ? nil : leadTimeMinutes },
            set: { newValue in
                if let newValue {
                    isCustomSelected = false
                    leadTimeMinutes = newValue
                    onCommit(newValue)
                } else {
                    isCustomSelected = true
                    if customText.isEmpty {
                        customText = String(leadTimeMinutes)
                    }
                }
            }
        )
    }

    /// Updates the live-bound value (for display) without committing —
    /// mirrors `DurationPickerView.commitCustomText`'s own validation,
    /// just without firing `onCommit`.
    private func updateLiveValue(_ text: String) {
        guard let parsed = Int(text), Self.customValidRange.contains(parsed) else { return }
        leadTimeMinutes = parsed
    }

    /// Only commits (fires `onCommit`) when the typed text is a
    /// genuinely valid lead time. Invalid or empty input never commits.
    private func commitCustomText(_ text: String) {
        guard let parsed = Int(text), Self.customValidRange.contains(parsed) else { return }
        leadTimeMinutes = parsed
        onCommit(parsed)
    }

    private static func label(forMinutes minutes: Int) -> String {
        minutes == 60 ? "1 hour before" : "\(minutes) minutes before"
    }
}
