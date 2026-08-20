import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// S3.3: first functional Daily Training UI. Deliberately unpolished —
/// mirrors `WeeklyPlanningView`'s style. All state changes go through
/// `DailyTrainingViewModel`, which itself only calls `TrainingService`/
/// `TrainingPlanningCoordinationService` — this view holds no business
/// logic.
public struct DailyTrainingView: View {
    @State private var viewModel: DailyTrainingViewModel
    @State private var recurringManagementSheetItem: RecurringManagementSheetItem?
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    private let actorId: ActorId
    private let athleteDisplayName: String

    public init(
        viewModel: DailyTrainingViewModel,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        actorId: ActorId,
        athleteDisplayName: String
    ) {
        _viewModel = State(initialValue: viewModel)
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.actorId = actorId
        self.athleteDisplayName = athleteDisplayName
    }

    public var body: some View {
        ScrollViewReader { proxy in
            Form {
                // Sprint 1.2B runtime closeout: an invisible top anchor
                // for the scroll-to-top-after-logging fix below — zero
                // height, never visible, exists only as a scroll target.
                Color.clear.frame(height: 0).id("dailyTraining.top")

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("training.errorMessage")
                    }
                    .voxtrRowSurface()
                }

                Section {
                    if viewModel.plannedActivities.isEmpty {
                        Text(TrainingStrings.noPlannedActivitiesToday)
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                    } else {
                        ForEach(viewModel.plannedActivities, id: \.plannedActivity.id) { item in
                            NavigationLink {
                                ActivityDetailViewLoader(
                                plannedActivity: item.plannedActivity,
                                athleteId: viewModel.athleteId,
                                athleteDisplayName: athleteDisplayName,
                                actorId: actorId,
                                planningService: planningService,
                                trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                                onActivityLogged: { viewModel.load() }
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.plannedActivity.title ?? "")
                                        .font(VoxtrTypography.cardTitle)
                                        .foregroundStyle(VoxtrColor.textPrimary)
                                    if let location = item.plannedActivity.location, !location.isEmpty {
                                        Text(location)
                                            .font(VoxtrTypography.metadata)
                                            .foregroundStyle(VoxtrColor.textSecondary)
                                    }
                                }
                                Spacer()
                                // Review follow-up (duration/completion
                                // placeholder audit): `isGenuinelyCompleted`,
                                // not `isCompleted` — the same fix
                                // already applied to Weekly Review/
                                // History's equivalent row label. A
                                // Cancelled or Missed activity must
                                // never show as "Completed" here.
                                //
                                // Status/outcome colour audit: `.green`
                                // is kept as the literal semantic
                                // "genuinely completed" colour (same
                                // meaning `ActivityDetailView`'s own
                                // `outcomeIndicatorColor` already
                                // establishes) — no `VoxtrColor` token
                                // represents this state, and none is
                                // invented here; only the neutral case
                                // moves to the `VoxtrColor` token.
                                Text(item.isGenuinelyCompleted ? TrainingStrings.completedLabel : TrainingStrings.notCompletedLabel)
                                    .font(VoxtrTypography.metadata)
                                    .foregroundStyle(item.isGenuinelyCompleted ? .green : VoxtrColor.textSecondary)
                            }
                        }
                        .accessibilityIdentifier("training.plannedActivityRow.\(item.plannedActivity.id.uuidString)")
                    }
                    }
                } header: {
                    VoxtrSectionHeading("Today's planned activities")
                }
                .voxtrRowSurface()
                .accessibilityIdentifier("training.plannedActivitiesList")

                if !viewModel.recurringOccurrences.isEmpty {
                    Section {
                        ForEach(viewModel.recurringOccurrences, id: \.id) { suggestion in
                            NavigationLink {
                                RecurringOccurrencePreviewView(
                                    suggestion: suggestion,
                                    athleteDisplayName: athleteDisplayName,
                                    planningService: planningService,
                                    trainingService: trainingService,
                                    trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                                    actorId: actorId,
                                    onActivityLogged: { viewModel.load() }
                                )
                            } label: {
                                HStack {
                                    Text(suggestion.title ?? "")
                                        .font(VoxtrTypography.cardTitle)
                                        .foregroundStyle(VoxtrColor.textPrimary)
                                    Spacer()
                                    Text("Recurring")
                                        .font(VoxtrTypography.metadata)
                                        .foregroundStyle(VoxtrColor.textSecondary)
                                }
                            }
                            .accessibilityIdentifier("training.recurringOccurrenceRow.\(suggestion.id)")
                        }
                    } header: {
                        VoxtrSectionHeading("Today's recurring activities")
                    }
                    .voxtrRowSurface()
                    .accessibilityIdentifier("training.recurringOccurrencesList")
                }

                Section {
                    if viewModel.loggedActivities.isEmpty {
                        Text(TrainingStrings.noLoggedActivitiesToday)
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                    } else {
                        ForEach(viewModel.loggedActivities, id: \.id) { activity in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.title ?? "")
                                    .font(VoxtrTypography.cardTitle)
                                    .foregroundStyle(VoxtrColor.textPrimary)
                                // Review follow-up (duration/logged-consumer
                                // audit): a Cancelled/Missed entry must show
                                // its outcome, never present its schema
                                // placeholder duration as if it were real
                                // training time.
                                Text(Self.durationOrOutcomeSubtitle(for: activity))
                                    .font(VoxtrTypography.metadata)
                                    .foregroundStyle(VoxtrColor.textSecondary)
                            }
                            .accessibilityIdentifier("training.loggedActivityRow.\(activity.id.uuidString)")
                        }
                    }
                } header: {
                    VoxtrSectionHeading("Today's logged activities")
                }
                .voxtrRowSurface()
                .accessibilityIdentifier("training.loggedActivitiesList")

                Section {
                    TextField("Title", text: $viewModel.newLogTitle)
                        .accessibilityIdentifier("training.newLogTitleField")

                    Picker("Activity type", selection: $viewModel.newLogActivityType) {
                        Text("Team training").tag(ActivityType.teamTraining)
                        Text("Match").tag(ActivityType.match)
                        Text("Competition").tag(ActivityType.competition)
                        Text("Individual training").tag(ActivityType.individualTraining)
                        Text("Strength").tag(ActivityType.strength)
                        Text("Conditioning").tag(ActivityType.conditioning)
                        Text("Recovery").tag(ActivityType.recovery)
                        Text("Test").tag(ActivityType.test)
                        Text("Other").tag(ActivityType.other)
                    }
                    .accessibilityIdentifier("training.newLogActivityTypePicker")

                    DatePicker("Started at", selection: $viewModel.newLogStartedAt)
                        .accessibilityIdentifier("training.newLogStartedAtPicker")

                    DurationPickerView(durationMinutes: $viewModel.newLogDurationMinutes)

                    Picker("RPE", selection: $viewModel.newLogPerceivedExertion) {
                        Text("Not set").tag(Int?.none)
                        ForEach(1...10, id: \.self) { value in
                            Text("\(value)").tag(Int?.some(value))
                        }
                    }
                    .accessibilityIdentifier("training.newLogExertionPicker")

                    // VX-022: "Form" — required for every log through this
                    // flow (always a completed session). Neutral 1-5 scale,
                    // no failure/success labeling, no scoring or readiness
                    // language, same Picker shape as RPE above. No "Not
                    // set" option — Form is required, not optional.
                    Picker("Form", selection: $viewModel.newLogSessionForm) {
                        ForEach(1...5, id: \.self) { value in
                            Text("\(value)").tag(Int?.some(value))
                        }
                    }
                    .accessibilityIdentifier("training.newLogSessionFormPicker")

                    TextField("Notes", text: $viewModel.newLogNotes)
                        .accessibilityIdentifier("training.newLogNotesField")

                    // Requirement: allow linking only to an UNCOMPLETED
                    // PlannedActivity — completed ones are shown (for
                    // context) but disabled, not hidden.
                    Picker("Link to planned activity", selection: $viewModel.selectedPlannedActivityId) {
                        Text(TrainingStrings.noneOptionLabel).tag(PlannedActivityId?.none)
                        ForEach(viewModel.plannedActivities, id: \.plannedActivity.id) { item in
                            Text(item.plannedActivity.title ?? "")
                                .tag(Optional(item.plannedActivity.plannedActivityId))
                                .disabled(item.isCompleted)
                        }
                    }
                    .accessibilityIdentifier("training.linkPlannedActivityPicker")

                    Button {
                        viewModel.logActivity()
                    } label: {
                        if viewModel.isSubmitting {
                            ProgressView()
                        } else {
                            Text("Log activity")
                        }
                    }
                    .disabled(viewModel.isSubmitting)
                    .accessibilityIdentifier("training.logActivityButton")
                } header: {
                    VoxtrSectionHeading("Log an activity")
                }
                .voxtrRowSurface()

                Section {
                    Button("Manage Recurring Activities") {
                        let recurringViewModel = WeeklyPlanningViewModel(
                            service: planningService,
                            athleteId: viewModel.athleteId,
                            committedByActorId: actorId
                        )
                        recurringViewModel.loadRecurringActivities()
                        recurringManagementSheetItem = RecurringManagementSheetItem(viewModel: recurringViewModel)
                    }
                    .accessibilityIdentifier("training.manageRecurringActivitiesButton")
                }
                .voxtrRowSurface()
            }
            .voxtrScreenBackground()
            .tint(VoxtrColor.accent)
            .navigationTitle("\(athleteDisplayName) Daily Training")
            .onAppear {
                viewModel.load()
            }
            .sheet(item: $recurringManagementSheetItem) { item in
                RecurringActivityManagementView(viewModel: item.viewModel, athleteDisplayName: athleteDisplayName)
            }
            .onChange(of: viewModel.successfulLogTrigger) { _, _ in
                // Only fires when a log genuinely succeeded (see
                // successfulLogTrigger's own doc comment) — never on
                // validation failure, persistence failure, or opening the
                // form. withAnimation is optional polish, not required for
                // correctness; native ScrollViewReader.scrollTo is the
                // actual mechanism, no timing hacks.
                withAnimation {
                    proxy.scrollTo("dailyTraining.top", anchor: .top)
                }
            }
        }
    }

    /// Review follow-up (duration/logged-consumer audit): duration is
    /// shown only for outcomes where something genuinely happened
    /// (`.completed`/`.partiallyCompleted`) — `LoggedActivity.durationMinutes`
    /// for `.missed`/`.cancelled` is the schema's own non-optional-`Int`
    /// placeholder (always `1`, never a real measurement), and must
    /// never be presented as if it were factual training time.
    private static func durationOrOutcomeSubtitle(for activity: LoggedActivity) -> String {
        switch activity.status {
        case .completed, .partiallyCompleted:
            return "\(activity.durationMinutes) min"
        case .missed:
            return "Missed"
        case .cancelled:
            return "Cancelled"
        case .scheduled:
            return "Scheduled"
        }
    }
}

/// Sprint 1.1 closeout, Item 4 (white-screen root cause fix): wraps
/// `WeeklyPlanningViewModel` for `.sheet(item:)` presentation.
///
/// Root cause: the previous implementation used two separate `@State`
/// variables — a `Bool` driving `.sheet(isPresented:)` and a separately
/// -set `WeeklyPlanningViewModel?` the sheet's content closure read via
/// `if let`. Both were set in the same button action, but nothing
/// guarantees SwiftUI evaluates the sheet's content closure only after
/// BOTH state updates are visible to it — `.sheet(isPresented:)`'s
/// content closure can be evaluated at the moment `isPresented` becomes
/// true, independent of whether a second, separately-tracked state
/// variable has "caught up" yet. When it hadn't, the `if let` fell
/// through with no `else`, and SwiftUI's `@ViewBuilder` renders that as
/// an implicit `EmptyView()` — a genuinely blank sheet. This exactly
/// matches "first attempt: white screen, second attempt: works" —  by
/// the second tap, the (never-reset) view model was already non-nil
/// from the first attempt, so the same race no longer mattered.
///
/// `HomeDashboardView`'s "Manage Athletes" sheet never had this bug: its
/// view model is a stored property, constructed once at `init` and
/// never nil, so there was nothing to race. This bug was specific to
/// this button's lazy, on-demand construction.
///
/// Fix: `.sheet(item:)` instead of `.sheet(isPresented:)` — presence
/// and content are now the SAME piece of state, so there is no window
/// where the sheet can be "presented" with no content to show.
private struct RecurringManagementSheetItem: Identifiable {
    let id = UUID()
    let viewModel: WeeklyPlanningViewModel
}
