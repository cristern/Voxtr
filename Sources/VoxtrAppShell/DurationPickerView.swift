import SwiftUI

/// Sprint 1.1, P1 (duration input), revised in Sprint 1.1.1 Items 4/5
/// and the P2 Stepper UX audit: a compact wheel-style `Picker` of
/// common presets plus "Custom", which reveals a direct numeric
/// minutes `TextField` — not another Stepper. One component reused
/// everywhere duration is entered (Log Activity, Edit Activity, Daily
/// Training, and now Add/Edit Recurring Activity), so these screens'
/// duration input never drifts apart. No external dependency: standard
/// SwiftUI `Picker`/`TextField` only. `durationMinutes: Int` (the
/// existing domain representation) is unchanged — this is presentation
/// only.
///
/// Custom duration UX (Sprint 1.1.1, Item 5): typing is the only way
/// to set a non-preset value now — no more repeated +/- tapping.
/// Reopening an existing non-preset value (e.g. 53) automatically
/// selects "Custom" in the wheel (the picker's own selection is
/// derived from `durationMinutes`, not separately tracked) and shows
/// that value in the text field. Invalid or empty input is never
/// committed to `durationMinutes` — the last valid value is preserved
/// until the user types something valid, so an invalid duration can
/// never be persisted through this control.
public struct DurationPickerView: View {
    @Binding var durationMinutes: Int
    @State private var customText: String = ""

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

        if !Self.presets.contains(durationMinutes) {
            HStack {
                Text("Minutes")
                Spacer()
                TextField("Minutes", text: $customText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .accessibilityIdentifier("durationPicker.customMinutesField")
            }
            .onAppear {
                // Seeds the field from the current value the first time
                // the custom row appears — covers both "user just
                // selected Custom" (starts from the last value) and
                // "reopening an existing non-preset duration" (shows
                // that saved value, e.g. 53).
                if customText.isEmpty {
                    customText = String(durationMinutes)
                }
            }
            .onChange(of: customText) { _, newValue in
                commitCustomText(newValue)
            }
        }
    }

    /// Maps the picker's own selection (a preset, or `nil` for
    /// "Custom") onto the real `durationMinutes` binding. Selecting a
    /// preset sets the value directly and hides the custom text field
    /// (the `if !presets.contains(...)` above stops showing it).
    /// Selecting "Custom" does not alter `durationMinutes` itself —
    /// only the text field's own `onChange` commits a value, and only
    /// once the user has typed something valid.
    private var pickerSelection: Binding<Int?> {
        Binding<Int?>(
            get: { Self.presets.contains(durationMinutes) ? durationMinutes : nil },
            set: { newValue in
                if let newValue {
                    durationMinutes = newValue
                    customText = ""
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
