import Observation
import SwiftUI
import VoxtrCoreContracts
import VoxtrReflectionDomain
import VoxtrTrainingDomain

@MainActor
@Observable
final class LoggedActivityReviewViewModel {
    private(set) var loggedActivity: LoggedActivity
    private(set) var activityReflection: ActivityReflection?
    private(set) var errorMessage: String?

    var editDurationMinutes: Int
    var editPerceivedExertion: Int?
    var editSessionForm: Int?

    let athleteDisplayName: String
    private let athleteId: AthleteId
    private let actorId: ActorId
    private let coordinationService: TrainingReflectionCoordinationService
    private let onActivityChanged: () -> Void

    init(
        detail: LoggedActivityDetail,
        athleteId: AthleteId,
        athleteDisplayName: String,
        actorId: ActorId,
        coordinationService: TrainingReflectionCoordinationService,
        onActivityChanged: @escaping () -> Void = {}
    ) {
        loggedActivity = detail.loggedActivity
        activityReflection = detail.reflection
        editDurationMinutes = detail.loggedActivity.durationMinutes
        editPerceivedExertion = detail.loggedActivity.perceivedExertion
        editSessionForm = detail.reflection?.visibility == .privateToAthlete
            ? nil
            : detail.reflection?.bodyFeeling
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.actorId = actorId
        self.coordinationService = coordinationService
        self.onActivityChanged = onActivityChanged
    }

    var formValue: Int? {
        guard let activityReflection,
              activityReflection.visibility != .privateToAthlete else { return nil }
        return activityReflection.bodyFeeling
    }

    var canEditDuration: Bool {
        TrainingValidator.requiresActualDuration(for: loggedActivity.status)
    }

    func prefillEditForm() {
        editDurationMinutes = loggedActivity.durationMinutes
        editPerceivedExertion = loggedActivity.perceivedExertion
        editSessionForm = formValue
        errorMessage = nil
    }

    @discardableResult
    func saveEdit() -> Bool {
        errorMessage = nil
        if let durationError = TrainingValidator.validateActualDuration(
            editDurationMinutes,
            for: loggedActivity.status
        ) {
            errorMessage = durationError
            return false
        }
        if let formError = TrainingValidator.validateForm(editSessionForm, for: loggedActivity.status) {
            errorMessage = formError
            return false
        }
        do {
            let result = try coordinationService.correctLoggedActivity(
                loggedActivityId: loggedActivity.loggedActivityId,
                athleteId: athleteId,
                authorId: actorId,
                durationMinutes: editDurationMinutes,
                perceivedExertion: editPerceivedExertion,
                sessionForm: editSessionForm
            )
            loggedActivity = result.loggedActivity
            if case .saved(let reflection) = result.sessionFormOutcome {
                activityReflection = reflection
            }
            if case .failed = result.sessionFormOutcome {
                errorMessage = "Duration and RPE saved. Form could not be saved — tap Save to try again."
                return false
            }
            onActivityChanged()
            return true
        } catch {
            errorMessage = TrainingStrings.genericError
            return false
        }
    }
}

/// Review composition for a canonical LoggedActivity. It deliberately
/// does not require a PlannedActivity, so manual standalone logs remain
/// first-class inspectable Training truth.
struct LoggedActivityReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: LoggedActivityReviewViewModel
    @State private var isEditing = false

    init(viewModel: LoggedActivityReviewViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("loggedActivityDetail.errorMessage")
                }
                .voxtrRowSurface()
            }

            Section {
                LabeledContent("Athlete", value: viewModel.athleteDisplayName)
                LabeledContent(
                    "Activity",
                    value: ActivityLabelResolver(modelContext: modelContext)
                        .primaryLabel(for: viewModel.loggedActivity)
                )
                LabeledContent(
                    "Identity",
                    value: ActivityLabelResolver(modelContext: modelContext)
                        .metadataLabel(for: viewModel.loggedActivity)
                )
                LabeledContent("Outcome", value: Self.statusText(viewModel.loggedActivity.status))
                LabeledContent("Started", value: viewModel.loggedActivity.startedAt.formatted())
                if viewModel.canEditDuration {
                    LabeledContent("Actual duration", value: "\(viewModel.loggedActivity.durationMinutes) min")
                }
                if let rpe = viewModel.loggedActivity.perceivedExertion {
                    LabeledContent("RPE", value: "\(rpe) / 10")
                }
                if let form = viewModel.formValue {
                    LabeledContent("Form", value: "\(form) / 5")
                }
                if let notes = viewModel.loggedActivity.notes, !notes.isEmpty {
                    LabeledContent("Notes", value: notes)
                }
            }
            .voxtrRowSurface()
            .accessibilityIdentifier("loggedActivityDetail.summary")

            Section {
                Button("Edit Logged Activity") {
                    viewModel.prefillEditForm()
                    isEditing = true
                }
                .accessibilityIdentifier("loggedActivityDetail.editButton")
            }
            .voxtrRowSurface()
        }
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle(
            ActivityLabelResolver(modelContext: modelContext)
                .primaryLabel(for: viewModel.loggedActivity)
        )
        .sheet(isPresented: $isEditing) {
            LoggedActivityReviewEditView(viewModel: viewModel)
        }
    }

    private static func statusText(_ status: ActivityStatus) -> String {
        switch status {
        case .scheduled: return "Scheduled"
        case .completed: return "Completed"
        case .partiallyCompleted: return "Partially completed"
        case .missed: return "Missed"
        case .cancelled: return "Cancelled"
        }
    }
}

private struct LoggedActivityReviewEditView: View {
    @Bindable var viewModel: LoggedActivityReviewViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if viewModel.canEditDuration {
                    Stepper(
                        "Actual duration: \(viewModel.editDurationMinutes) min",
                        value: $viewModel.editDurationMinutes,
                        in: 1...1440
                    )
                }
                Picker("RPE", selection: $viewModel.editPerceivedExertion) {
                    Text("Not set").tag(Int?.none)
                    ForEach(1...10, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                if TrainingValidator.requiresForm(for: viewModel.loggedActivity.status) {
                    Picker("Form", selection: $viewModel.editSessionForm) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                }
            }
            .navigationTitle("Edit Logged Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if viewModel.saveEdit() { dismiss() }
                    }
                }
            }
        }
    }
}

struct LoggedActivityReviewViewLoader: View {
    let loggedActivityId: LoggedActivityId
    let athleteId: AthleteId
    let athleteDisplayName: String
    let actorId: ActorId
    let coordinationService: TrainingReflectionCoordinationService
    let onActivityChanged: () -> Void

    @State private var viewModel: LoggedActivityReviewViewModel?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let viewModel {
                LoggedActivityReviewView(viewModel: viewModel)
            } else if loadFailed {
                ContentUnavailableView("Activity unavailable", systemImage: "exclamationmark.circle")
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard viewModel == nil, !loadFailed else { return }
            do {
                let detail = try coordinationService.loggedActivityDetail(
                    loggedActivityId: loggedActivityId,
                    athleteId: athleteId
                )
                viewModel = LoggedActivityReviewViewModel(
                    detail: detail,
                    athleteId: athleteId,
                    athleteDisplayName: athleteDisplayName,
                    actorId: actorId,
                    coordinationService: coordinationService,
                    onActivityChanged: onActivityChanged
                )
            } catch {
                loadFailed = true
            }
        }
    }
}
