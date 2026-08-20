import SwiftUI

/// VX-023 (Sleep V1): the canonical Sleep capture screen — one
/// `LocalDate` per screen instance, reused identically for "log today's
/// Sleep" and "edit/backfill a historical date" (only `localDate` and
/// `existingSleepQuality` differ between those two call sites; this view
/// has no notion of "today" vs "historical" itself).
public struct SleepCaptureView: View {
    @State private var viewModel: SleepCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    /// Called only after a successful save — the caller's hook for
    /// refreshing whatever list/card led here (e.g. Sleep History
    /// re-reading the corrected value). Live invalidation of
    /// already-mounted Athlete Home/Family Home Sleep surfaces happens
    /// independently via `AthleteSleepChangeBroadcaster` inside
    /// `SleepCoordinationService.recordSleep` — this closure is purely
    /// for the presenting screen's own immediate list refresh.
    private let onSaved: (() -> Void)?

    public init(viewModel: SleepCaptureViewModel, onSaved: (() -> Void)? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.onSaved = onSaved
    }

    public var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("sleepCapture.errorMessage")
                }
                .voxtrRowSurface()
            }

            Section {
                LabeledContent("Athlete", value: viewModel.athleteDisplayName)
                LabeledContent("Date", value: viewModel.localDate.isoString)
            }
            .voxtrRowSurface()
            .accessibilityIdentifier("sleepCapture.context")

            // Product contract: "How did you sleep?" / "Sleep score:
            // 1 2 3 4 5" — deliberately no Poor/Good/Excellent labels, no
            // readiness language, no color-coding. Same neutral 1-5
            // Picker shape LogActivityView already establishes for
            // Session Form.
            Section {
                Picker("Sleep score", selection: $viewModel.sleepQuality) {
                    ForEach(1...5, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sleepCapture.sleepQualityPicker")
            } header: {
                VoxtrSectionHeading("How did you sleep?")
            }
            .voxtrRowSurface()
        }
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle("Sleep")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    viewModel.save()
                    if viewModel.didSave {
                        onSaved?()
                        dismiss()
                    }
                }
                .accessibilityIdentifier("sleepCapture.saveButton")
            }
        }
    }
}
