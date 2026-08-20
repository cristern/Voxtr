import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Area 6: "Week by Week" — presents ONE historical week's factual
/// truth. Deliberately no hero percentage/score (e.g. never "83%
/// achieved") — only plain counts, per the approved contract. No
/// sibling comparison, no ratings, no gamification.
public struct WeeklyHistoryView: View {
    @State private var viewModel: WeeklyHistoryViewModel
    @State private var isShowingReflectionForm = false
    let athleteDisplayName: String
    let reflectionService: WeeklyReflectionService
    let authorId: ActorId

    public init(
        viewModel: WeeklyHistoryViewModel,
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
            Section {
                Text(athleteDisplayName)
                    .font(VoxtrTypography.cardTitle)
                    .foregroundStyle(VoxtrColor.textPrimary)
                    .accessibilityIdentifier("weeklyHistory.athleteName")
                HStack {
                    Button {
                        viewModel.switchToWeek(viewModel.weekStart.adding(days: -7))
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("weeklyHistory.previousWeekButton")
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
                    .accessibilityIdentifier("weeklyHistory.nextWeekButton")
                }
            }
            .voxtrRowSurface()
            .accessibilityIdentifier("weeklyHistory.weekIdentityBar")

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
                .voxtrRowSurface()
            }

            Section {
                LabeledContent("Planned", value: "\(viewModel.plannedCount)")
                    .accessibilityIdentifier("weeklyHistory.plannedCount")
                LabeledContent("Completed from plan", value: "\(viewModel.completedFromPlanCount)")
                    .accessibilityIdentifier("weeklyHistory.completedCount")
                LabeledContent("Additional", value: "\(viewModel.additionalCount)")
                    .accessibilityIdentifier("weeklyHistory.additionalCount")
            } header: {
                VoxtrSectionHeading("What happened")
            }
            .voxtrRowSurface()

            if let plannedActivities = viewModel.result?.plannedActivities, !plannedActivities.isEmpty {
                Section {
                    ForEach(plannedActivities, id: \.plannedActivity.id) { completion in
                        HStack {
                            Text(completion.plannedActivity.title)
                                .font(VoxtrTypography.cardTitle)
                                .foregroundStyle(VoxtrColor.textPrimary)
                            Spacer()
                            // Review follow-up (cancellation sanity
                            // check): the outcome, not a blanket
                            // "Completed" — a cancelled or missed
                            // planned activity must be shown as such,
                            // never mislabeled as Completed. `nil` when
                            // nothing has been logged at all yet (still
                            // possible for a past week the athlete
                            // never logged).
                            if let status = completion.loggedActivity?.status {
                                Text(Self.outcomeLabel(for: status))
                                    .font(VoxtrTypography.metadata)
                                    .foregroundStyle(VoxtrColor.textSecondary)
                            }
                        }
                    }
                } header: {
                    VoxtrSectionHeading("Planned activities")
                }
                .voxtrRowSurface()
                .accessibilityIdentifier("weeklyHistory.plannedActivitiesSection")
            }

            if !viewModel.additionalLoggedActivities.isEmpty {
                Section {
                    ForEach(viewModel.additionalLoggedActivities, id: \.id) { logged in
                        Text(logged.title)
                            .font(VoxtrTypography.cardTitle)
                            .foregroundStyle(VoxtrColor.textPrimary)
                    }
                } header: {
                    VoxtrSectionHeading("Additional (unplanned)")
                }
                .voxtrRowSurface()
                .accessibilityIdentifier("weeklyHistory.additionalActivitiesSection")
            }

            Section {
                switch viewModel.reflectionAccessState {
                case .visible(let reflection):
                    if let whatWorked = reflection.whatWorked, !whatWorked.isEmpty {
                        LabeledContent("What worked", value: whatWorked)
                    }
                    if let whatWasDifficult = reflection.whatWasDifficult, !whatWasDifficult.isEmpty {
                        LabeledContent("What was difficult", value: whatWasDifficult)
                    }
                    if let focus = viewModel.focusNextWeekIfPermitted, !focus.isEmpty {
                        LabeledContent("Focus next week", value: focus)
                    }
                    Button("Edit Reflection") {
                        isShowingReflectionForm = true
                    }
                    .accessibilityIdentifier("weeklyHistory.reflectionAction")
                case .none:
                    Text("No reflection yet")
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                        .accessibilityIdentifier("weeklyHistory.noReflection")
                    Button("Add Reflection") {
                        isShowingReflectionForm = true
                    }
                    .accessibilityIdentifier("weeklyHistory.reflectionAction")
                case .hiddenForPrivacy:
                    // Case C: a Reflection exists but is private to the
                    // athlete. Deliberately shows the SAME neutral text
                    // as the genuinely-missing case — never reveals
                    // that a private Reflection exists — but offers NO
                    // action at all: no Edit (would expose private
                    // content), and no Add (would attempt to create a
                    // competing/duplicate Reflection for this
                    // athlete/week, which already has one).
                    Text("No reflection yet")
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                        .accessibilityIdentifier("weeklyHistory.noReflection")
                }
            } header: {
                VoxtrSectionHeading("Reflection")
            }
            .voxtrRowSurface()
            .accessibilityIdentifier("weeklyHistory.reflectionSection")
        }
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle("Week by Week")
        .onAppear {
            viewModel.load()
        }
        // Issue 3: the EXISTING Reflection form, for the EXACT
        // selected historical week — never a duplicate form embedded
        // here. `onDismiss` reloads this screen's own read model, so a
        // newly saved/edited Reflection (and any Focus next week it
        // carries) is immediately visible, never stale pre-save
        // content.
        .sheet(isPresented: $isShowingReflectionForm, onDismiss: {
            viewModel.load()
        }) {
            NavigationStack {
                WeeklyReflectionFormView(
                    viewModel: WeeklyReflectionFormViewModel(
                        service: reflectionService,
                        athleteId: viewModel.athleteId,
                        athleteDisplayName: athleteDisplayName,
                        weekStart: viewModel.weekStart,
                        authorId: authorId,
                        existing: viewModel.result?.weeklyReflection
                    ),
                    isModal: true
                )
            }
        }
    }

    /// Review follow-up (cancellation sanity check): matches
    /// `ActivityDetailView`'s own outcome-label mapping — the plain
    /// canonical outcome, no color/interpretation added here (Weekly
    /// History's own "no hero score, no interpretation" contract, per
    /// this file's own doc comment above).
    private static func outcomeLabel(for status: ActivityStatus) -> String {
        switch status {
        case .completed: return "Completed"
        case .partiallyCompleted: return "Partially completed"
        case .missed: return "Missed"
        case .cancelled: return "Cancelled"
        case .scheduled: return "Scheduled"
        }
    }
}
