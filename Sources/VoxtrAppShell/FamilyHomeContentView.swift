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
    case reflection(AthleteId)
    case familySchedule
}

/// The actual Family Home content — replaces the previous
/// single-athlete `HomeDashboardView` at this position in the
/// navigation hierarchy. `HomeDashboardView` itself is unchanged in
/// content and is now what Athlete Overview presents (see
/// `FamilyHomeDestination.athlete`), not what Home shows directly.
///
/// Sprint 1 integration audit: every athlete lookup in this view reads
/// from `viewModel.activeAthletes` (refreshed from `AthleteRepository`
/// on appear), never from `family.activeAthletes` directly — the
/// latter is a launch-time snapshot that goes stale the moment an
/// athlete is added, archived, or edited after launch. See
/// `FamilyHomeViewModel`'s own doc comment for the full explanation.
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
        athleteRepository: AthleteRepository,
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
            workspaceId: WorkspaceId(rawValue: family.workspace.id),
            athleteRepository: athleteRepository,
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

                tomorrowSection

                Section {
                    NavigationLink("View upcoming schedule", value: FamilyHomeDestination.familySchedule)
                        .accessibilityIdentifier("familyHome.familyScheduleLink")
                }

                reflectionReminderSection
            }
            // Naming/navigation clarity: "Family Home" always, never
            // the generic "Home" — this is the family-wide screen, and
            // must read as such at a glance, distinct from Athlete
            // Overview's "<Athlete Name> Home" title.
            .navigationTitle("Family Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink("Manage Athletes", value: FamilyHomeDestination.manageAthletes)
                        .accessibilityIdentifier("familyHome.manageAthletesButton")
                }
            }
            .onAppear {
                viewModel.refresh()
            }
            .navigationDestination(for: FamilyHomeDestination.self) { destination in
                switch destination {
                case .athlete(let athleteId):
                    if let athlete = viewModel.activeAthletes.first(where: { $0.athleteId == athleteId }) {
                        athleteOverview(for: athlete)
                    }
                case .activity(let rowId):
                    if let row = viewModel.rows.first(where: { $0.id == rowId }) {
                        activityDetail(for: row)
                    }
                case .manageAthletes:
                    AthleteFamilyManagementView(
                        viewModel: athleteManagementViewModel,
                        athleteHomeDestination: { athlete in AnyView(self.athleteOverview(for: athlete)) }
                    )
                case .reflection(let athleteId):
                    ReflectionFormViewLoader(
                        athleteId: athleteId,
                        athleteDisplayName: viewModel.activeAthletes.first(where: { $0.athleteId == athleteId })?.givenName ?? "Athlete",
                        weekStart: TrainingPlanningCoordinationService.weekStart(),
                        authorId: ActorId(rawValue: family.participant.id),
                        weeklyReflectionService: weeklyReflectionService
                    )
                case .familySchedule:
                    FamilyScheduleView(
                        viewModel: FamilyScheduleViewModel(
                            activeAthletes: viewModel.activeAthletes,
                            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                            planningService: planningService
                        ),
                        actorId: ActorId(rawValue: family.participant.id),
                        planningService: planningService,
                        trainingService: trainingService
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var tomorrowSection: some View {
        if !viewModel.tomorrowRows.isEmpty {
            Section("Tomorrow") {
                ForEach(viewModel.tomorrowRows) { row in
                    familyHomeRow(row)
                }
            }
            .accessibilityIdentifier("familyHome.tomorrowList")
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

    /// Sprint 1 completion package, Item 5: location is now included
    /// where available — the field genuinely didn't exist when this
    /// comment previously said so.
    private static func rowSubtitle(for row: FamilyHomeRow) -> String {
        var parts: [String] = []
        if row.isCompleted {
            if let duration = row.plannedActivity.plannedDurationMinutes {
                parts.append("\(duration) min")
            }
            parts.append(row.plannedActivity.localDate.isoString)
        } else if let startTime = row.plannedActivity.startLocalTime {
            parts.append(String(format: "%02d:%02d", startTime.hour, startTime.minute))
        } else {
            parts.append("Ready to log")
        }
        if let location = row.plannedActivity.location, !location.isEmpty {
            parts.append(location)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var reflectionReminderSection: some View {
        Section("Reflection") {
            if viewModel.reflectionReminders.isEmpty {
                Text("No reflection yet this week.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.reflectionReminders) { reminder in
                    NavigationLink(value: FamilyHomeDestination.reflection(reminder.athleteId)) {
                        HStack {
                            Text(reminder.athleteName)
                            Spacer()
                            Text(reminder.reflectionExists ? "Recorded" : "No reflection yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("familyHome.reflectionRow.\(reminder.id)")
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
            plannedActivity: row.plannedActivity,
            isCompleted: row.isCompleted,
            athleteId: row.athleteId,
            athleteDisplayName: row.athleteName,
            actorId: ActorId(rawValue: family.participant.id),
            planningService: planningService,
            trainingService: trainingService
        )
    }
}
