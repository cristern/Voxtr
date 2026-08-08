import SwiftUI

/// Sprint 1.1, P1 (duration input): replaces minute-by-minute +/-
/// stepper editing — slow for common durations (getting from 0 to 60
/// meant 60 taps) — with a native `Picker` of common presets plus a
/// "Custom" option that reveals a `Stepper` for any other value. One
/// component reused by both Log Activity and Edit Activity, so the two
/// screens' duration input never drifts apart. No external dependency:
/// standard SwiftUI `Picker`/`Stepper` only. `durationMinutes: Int`
/// (the existing domain representation) is unchanged — this is
/// presentation only.
public struct DurationPickerView: View {
    @Binding var durationMinutes: Int

    /// The common presets this work package explicitly asks for.
    private static let presets = [30, 45, 60, 75, 90, 120]

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
        .accessibilityIdentifier("durationPicker.presetPicker")

        if !Self.presets.contains(durationMinutes) {
            Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 1...1440)
                .accessibilityIdentifier("durationPicker.customStepper")
        }
    }

    /// Maps the picker's own selection (a preset, or `nil` for
    /// "Custom") onto the real `durationMinutes` binding — selecting a
    /// preset sets the value directly; selecting "Custom" leaves the
    /// current value as the starting point for the stepper that
    /// appears, rather than resetting it to something arbitrary.
    private var pickerSelection: Binding<Int?> {
        Binding<Int?>(
            get: { Self.presets.contains(durationMinutes) ? durationMinutes : nil },
            set: { newValue in
                if let newValue {
                    durationMinutes = newValue
                }
                // Selecting "Custom" (nil) intentionally does nothing
                // here — the stepper below takes over, starting from
                // whatever durationMinutes already was.
            }
        )
    }
}
