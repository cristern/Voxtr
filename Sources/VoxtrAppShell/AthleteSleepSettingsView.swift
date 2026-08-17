import SwiftUI

/// VX-023 (Sleep V1): Profile → Manage Athletes → (per-athlete) "Sleep"
/// — a single On/Off toggle, nothing else. Reached from
/// `AthleteFamilyManagementView`'s per-athlete row, alongside its
/// existing Edit/Archive actions.
public struct AthleteSleepSettingsView: View {
    @State private var viewModel: AthleteSleepSettingsViewModel

    public init(viewModel: AthleteSleepSettingsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("athleteSleepSettings.errorMessage")
                }
            }
            Section {
                Toggle("Sleep tracking", isOn: Binding(
                    get: { viewModel.isTrackingEnabled },
                    set: { viewModel.setTrackingEnabled($0) }
                ))
                .accessibilityIdentifier("athleteSleepSettings.trackingToggle")
            } footer: {
                Text("When off, Sleep won't appear on \(viewModel.athleteDisplayName)'s Home or Family Home. Existing Sleep history is kept.")
            }
        }
        .navigationTitle("Sleep")
        .onAppear {
            viewModel.load()
        }
    }
}
