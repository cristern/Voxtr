import Foundation
import SwiftUI
import VoxtrCoreContracts
import VoxtrCoachingDomain
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
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle("\(athleteDisplayName) Weekly Review")
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
                NavigationStack {
                    WeeklyReflectionFormView(
                        viewModel: WeeklyReflectionFormViewModel(
                            service: reflectionService,
                            athleteId: viewModel.athleteId,
                            athleteDisplayName: athleteDisplayName,
                            weekStart: viewModel.weekStart,
                            authorId: authorId,
                            existing: result.weeklyReflection
                        ),
                        isModal: true
                    )
                }
            }
        }
    }

    private var header: some View {
        Section {
            Text(athleteDisplayName)
                .font(VoxtrTypography.cardTitle)
                .foregroundStyle(VoxtrColor.textPrimary)
                .accessibilityIdentifier("weeklyReview.athleteName")
            HStack {
                Button {
                    viewModel.switchToWeek(viewModel.weekStart.adding(days: -7))
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("weeklyReview.previousWeekButton")
                WeekIdentityView(
                    weekStart: viewModel.weekStart,
                    referenceWeekStart: WeeklyPlanningViewModel.currentWeekStart()
                )
                Button {
                    viewModel.switchToWeek(viewModel.weekStart.adding(days: 7))
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.weekStart.adding(days: 7) > WeeklyPlanningViewModel.currentWeekStart())
                .accessibilityIdentifier("weeklyReview.nextWeekButton")
            }
            .accessibilityIdentifier("weeklyReview.weekStart")
        }
        .voxtrRowSurface()
    }

    private func weekPlanSection(_ result: WeeklyReviewResult) -> some View {
        Section {
            if let weekPlan = result.weekPlan {
                Text(weekPlan.status == .committed ? "Committed" : "Draft")
                    .font(VoxtrTypography.body)
                    .foregroundStyle(VoxtrColor.textPrimary)
                    .accessibilityIdentifier("weeklyReview.weekPlanStatus")
            } else {
                Text(WeeklyReviewStrings.noWeekPlan)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("weeklyReview.noWeekPlan")
            }
        } header: {
            VoxtrSectionHeading("Weekly plan")
        }
        .voxtrRowSurface()
    }

    private func plannedActivitiesSection(_ result: WeeklyReviewResult) -> some View {
        Section {
            if result.plannedActivities.isEmpty {
                Text(WeeklyReviewStrings.noPlannedActivities)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("weeklyReview.noPlannedActivities")
            } else {
                ForEach(result.plannedActivities, id: \.plannedActivity.id) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        // Weekday-scan round: this row previously had
                        // no date/weekday text at all — the user could
                        // only infer which day an item belonged to from
                        // list position. Leads with the same canonical
                        // `weekdayLabel(for:)` formatter
                        // `WeeklyPlanningView`'s own planned-activity
                        // rows already use, derived from the SAME
                        // canonical `PlannedActivity.localDate` this
                        // section was already reading nothing else
                        // from.
                        Text(WeeklyPlanningView.weekdayLabel(for: item.plannedActivity.localDate.weekday))
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                        HStack {
                            Text(item.plannedActivity.title ?? "")
                                .font(VoxtrTypography.cardTitle)
                                .foregroundStyle(VoxtrColor.textPrimary)
                            Spacer()
                            // Review follow-up (duration/completion
                            // placeholder audit): `isGenuinelyCompleted`,
                            // not `isCompleted` — a Cancelled or Missed
                            // activity must never show as "Completed"
                            // here, the same fix already applied to
                            // Weekly History's equivalent row label.
                            Text(item.isGenuinelyCompleted ? TrainingStrings.completedLabel : TrainingStrings.notCompletedLabel)
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(item.isGenuinelyCompleted ? .green : VoxtrColor.textSecondary)
                                .accessibilityLabel(
                                    Text(item.isGenuinelyCompleted ? TrainingStrings.completedLabel : TrainingStrings.notCompletedLabel)
                                )
                        }
                        // Planned -> actual, using the exact same
                        // PlannedActivity<->LoggedActivity relationship
                        // TrainingPlanningCoordinationService already
                        // derives completion from — never a second,
                        // separate lookup, never inferred from matching
                        // title/date. Only shown when it exists; kept
                        // to the two fields this work package names
                        // (actual duration, RPE), not everything the
                        // model happens to have.
                        if let loggedActivity = item.loggedActivity {
                            Text(Self.actualSubtitle(for: loggedActivity))
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("weeklyReview.plannedActivityRow.\(item.plannedActivity.id.uuidString)")
                }
            }
        } header: {
            VoxtrSectionHeading("Planned activities")
        }
        .voxtrRowSurface()
    }

    /// Review follow-up (duration/logged-consumer audit): duration and
    /// RPE are presented as "Actual: ..." only for outcomes where
    /// something genuinely happened (`.completed`/`.partiallyCompleted`)
    /// — `LoggedActivity.durationMinutes` for `.missed`/`.cancelled` is
    /// the schema's own non-optional-`Int` placeholder (always `1`,
    /// never a real measurement; see `TrainingService.logActivity`'s
    /// own doc comment on this exact convention), and must never be
    /// presented as if it were factual "Actual" training data. RPE is
    /// never collected for either outcome either (nothing to rate), so
    /// this covers both fields the same way.
    private static func actualSubtitle(for loggedActivity: LoggedActivity) -> String {
        switch loggedActivity.status {
        case .completed, .partiallyCompleted:
            var parts = ["\(loggedActivity.durationMinutes) min"]
            if let rpe = loggedActivity.perceivedExertion {
                parts.append("RPE \(rpe)")
            }
            return "Actual: " + parts.joined(separator: " · ")
        case .missed:
            return "Missed"
        case .cancelled:
            return "Cancelled"
        case .scheduled:
            return "Scheduled"
        }
    }

    private func loggedActivitiesSection(_ result: WeeklyReviewResult) -> some View {
        Section {
            if result.loggedActivities.isEmpty {
                Text(WeeklyReviewStrings.noLoggedActivities)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("weeklyReview.noLoggedActivities")
            } else {
                ForEach(result.loggedActivities, id: \.id) { activity in
                    VStack(alignment: .leading, spacing: 2) {
                        // Weekday-scan round: same principle as
                        // `plannedActivitiesSection` above — a leading
                        // weekday caption so both sections read the
                        // same way. `LoggedActivity.startedAt` is a
                        // `Date`, not a `LocalDate` (unlike
                        // `PlannedActivity`), so this is derived via
                        // `Self.localDate(for:)` below, which is the
                        // existing domain contract already used
                        // elsewhere in this app for this exact
                        // `Date` -> `LocalDate` conversion — see that
                        // helper's own doc comment.
                        Text(WeeklyPlanningView.weekdayLabel(for: Self.localDate(for: activity.startedAt).weekday))
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                        Text(activity.title ?? "")
                            .font(VoxtrTypography.cardTitle)
                            .foregroundStyle(VoxtrColor.textPrimary)
                        // Review follow-up (duration/logged-consumer
                        // audit): reuses the SAME `actualSubtitle`
                        // outcome-aware text `plannedActivitiesSection`
                        // above already uses — a Cancelled/Missed entry
                        // here must show its outcome, never its
                        // placeholder duration presented as if real.
                        Text(Self.actualSubtitle(for: activity))
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                    }
                    .accessibilityIdentifier("weeklyReview.loggedActivityRow.\(activity.id.uuidString)")
                }
            }
        } header: {
            VoxtrSectionHeading("Logged activities")
        }
        .voxtrRowSurface()
    }

    /// Weekday-scan round: `LoggedActivity.startedAt` is a `Date`
    /// (a real instant, needed for lifecycle/ordering elsewhere), not a
    /// `LocalDate` — this derives the calendar day it falls on using
    /// the SAME `calendar.dateComponents([.year, .month, .day], from:)`
    /// technique `TrainingPlanningCoordinationService.today(referenceDate:)`/
    /// `.weekStart(referenceDate:)` already establish for this exact
    /// `Date` -> `LocalDate` conversion — not a new algorithm, just
    /// applied here to a logged activity's own start time rather than
    /// "now". Kept local to this file (rather than reusing
    /// `.today(referenceDate:)` directly) since calling something named
    /// "today" with an arbitrary past date would read as a mistake even
    /// though it's mechanically identical. Internal, not `private` — so
    /// this conversion is directly unit-testable (see
    /// `WeeklyReviewViewModelTests`).
    static func localDate(for date: Date, calendar: Calendar = .current) -> LocalDate {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    private func reflectionSection(_ result: WeeklyReviewResult) -> some View {
        Section {
            if let reflection = result.weeklyReflection {
                if let satisfaction = reflection.overallSatisfaction {
                    Text("Overall satisfaction: \(satisfaction)/5")
                        .font(VoxtrTypography.body)
                        .foregroundStyle(VoxtrColor.textPrimary)
                }
                if let learning = reflection.learning {
                    Text(learning)
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                }
            } else {
                Text(WeeklyReviewStrings.noReflection)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("weeklyReview.noReflection")
            }

            Button(result.weeklyReflection == nil ? WeeklyReviewStrings.startReflectionAction : WeeklyReviewStrings.editReflectionAction) {
                isShowingReflectionForm = true
            }
            .accessibilityIdentifier("weeklyReview.reflectionAction")
            .accessibilityLabel(
                Text(result.weeklyReflection == nil ? WeeklyReviewStrings.startReflectionAction : WeeklyReviewStrings.editReflectionAction)
            )
        } header: {
            VoxtrSectionHeading("Weekly reflection")
        }
        .voxtrRowSurface()
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
    ///
    /// Sprint 10: each item may also render one action button. This
    /// view decides nothing about WHICH action belongs to an item — it
    /// only reads `item.action`, already assigned by
    /// `CoachingPresentationMapper`, and switches on THAT (three cases,
    /// `CoachingPresentationAction`) rather than on `CoachingInsight`.
    @ViewBuilder
    private var coachingSection: some View {
        switch viewModel.coachingPresentationState {
        case .loading:
            EmptyView()
        case .failed:
            Section {
                Text(CoachingPresentationStrings.unavailable)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("weeklyReview.coaching.unavailable")
            }
            .voxtrRowSurface()
        case .loaded(let presentation):
            if presentation.sections.isEmpty {
                EmptyView()
            } else {
                ForEach(presentation.sections, id: \.title) { section in
                    Section {
                        ForEach(section.items, id: \.insight) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.text)
                                    .font(VoxtrTypography.body)
                                    .foregroundStyle(Self.color(for: item.emphasis))
                                actionButton(for: item)
                            }
                            .accessibilityIdentifier("weeklyReview.coaching.item.\(item.insight.rawValue)")
                        }
                    } header: {
                        VoxtrSectionHeading(section.title)
                    }
                    .voxtrRowSurface()
                }
            }
        }
    }

    /// The ONLY place `CoachingPresentationAction` is translated into an
    /// actual control. `.none` renders nothing extra.
    /// `.startWeeklyReflection` reuses the SAME existing reflection form
    /// already wired above (`isShowingReflectionForm`) — a real,
    /// already-functional workflow, not a new one.
    /// `.addParentObservation` has no creation flow anywhere in this
    /// project yet (verified before implementing); per Sprint 10's own
    /// instruction to expose the action while keeping the UI minimal
    /// rather than inventing the missing workflow, this renders a
    /// visible but disabled button — the action's existence is shown,
    /// nothing is pretended to work that doesn't yet.
    @ViewBuilder
    private func actionButton(for item: CoachingPresentationItem) -> some View {
        switch item.action {
        case .none:
            EmptyView()
        case .startWeeklyReflection:
            Button(WeeklyReviewStrings.startReflectionAction) {
                isShowingReflectionForm = true
            }
            .font(VoxtrTypography.metadata)
            .accessibilityIdentifier("weeklyReview.coaching.action.startWeeklyReflection")
        case .addParentObservation:
            Button(CoachingPresentationStrings.addParentObservationAction) {}
                .font(VoxtrTypography.metadata)
                .disabled(true)
                .accessibilityIdentifier("weeklyReview.coaching.action.addParentObservation")
        }
    }

    /// The ONLY place `CoachingPresentationEmphasis` is translated into
    /// an actual visual treatment — per Sprint 9's architecture rule,
    /// this mapping belongs at the UI/design-system boundary, never in
    /// `CoachingPresentation` itself.
    ///
    /// `.attention` is deliberately NOT `.red` — this project already
    /// avoids alarm-coded color for "incomplete" states (see
    /// `plannedActivitiesSection` above: not-completed uses the plain
    /// `VoxtrColor.textSecondary` token, not red). `.attention` here uses `.orange` instead
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
