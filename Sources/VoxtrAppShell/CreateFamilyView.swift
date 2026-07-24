import SwiftUI
import VoxtrCoreContracts

/// S1.4: the parent onboarding form. Deliberately minimal — parent name,
/// athlete name, birth date, development stage. No CloudKit, no Weekly
/// Review, no notifications; those are explicitly out of scope.
public struct CreateFamilyView: View {
    @State private var viewModel: CreateFamilyViewModel

    public init(viewModel: CreateFamilyViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            Section("Your name") {
                TextField("Your name", text: $viewModel.parentGivenName)
                    .textContentType(.givenName)
                if let error = viewModel.parentGivenNameError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Athlete") {
                TextField("Athlete's name", text: $viewModel.athleteGivenName)
                    .textContentType(.givenName)
                if let error = viewModel.athleteGivenNameError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                DatePicker(
                    "Birth date",
                    selection: $viewModel.athleteBirthDate,
                    displayedComponents: .date
                )
                if let error = viewModel.athleteBirthDateError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Picker("Development stage", selection: $viewModel.athleteDevelopmentStage) {
                    Text("Parent-led").tag(DevelopmentStage.parentLed)
                    Text("Shared ownership").tag(DevelopmentStage.sharedOwnership)
                    Text("Guided independence").tag(DevelopmentStage.guidedIndependence)
                    Text("Athlete-led").tag(DevelopmentStage.athleteLed)
                }
            }

            if let submissionError = viewModel.submissionError {
                Section {
                    Text(submissionError)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    viewModel.submit()
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView()
                    } else {
                        Text("Create family")
                    }
                }
                .disabled(viewModel.isSubmitting)
            }
        }
        .navigationTitle("Welcome to Vǫxtr")
    }
}
