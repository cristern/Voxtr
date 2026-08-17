import SwiftUI

/// Sprint 1.1, P1 (duration input), revised in Sprint 1.1.1 and
/// Sprint 1.2A: a compact wheel-style `Picker` of common presets plus
/// "Custom", which reveals a direct numeric minutes `TextField` — not
/// a Stepper. One component reused everywhere duration is entered (Log
/// Activity, Edit Activity, Daily Training, Recurring Activity), so
/// these screens' duration input never drifts apart. No external
/// dependency: standard SwiftUI `Picker`/`TextField` only.
/// `durationMinutes: Int` (the existing domain representation) is
/// unchanged — this is presentation only.
///
/// Sprint 1.2A root-cause fix: selecting "Custom" previously did NOT
/// reveal the text field when starting from a preset. The field's
/// visibility was driven entirely by `!presets.contains(durationMinutes)`
/// — but selecting "Custom" was deliberately designed to leave
/// `durationMinutes` untouched until the user typed a value (so an
/// incomplete edit never persisted). Since `durationMinutes` therefore
/// never actually left the preset set the moment "Custom" was tapped,
/// that condition stayed false and the field silently never appeared.
/// It only ever worked when reopening an activity whose duration was
/// ALREADY a non-preset value before the view opened — which is why
/// this passed casual testing but failed the very case being tested
/// (choosing Custom from a preset). Fixed by tracking which row is
/// selected (`isCustomSelected`) as its own explicit state, independent
/// of `durationMinutes`'s current value — initialized once from
/// `durationMinutes` (so reopening an existing 53 still auto-selects
/// Custom) but updated immediately when the user taps "Custom" in the
/// picker, regardless of whether a new value has been typed yet.
public struct DurationPickerView: View {
    @Binding var durationMinutes: Int
    @State private var isCustomSelected: Bool = false
    @State private var customText: String = ""
    @State private var hasInitialized: Bool = false

    /// The common presets this work package explicitly asks for.
    private static let presets = [30, 45, 60, 75, 90, 120]
    private static let validRange = 1...1440

    public init(durationMinutes: Binding<Int>) {
        _durationMinutes = durationMinutes
    }

    public var body: some View {
        Picker("Duration", selection: pickerSelection) {
            ForEach(Self.presets, id: \.self) { preset in
                Text("\(preset) min").tag(Int?.some(preset))
            }
            Text("Custom").tag(Int?.none)
        }
        .pickerStyle(.wheel)
        .frame(height: 110)
        .accessibilityIdentifier("durationPicker.presetPicker")
        .onAppear {
            // Runs once, regardless of whether durationMinutes happens
            // to be a preset or not — establishes the picker's own
            // selection state from the current value exactly one time,
            // covering "reopening an existing non-preset duration"
            // (e.g. 53: Custom is selected, the field shows 53).
            guard !hasInitialized else { return }
            hasInitialized = true
            isCustomSelected = !Self.presets.contains(durationMinutes)
            if isCustomSelected {
                customText = String(durationMinutes)
            }
        }

        if isCustomSelected {
            HStack {
                Text("Minutes")
                Spacer()
                TextField("Minutes", text: $customText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .accessibilityIdentifier("durationPicker.customMinutesField")
            }
            .onChange(of: customText) { _, newValue in
                commitCustomText(newValue)
            }
        }
    }

    /// The picker's own selection is now driven by `isCustomSelected`
    /// directly, not derived from `durationMinutes` — this is the core
    /// of the fix. Choosing a preset clears `isCustomSelected` AND sets
    /// `durationMinutes` together, so the field hides and the value
    /// updates in the same action. Choosing "Custom" sets
    /// `isCustomSelected = true` immediately — the field appears
    /// regardless of what `durationMinutes` currently holds — and seeds
    /// the text field from the current value as a starting point.
    private var pickerSelection: Binding<Int?> {
        Binding<Int?>(
            get: { isCustomSelected ? nil : durationMinutes },
            set: { newValue in
                if let newValue {
                    isCustomSelected = false
                    durationMinutes = newValue
                } else {
                    isCustomSelected = true
                    if customText.isEmpty {
                        customText = String(durationMinutes)
                    }
                }
            }
        )
    }

    /// Only commits to `durationMinutes` (the persisted domain
    /// representation) when the typed text is a genuinely valid
    /// duration (1...1440 minutes). Invalid or empty input is left
    /// uncommitted — `durationMinutes` keeps its last valid value —
    /// so an invalid duration can never reach persistence through this
    /// control.
    private func commitCustomText(_ text: String) {
        guard let parsed = Int(text), Self.validRange.contains(parsed) else { return }
        durationMinutes = parsed
    }
}

/// Activity outcome consistency closeout (item D): a small,
/// optional-aware wrapper around `DurationPickerView` above —
/// `DurationPickerView` itself stays `Binding<Int>`-only, completely
/// UNCHANGED, and every existing call site (Weekly Plan Add, Edit
/// Planned Activity, Edit Logged Activity, recurring activity forms)
/// keeps using it directly via the already-established "Has X" Toggle +
/// conditionally-shown `DurationPickerView` pattern, where the field's
/// requiredness is a user-chosen toggle. `LogActivityView`'s actual
/// duration doesn't fit that pattern — its requiredness is driven by
/// the Outcome picker next to it, not a dedicated toggle — and,
/// crucially, it must visibly represent "no duration selected yet"
/// rather than showing a fabricated starting value (60) that
/// `durationMinutes` doesn't actually contain (the exact reported bug:
/// Save was correctly blocked while the picker visibly showed 60).
///
/// While `durationMinutes` is `nil`, shows a plain row reading "Not
/// set" — the same vocabulary this app's own optional pickers already
/// use (e.g. the RPE `Picker`'s own `Text("Not set").tag(Int?.none)`) —
/// instead of the real wheel picker. Tapping it starts a real duration
/// at 60, this app's own established "reasonable starting value for an
/// optional duration" convention (`WeeklyPlanningViewModel.newActivityDurationMinutes`,
/// `ActivityDetailViewModel.editDurationMinutes`) — an explicit user
/// action choosing to set a duration, not a value fabricated merely to
/// satisfy the component. From that point on, the real
/// `DurationPickerView` is shown and reused verbatim — never a second,
/// duplicated duration-selection UI.
struct OptionalDurationPickerView: View {
    @Binding var durationMinutes: Int?

    var body: some View {
        if let value = durationMinutes {
            DurationPickerView(durationMinutes: Binding(
                get: { value },
                set: { durationMinutes = $0 }
            ))
        } else {
            Button {
                durationMinutes = 60
            } label: {
                HStack {
                    Text("Duration")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Not set")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("optionalDurationPicker.setDurationButton")
        }
    }
}
