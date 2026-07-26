import SwiftUI
import VoxtrCoreContracts
import VoxtrReflectionDomain

/// Sprint 13 (architecture correction): renders one already-derived
/// `DailyFocusLoadState`, passed in as a plain value by
/// `HomeDashboardView` — this type performs no loading of its own.
/// `HomeDashboardViewModel` is the single owner of dashboard data
/// loading; this view has no `@State`, holds no `ViewModel`, and calls
/// no application service. Meant to be embedded as a `Section` inside a
/// parent `Form` already wrapped in its own `NavigationStack` —
/// `HomeDashboardView`, in practice — so this view owns no navigation
/// container of its own.
///
/// Reuses `WeeklyReviewView` for `.startWeeklyReflection` navigation —
/// no new screen is created here.
///
/// CORRECTION: `.addParentObservation` no longer renders a disabled
/// button. No parent-observation creation flow exists anywhere in this
/// project, and a disabled control implying one is coming was flagged
/// as inconsistent with product intent. The underlying
/// `CoachingPresentationAction` value is still preserved on
/// `DailyFocusPresentation.action` for traceability — only the control
/// this view renders for it changed, to none at all, same as `.none`.
public struct DailyFocusCardView: View {
    let dailyFocusState: DailyFocusLoadState
    let athleteDisplayName: String
    let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    let weeklyReflectionService: WeeklyReflectionService
    let coachingApplicationService: CoachingApplicationService
    let athleteId: AthleteId
    let weekStart: LocalDate
    let committedByActorId: ActorId

    public init(
        dailyFocusState: DailyFocusLoadState,
        athleteDisplayName: String,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteId: AthleteId,
        weekStart: LocalDate,
        committedByActorId: ActorId
    ) {
        self.dailyFocusState = dailyFocusState
        self.athleteDisplayName = athleteDisplayName
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteId = athleteId
        self.weekStart = weekStart
        self.committedByActorId = committedByActorId
    }

    public var body: some View {
        switch dailyFocusState {
        case .loading:
            EmptyView()
        case .failed:
            // Both underlying sources failed — hide the card entirely,
            // per this feature's explicit requirement. No fallback
            // content is invented.
            EmptyView()
        case .loaded(let focus):
            if let focus {
                focusSection(focus)
            } else {
                emptyStateSection
            }
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
                        weekStart: weekStart
                    ),
                    athleteDisplayName: athleteDisplayName,
                    reflectionService: weeklyReflectionService,
                    authorId: committedByActorId
                )
            }
            .accessibilityIdentifier("dailyFocus.action.startWeeklyReflection")
        case .addParentObservation:
            // No creation flow exists — render no control at all,
            // rather than a disabled one implying otherwise.
            EmptyView()
        }
    }
}
