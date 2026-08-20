import SwiftUI
import VoxtrCoreContracts

/// S1.4: the parent onboarding form. Deliberately minimal — parent name,
/// athlete name, birth date, development stage. No CloudKit, no Weekly
/// Review, no notifications; those are explicitly out of scope.
///
/// S1.5: every control has an `accessibilityIdentifier` (for UI testing
/// and assistive-technology targeting) and an explicit
/// `accessibilityLabel` — visible text and layout are unchanged.
public struct CreateFamilyView: View {
    @State private var viewModel: CreateFamilyViewModel

    public init(viewModel: CreateFamilyViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            Section {
                TextField("Your name", text: $viewModel.parentGivenName)
                    .textContentType(.givenName)
                    .accessibilityIdentifier("onboarding.parentNameField")
                    .accessibilityLabel(Text("Your name"))
                if let error = viewModel.parentGivenNameError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("onboarding.parentNameField.error")
                }
            } header: {
                VoxtrSectionHeading("Your name")
            }
            .voxtrRowSurface()

            Section {
                TextField("Athlete's name", text: $viewModel.athleteGivenName)
                    .textContentType(.givenName)
                    .accessibilityIdentifier("onboarding.athleteNameField")
                    .accessibilityLabel(Text("Athlete's name"))
                if let error = viewModel.athleteGivenNameError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("onboarding.athleteNameField.error")
                }

                DatePicker(
                    "Birth date",
                    selection: $viewModel.athleteBirthDate,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("onboarding.athleteBirthDatePicker")
                .accessibilityLabel(Text("Athlete's birth date"))
                if let error = viewModel.athleteBirthDateError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("onboarding.athleteBirthDatePicker.error")
                }

                Picker("Development stage", selection: $viewModel.athleteDevelopmentStage) {
                    Text("Parent-led").tag(DevelopmentStage.parentLed)
                    Text("Shared ownership").tag(DevelopmentStage.sharedOwnership)
                    Text("Guided independence").tag(DevelopmentStage.guidedIndependence)
                    Text("Athlete-led").tag(DevelopmentStage.athleteLed)
                }
                .accessibilityIdentifier("onboarding.developmentStagePicker")
                .accessibilityLabel(Text("Development stage"))
            } header: {
                VoxtrSectionHeading("Athlete")
            }
            .voxtrRowSurface()

            if let submissionError = viewModel.submissionError {
                Section {
                    Text(submissionError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("onboarding.submissionError")
                }
                .voxtrRowSurface()
            }

            Section {
                Button {
                    viewModel.submit()
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .accessibilityLabel(Text("Creating family"))
                    } else {
                        Text("Create family")
                    }
                }
                .disabled(viewModel.isSubmitting)
                .accessibilityIdentifier("onboarding.submitButton")
                .accessibilityLabel(Text("Create family"))
            }
            .voxtrRowSurface()
        }
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle("Welcome to Vǫxtr")
    }
}
