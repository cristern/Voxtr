import SwiftUI
import VoxtrCoreContracts
import VoxtrReflectionDomain

/// Sprint 13: renders one `DailyFocusPresentation` (or an empty/hidden
/// state). Meant to be embedded as a `Section` inside a parent `Form`
/// already wrapped in its own `NavigationStack` — `HomeDashboardView`,
/// in practice — so this view owns no navigation container of its own.
///
/// Reuses `WeeklyReviewView` for `.startWeeklyReflection` navigation —
/// no new screen is created here. `.addParentObservation` mirrors
/// `WeeklyReviewView.actionButton(for:)`'s existing Sprint 10 treatment
/// exactly: a visible but disabled button, since no creation UI exists
/// for it anywhere in this project (unchanged since Sprint 10 — still
/// true, not re-verified by inventing a workflow here).
public struct DailyFocusCardView: View {
    @State private var viewModel: DailyFocusViewModel
    private let athleteDisplayName: String
    private let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    private let weeklyReflectionService: WeeklyReflectionService
    private let coachingApplicationService: CoachingApplicationService
    private let athleteId: AthleteId
    private let committedByActorId: ActorId

    public init(
        viewModel: DailyFocusViewModel,
        athleteDisplayName: String,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteId: AthleteId,
        committedByActorId: ActorId
    ) {
        _viewModel = State(initialValue: viewModel)
        self.athleteDisplayName = athleteDisplayName
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteId = athleteId
        self.committedByActorId = committedByActorId
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                EmptyView()
            case .failed:
                // Both underlying loads failed — hide the card
                // entirely, per this sprint's explicit requirement. No
                // fallback content is invented.
                EmptyView()
            case .loaded(let focus):
                if let focus {
                    focusSection(focus)
                } else {
                    emptyStateSection
                }
            }
        }
        .onAppear {
            viewModel.load()
        }
    }

    private func focusSection(_ focus: DailyFocusPresentation) -> some View {
        Section("Daily Focus") {
            Text(focus.title)
                .accessibilityIdentifier("dailyFocus.title")
            Text(focus.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("dailyFocus.subtitle")
            actionButton(for: focus.action)
        }
    }

    private var emptyStateSection: some View {
        Section("Daily Focus") {
            Text(DailyFocusStrings.nothingNeedsAttention)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("dailyFocus.empty")
        }
    }

    @ViewBuilder
    private func actionButton(for action: CoachingPresentationAction) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .startWeeklyReflection:
            NavigationLink(WeeklyReviewStrings.startReflectionAction) {
                WeeklyReviewView(
                    viewModel: WeeklyReviewViewModel(
                        coordinationService: weeklyReviewCoordinationService,
                        coachingPresentationProvider: coachingApplicationService,
                        athleteId: athleteId,
                        weekStart: viewModel.weekStart
                    ),
                    athleteDisplayName: athleteDisplayName,
                    reflectionService: weeklyReflectionService,
                    authorId: committedByActorId
                )
            }
            .accessibilityIdentifier("dailyFocus.action.startWeeklyReflection")
        case .addParentObservation:
            Button(CoachingPresentationStrings.addParentObservationAction) {}
                .disabled(true)
                .accessibilityIdentifier("dailyFocus.action.addParentObservation")
        }
    }
}
