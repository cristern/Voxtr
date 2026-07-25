import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Sprint 5.2: presents one athlete's week for review. Deliberately
/// unpolished, mirroring `WeeklyPlanningView`/`DailyTrainingView`'s
/// style. Every value shown comes directly from
/// `WeeklyReviewViewModel.loadState`'s `WeeklyReviewResult` — this view
/// recomputes no completion state, no ordering, no date scoping.
public struct WeeklyReviewView: View {
    @State private var viewModel: WeeklyReviewViewModel
    @State private var isShowingReflectionForm = false
    private let athleteDisplayName: String
    private let reflectionService: WeeklyReflectionService
    private let authorId: ActorId

    public init(
        viewModel: WeeklyReviewViewModel,
        athleteDisplayName: String,
        reflectionService: WeeklyReflectionService,
        authorId: ActorId
    ) {
        _viewModel = State(initialValue: viewModel)
        self.athleteDisplayName = athleteDisplayName
        self.reflectionService = reflectionService
        self.authorId = authorId
    }

    public var body: some View {
        Form {
            header

            switch viewModel.loadState {
            case .loading:
                Section {
                    ProgressView()
                        .accessibilityIdentifier("weeklyReview.loadingIndicator")
                }
            case .failed:
                Section {
                    Text(WeeklyReviewStrings.genericError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("weeklyReview.errorMessage")
                }
            case .loaded(let result):
                weekPlanSection(result)
                plannedActivitiesSection(result)
                loggedActivitiesSection(result)
                reflectionSection(result)
            }

            coachingSection
        }
        .navigationTitle("Weekly Review")
        .onAppear {
            viewModel.load()
            viewModel.loadCoachingPresentation()
        }
        .sheet(isPresented: $isShowingReflectionForm, onDismiss: {
            // Requirement: reload after returning from the reflection
            // form, whether the user saved or cancelled — reloading on
            // any dismissal is simpler than tracking save-vs-cancel
            // separately, and idempotent if nothing actually changed.
            viewModel.load()
        }) {
            if case .loaded(let result) = viewModel.loadState {
                WeeklyReflectionFormView(
                    viewModel: WeeklyReflectionFormViewModel(
                        service: reflectionService,
                        athleteId: viewModel.athleteId,
                        weekStart: viewModel.weekStart,
                        authorId: authorId,
                        existing: result.weeklyReflection
                    )
                )
            }
        }
    }

    private var header: some View {
        Section {
            Text(athleteDisplayName)
                .accessibilityIdentifier("weeklyReview.athleteName")
            Text(viewModel.weekStart.isoString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("weeklyReview.weekStart")
        }
    }

    private func weekPlanSection(_ result: WeeklyReviewResult) -> some View {
        Section("Weekly plan") {
            if let weekPlan = result.weekPlan {
                Text(weekPlan.status == .committed ? "Committed" : "Draft")
                    .accessibilityIdentifier("weeklyReview.weekPlanStatus")
            } else {
                Text(WeeklyReviewStrings.noWeekPlan)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyReview.noWeekPlan")
            }
        }
    }

    private func plannedActivitiesSection(_ result: WeeklyReviewResult) -> some View {
        Section("Planned activities") {
            if result.plannedActivities.isEmpty {
                Text(WeeklyReviewStrings.noPlannedActivities)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyReview.noPlannedActivities")
            } else {
                ForEach(result.plannedActivities, id: \.plannedActivity.id) { item in
                    HStack {
                        Text(item.plannedActivity.title)
                        Spacer()
                        Text(item.isCompleted ? TrainingStrings.completedLabel : TrainingStrings.notCompletedLabel)
                            .font(.caption)
                            .foregroundStyle(item.isCompleted ? .green : .secondary)
                            .accessibilityLabel(
                                Text(item.isCompleted ? TrainingStrings.completedLabel : TrainingStrings.notCompletedLabel)
                            )
                    }
                    .accessibilityIdentifier("weeklyReview.plannedActivityRow.\(item.plannedActivity.id.uuidString)")
                }
            }
        }
    }

    private func loggedActivitiesSection(_ result: WeeklyReviewResult) -> some View {
        Section("Logged activities") {
            if result.loggedActivities.isEmpty {
                Text(WeeklyReviewStrings.noLoggedActivities)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyReview.noLoggedActivities")
            } else {
                ForEach(result.loggedActivities, id: \.id) { activity in
                    VStack(alignment: .leading) {
                        Text(activity.title)
                        Text("\(activity.durationMinutes) min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("weeklyReview.loggedActivityRow.\(activity.id.uuidString)")
                }
            }
        }
    }

    private func reflectionSection(_ result: WeeklyReviewResult) -> some View {
        Section("Weekly reflection") {
            if let reflection = result.weeklyReflection {
                if let satisfaction = reflection.overallSatisfaction {
                    Text("Overall satisfaction: \(satisfaction)/5")
                }
                if let learning = reflection.learning {
                    Text(learning)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(WeeklyReviewStrings.noReflection)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyReview.noReflection")
            }

            Button(result.weeklyReflection == nil ? WeeklyReviewStrings.startReflectionAction : WeeklyReviewStrings.editReflectionAction) {
                isShowingReflectionForm = true
            }
            .accessibilityIdentifier("weeklyReview.reflectionAction")
            .accessibilityLabel(
                Text(result.weeklyReflection == nil ? WeeklyReviewStrings.startReflectionAction : WeeklyReviewStrings.editReflectionAction)
            )
        }
    }

    /// Sprint 9: the coaching integration. Never switches on
    /// `CoachingInsight` — everything it reads (`section.title`,
    /// `item.text`, `item.emphasis`) already comes fully formed from
    /// `CoachingPresentationMapper`. `.loading` produces no visible
    /// change if `.failed` follows quickly, `.failed` renders a single
    /// calm, non-blocking line (the rest of the screen already loaded
    /// independently — see `WeeklyReviewViewModel.loadCoachingPresentation`),
    /// and an empty `.loaded` presentation renders nothing at all — no
    /// section, no placeholder text — per the explicit rule against
    /// inventing a success message `CoachingResult` never represented.
    @ViewBuilder
    private var coachingSection: some View {
        switch viewModel.coachingPresentationState {
        case .loading:
            EmptyView()
        case .failed:
            Section {
                Text(CoachingPresentationStrings.unavailable)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyReview.coaching.unavailable")
            }
        case .loaded(let presentation):
            if presentation.sections.isEmpty {
                EmptyView()
            } else {
                ForEach(presentation.sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items, id: \.insight) { item in
                            Text(item.text)
                                .foregroundStyle(Self.color(for: item.emphasis))
                                .accessibilityIdentifier("weeklyReview.coaching.item.\(item.insight.rawValue)")
                        }
                    }
                }
            }
        }
    }

    /// The ONLY place `CoachingPresentationEmphasis` is translated into
    /// an actual visual treatment — per Sprint 9's architecture rule,
    /// this mapping belongs at the UI/design-system boundary, never in
    /// `CoachingPresentation` itself.
    ///
    /// `.attention` is deliberately NOT `.red` — this project already
    /// avoids alarm-coded color for "incomplete" states (see
    /// `plannedActivitiesSection` above: not-completed uses plain
    /// `.secondary`, not red). `.attention` here uses `.orange` instead
    /// — visually distinct from `.positive`/`.neutral` (so the emphasis
    /// actually carries meaning) while staying well short of the
    /// failure/danger/punishment/guilt read `.red` would risk. This is
    /// a UI judgment call, made here at the UI boundary where the
    /// architecture says it belongs, not a coaching threshold.
    private static func color(for emphasis: CoachingPresentationEmphasis) -> Color {
        switch emphasis {
        case .positive:
            return .green
        case .neutral:
            return .primary
        case .attention:
            return .orange
        }
    }
}
