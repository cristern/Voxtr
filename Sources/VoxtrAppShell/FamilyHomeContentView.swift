import SwiftUI
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Sprint 1 (Daily Use Foundation), Part 1. Each destination carries
/// its own identity directly — there is no shared, mutable "currently
/// selected athlete" anywhere in this type or its view, matching "no
/// global selected athlete state." A `NavigationLink(value:)` for one
/// row's athlete and one for its activity are both fully self-contained.
enum FamilyHomeDestination: Hashable {
    case athlete(AthleteId)
    case activity(rowId: String)
    case manageAthletes
}

/// The actual Family Home content — replaces the previous
/// single-athlete `HomeDashboardView` at this position in the
/// navigation hierarchy. `HomeDashboardView` itself is unchanged and is
/// now what Athlete Overview presents (see `FamilyHomeDestination
/// .athlete`), not what Home shows directly.
public struct FamilyHomeContentView: View {
    @State private var viewModel: FamilyHomeViewModel
    private let family: RestoredFamily
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    private let weeklyReflectionService: WeeklyReflectionService
    private let coachingApplicationService: CoachingApplicationService
    private let athleteManagementViewModel: AthleteFamilyManagementViewModel

    public init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteManagementViewModel: AthleteFamilyManagementViewModel
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteManagementViewModel = athleteManagementViewModel
        _viewModel = State(initialValue: FamilyHomeViewModel(
            activeAthletes: family.activeAthletes,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        ))
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("familyHome.errorMessage")
                    }
                }

                Section("Today's Schedule") {
                    if viewModel.rows.isEmpty {
                        Text("Nothing planned for today.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.rows) { row in
                            familyHomeRow(row)
                        }
                    }
                }
                .accessibilityIdentifier("familyHome.scheduleList")

                reflectionReminderSection
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink("Manage Athletes", value: FamilyHomeDestination.manageAthletes)
                        .accessibilityIdentifier("familyHome.manageAthletesButton")
                }
            }
            .onAppear {
                viewModel.loadHome()
                viewModel.loadReflectionReminder()
            }
            .navigationDestination(for: FamilyHomeDestination.self) { destination in
                switch destination {
                case .athlete(let athleteId):
                    if let athlete = family.activeAthletes.first(where: { $0.athleteId == athleteId }) {
                        athleteOverview(for: athlete)
                    }
                case .activity(let rowId):
                    if let row = viewModel.rows.first(where: { $0.id == rowId }) {
                        activityDetail(for: row)
                    }
                case .manageAthletes:
                    AthleteFamilyManagementView(viewModel: athleteManagementViewModel)
                }
            }
        }
    }

    private func familyHomeRow(_ row: FamilyHomeRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            NavigationLink(value: FamilyHomeDestination.athlete(row.athleteId)) {
                Text(row.athleteName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("familyHome.athleteLink.\(row.athleteId.rawValue.uuidString)")

            NavigationLink(value: FamilyHomeDestination.activity(rowId: row.id)) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.plannedActivity.title)
                        Text(Self.rowSubtitle(for: row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.isCompleted {
                        Text("Completed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("familyHome.activityRow.\(row.id)")
        }
    }

    /// Upcoming: time + activity is already the row title, so this adds
    /// nothing extra beyond a location if one existed (it doesn't yet —
    /// see this work's own deliverable). Completed: duration + date,
    /// per this part's own requirement — no location field exists to
    /// show either way.
    private static func rowSubtitle(for row: FamilyHomeRow) -> String {
        if row.isCompleted {
            var parts: [String] = []
            if let duration = row.plannedActivity.plannedDurationMinutes {
                parts.append("\(duration) min")
            }
            parts.append(row.plannedActivity.localDate.isoString)
            return parts.joined(separator: " · ")
        } else if let startTime = row.plannedActivity.startLocalTime {
            return String(format: "%02d:%02d", startTime.hour, startTime.minute)
        } else {
            return "Ready to log"
        }
    }

    @ViewBuilder
    private var reflectionReminderSection: some View {
        Section("Reflection") {
            switch viewModel.reflectionState {
            case .loading:
                ProgressView()
            case .unavailable:
                EmptyView()
            case .none(let athleteName):
                VStack(alignment: .leading, spacing: 4) {
                    Text("No reflection yet this week.")
                        .foregroundStyle(.secondary)
                    if let athlete = family.activeAthletes.first(where: { $0.givenName == athleteName }) {
                        NavigationLink("Add reflection", value: FamilyHomeDestination.athlete(athlete.athleteId))
                            .accessibilityIdentifier("familyHome.addReflectionLink")
                    }
                }
            case .recorded(let athleteName, let whatWentWell, let whatCouldImprove):
                VStack(alignment: .leading, spacing: 4) {
                    Text(athleteName).font(.caption).foregroundStyle(.secondary)
                    if let whatWentWell, !whatWentWell.isEmpty {
                        Text("What went well: \(whatWentWell)")
                    }
                    if let whatCouldImprove, !whatCouldImprove.isEmpty {
                        Text("What could improve: \(whatCouldImprove)")
                    }
                    if let athlete = family.activeAthletes.first(where: { $0.givenName == athleteName }) {
                        NavigationLink("Open reflection", value: FamilyHomeDestination.athlete(athlete.athleteId))
                            .accessibilityIdentifier("familyHome.openReflectionLink")
                    }
                }
            }
        }
        .accessibilityIdentifier("familyHome.reflectionReminder")
    }

    private func athleteOverview(for athlete: AthleteProfile) -> some View {
        HomeDashboardView(
            viewModel: HomeDashboardViewModel(
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                coachingPresentationProvider: coachingApplicationService,
                athleteId: athlete.athleteId,
                weekStart: WeeklyPlanningViewModel.currentWeekStart()
            ),
            athleteDisplayName: athlete.givenName,
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReviewCoordinationService: weeklyReviewCoordinationService,
            weeklyReflectionService: weeklyReflectionService,
            coachingApplicationService: coachingApplicationService,
            athleteId: athlete.athleteId,
            committedByActorId: ActorId(rawValue: family.participant.id),
            athleteManagementViewModel: athleteManagementViewModel
        )
    }

    private func activityDetail(for row: FamilyHomeRow) -> some View {
        ActivityDetailViewLoader(
            row: row,
            actorId: ActorId(rawValue: family.participant.id),
            planningService: planningService,
            trainingService: trainingService
        )
    }
}

/// Resolves a `FamilyHomeRow`'s WeekPlan draft status (needed to
/// construct `ActivityDetailViewModel`) before showing
/// `ActivityDetailView` — a small, local loading step rather than
/// fetching this eagerly for every row on Home just to support the rare
/// tap.
private struct ActivityDetailViewLoader: View {
    let row: FamilyHomeRow
    let actorId: ActorId
    let planningService: PlanningService
    let trainingService: TrainingService
    @State private var viewModel: ActivityDetailViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ActivityDetailView(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard viewModel == nil else { return }
            let weekPlanId = WeekPlanId(rawValue: row.plannedActivity.weekPlanId)
            let fetchedWeekPlan = try? planningService.fetchWeekPlan(byId: weekPlanId)
            let isDraft = (fetchedWeekPlan ?? nil)?.status == .draft
            viewModel = ActivityDetailViewModel(
                activity: row.plannedActivity,
                isCompleted: row.isCompleted,
                weekPlanId: weekPlanId,
                athleteId: row.athleteId,
                isWeekPlanDraft: isDraft,
                deletedByActorId: actorId,
                planningService: planningService,
                trainingService: trainingService
            )
        }
    }
}
