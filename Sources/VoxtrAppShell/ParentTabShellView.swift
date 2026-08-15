import SwiftUI
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Bottom Navigation / Information Architecture Foundation package:
/// the Parent shell's five approved primary destinations — Home | Plan
/// | Training | Statistics | Profile. This is the Parent-only
/// implementation of the shared five-destination concept; the future
/// Athlete App will use the same conceptual shape with different root
/// content and permissions, never embedded here.
///
/// Each tab owns its own `NavigationStack` — the standard, native
/// SwiftUI TabView contract (switching tabs must not create duplicate
/// model state, must not reset persisted domain state, and each tab's
/// own navigation history is preserved independently while the app
/// runs). No custom navigation framework: platform-standard
/// TabView/NavigationStack is sufficient for every requirement this
/// package has.
///
/// Navigation ownership audit performed before this file was written:
/// - `FamilyHomeView`/`FamilyHomeContentView` already own their own
///   root `NavigationStack` (mutually exclusive branches — never both
///   active at once) — reused verbatim as the Home tab's entire
///   content, unmodified.
/// - `FamilyScheduleView`, `WeeklyPlanningView`, `DailyTrainingView`,
///   and `AthleteFamilyManagementView` all deliberately have NO root
///   `NavigationStack` of their own (confirmed directly in each file —
///   any `NavigationStack` inside them belongs to an internal sheet
///   struct, e.g. `RecurringActivityManagementView`,
///   `RecurringActivityFormView`, `AthleteFormView`) — they were
///   always designed to be pushed into an existing stack. Each is now
///   wrapped in exactly one new `NavigationStack`, owned by this tab's
///   own root view below — no duplicate ownership, no accidental
///   nesting.
public struct ParentTabShellView: View {
    public let family: RestoredFamily
    public let planningService: PlanningService
    public let trainingService: TrainingService
    public let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    public let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    public let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    public let weeklyReflectionService: WeeklyReflectionService
    public let coachingApplicationService: CoachingApplicationService
    public let athleteRepository: AthleteRepository
    public let athleteFamilyManagementService: AthleteFamilyManagementService

    public init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteRepository: AthleteRepository,
        athleteFamilyManagementService: AthleteFamilyManagementService
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteRepository = athleteRepository
        self.athleteFamilyManagementService = athleteFamilyManagementService
    }

    public var body: some View {
        TabView {
            // Home: "What is happening in the family now?" — the
            // existing Family Home experience, entirely unmodified.
            // FamilyHomeView already owns its own root NavigationStack
            // (either via FamilyHomeContentView, when active athletes
            // exist, or its own zero-athletes branch) — not wrapped in
            // a second one here.
            FamilyHomeView(
                family: family,
                planningService: planningService,
                trainingService: trainingService,
                trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                weeklyReviewCoordinationService: weeklyReviewCoordinationService,
                weeklyReflectionService: weeklyReflectionService,
                coachingApplicationService: coachingApplicationService,
                athleteRepository: athleteRepository,
                athleteFamilyManagementService: athleteFamilyManagementService
            )
            .tabItem { Label("Home", systemImage: "house") }
            .accessibilityIdentifier("parentTabs.home")

            // Plan: "What is planned?" — Family Schedule is the
            // family-wide view (every athlete's planned activities
            // across a date range) and is the natural root for a
            // family-level question; Weekly Planning is deliberately
            // per-athlete (its own existing, unchanged architecture),
            // so it is reached FROM this tab via explicit athlete
            // selection, never auto-selecting one.
            ParentPlanTabView(
                family: family,
                planningService: planningService,
                trainingService: trainingService,
                trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                athleteRepository: athleteRepository,
                actorId: ActorId(rawValue: family.participant.id)
            )
            .tabItem { Label("Plan", systemImage: "calendar") }
            .accessibilityIdentifier("parentTabs.plan")

            // Training: "What training has happened / what can I log
            // or review?" — Daily Training and Weekly Review are both
            // deliberately per-athlete (unchanged); no family-wide
            // training overview currently exists, and building one is
            // explicitly out of scope (no new training domain). The
            // smallest coherent root that reuses existing
            // functionality is explicit athlete selection into the
            // existing per-athlete screens — the same shape
            // `AthleteFamilyManagementView`'s own `athleteHomeDestination`
            // already establishes for Home's zero-active-athletes
            // branch, reused here rather than invented anew.
            ParentTrainingTabView(
                family: family,
                planningService: planningService,
                trainingService: trainingService,
                trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                weeklyReviewCoordinationService: weeklyReviewCoordinationService,
                weeklyReflectionService: weeklyReflectionService,
                coachingApplicationService: coachingApplicationService,
                athleteRepository: athleteRepository,
                actorId: ActorId(rawValue: family.participant.id)
            )
            .tabItem { Label("Training", systemImage: "figure.run") }
            .accessibilityIdentifier("parentTabs.training")

            // Statistics: approved destination, feature explicitly out
            // of scope for this package. Minimum maintainable
            // placeholder only — no charts, no aggregation, no
            // repository, no schema.
            NavigationStack {
                StatisticsPlaceholderView()
            }
            .tabItem { Label("Statistics", systemImage: "chart.bar") }
            .accessibilityIdentifier("parentTabs.statistics")

            // Profile: "Who is in this family and how is the family
            // configured?" — AthleteFamilyManagementView already covers
            // family/athlete configuration; reused verbatim, wrapped in
            // exactly one new NavigationStack since it has none of its
            // own. The athleteHomeDestination closure reuses the exact
            // same canonical Athlete Home construction FamilyHomeView's
            // own zero-active-athletes branch already establishes — not
            // a second implementation.
            NavigationStack {
                AthleteFamilyManagementView(
                    viewModel: AthleteFamilyManagementViewModel(
                        workspaceId: WorkspaceId(rawValue: family.workspace.id),
                        participantId: family.participant.id,
                        athleteRepository: athleteRepository,
                        athleteFamilyManagementService: athleteFamilyManagementService
                    ),
                    athleteHomeDestination: { athlete in
                        AnyView(
                            HomeDashboardView(
                                viewModel: HomeDashboardViewModel(
                                    trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                                    coachingPresentationProvider: coachingApplicationService,
                                    athleteId: athlete.athleteId,
                                    athleteDisplayName: athlete.givenName,
                                    weekStart: WeeklyPlanningViewModel.currentWeekStart(),
                                    todayActivityComposer: TodayActivityComposer(
                                        planningService: planningService,
                                        trainingService: trainingService,
                                        trainingPlanningCoordinationService: trainingPlanningCoordinationService
                                    )
                                ),
                                athleteDisplayName: athlete.givenName,
                                planningService: planningService,
                                trainingService: trainingService,
                                trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                                weeklyReviewCoordinationService: weeklyReviewCoordinationService,
                                weeklyReflectionService: weeklyReflectionService,
                                coachingApplicationService: coachingApplicationService,
                                athleteId: athlete.athleteId,
                                committedByActorId: ActorId(rawValue: family.participant.id),
                                athleteManagementViewModel: AthleteFamilyManagementViewModel(
                                    workspaceId: WorkspaceId(rawValue: family.workspace.id),
                                    participantId: family.participant.id,
                                    athleteRepository: athleteRepository,
                                    athleteFamilyManagementService: athleteFamilyManagementService
                                )
                            )
                        )
                    }
                )
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .accessibilityIdentifier("parentTabs.profile")
        }
    }
}

/// Shared by both new tab roots below — the exact same repository
/// method, active-only filter, and deterministic ordering
/// `FamilyHomeViewModel.refreshActiveAthletes()` already established
/// (see that method's own doc comment), reused rather than
/// reimplemented separately in each tab.
///
/// `@MainActor`: `AthleteRepository` is itself `@MainActor`-isolated
/// (class-level). As a top-level, free function — not a member method
/// on an already-`@MainActor` type — this does not inherit that
/// isolation automatically, unlike e.g. `FamilyHomeViewModel`'s own
/// `refreshActiveAthletes()`, which is `@MainActor` only because
/// `FamilyHomeViewModel` itself is. Both call sites below are already
/// valid `@MainActor` contexts on their own: they're inside
/// `.onAppear` closures attached directly within `ParentPlanTabView`/
/// `ParentTrainingTabView`'s own `body`, and `View.body` is declared
/// `@MainActor` by the `View` protocol itself — the same guarantee
/// every other `.onAppear`-triggered call in this app already relies
/// on. This annotation makes that existing guarantee explicit for a
/// free function, which the compiler cannot infer on its own.
@MainActor
private func fetchActiveAthletes(workspaceId: WorkspaceId, athleteRepository: AthleteRepository) -> [AthleteProfile] {
    (try? athleteRepository.fetchAthletes(forWorkspace: workspaceId))?
        .filter { !$0.isArchived }
        .sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        } ?? []
}

/// Plan tab root: Family Schedule (family-wide) with explicit,
/// per-athlete navigation into Weekly Planning — never auto-selecting
/// an athlete. Wraps `FamilyScheduleView`, which deliberately owns no
/// `NavigationStack` of its own, in exactly one.
///
/// Pattern-impact audit finding (fixed here, Category A — same root
/// cause, same UX contract, low risk, directly within this package):
/// this tab's athlete list is seeded from `family.activeAthletes`, but
/// that is a launch-time snapshot that goes stale the moment an
/// athlete is added, archived, or edited after launch — the exact
/// defect `FamilyHomeContentView`'s own doc comment already documents
/// and fixes for Home. Refreshed on appear here too, so returning to
/// this tab after adding an athlete elsewhere (e.g. Profile) reflects
/// current persisted state rather than a stale snapshot.
private struct ParentPlanTabView: View {
    let family: RestoredFamily
    let planningService: PlanningService
    let trainingService: TrainingService
    let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    let athleteRepository: AthleteRepository
    let actorId: ActorId

    @State private var activeAthletes: [AthleteProfile]

    init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        athleteRepository: AthleteRepository,
        actorId: ActorId
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.athleteRepository = athleteRepository
        self.actorId = actorId
        _activeAthletes = State(initialValue: family.activeAthletes)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("Family Schedule") {
                        FamilyScheduleView(
                            viewModel: FamilyScheduleViewModel(
                                activeAthletes: activeAthletes,
                                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                                planningService: planningService
                            ),
                            actorId: actorId,
                            planningService: planningService,
                            trainingService: trainingService,
                            trainingReflectionCoordinationService: trainingReflectionCoordinationService
                        )
                    }
                    .accessibilityIdentifier("parentPlan.familyScheduleLink")
                }

                if !activeAthletes.isEmpty {
                    Section("Weekly Plan") {
                        ForEach(activeAthletes, id: \.athleteId) { athlete in
                            NavigationLink(athlete.givenName) {
                                WeeklyPlanningView(
                                    viewModel: WeeklyPlanningViewModel(
                                        service: planningService,
                                        athleteId: athlete.athleteId,
                                        committedByActorId: actorId
                                    ),
                                    athleteDisplayName: athlete.givenName,
                                    planningService: planningService,
                                    trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                                    actorId: actorId
                                )
                            }
                            .accessibilityIdentifier("parentPlan.weeklyPlanLink.\(athlete.athleteId.rawValue.uuidString)")
                        }
                    }
                }
            }
            .navigationTitle("Plan")
        }
        .onAppear {
            activeAthletes = fetchActiveAthletes(workspaceId: WorkspaceId(rawValue: family.workspace.id), athleteRepository: athleteRepository)
        }
    }
}

/// Training tab root: explicit per-athlete selection into the existing
/// Daily Training and Weekly Review screens — never auto-selecting an
/// athlete, never a new family-wide training domain. Wraps two
/// screens that deliberately own no `NavigationStack` of their own,
/// each in exactly one, at the point they're actually pushed.
private struct ParentTrainingTabView: View {
    let family: RestoredFamily
    let planningService: PlanningService
    let trainingService: TrainingService
    let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    let weeklyReflectionService: WeeklyReflectionService
    let coachingApplicationService: CoachingApplicationService
    let athleteRepository: AthleteRepository
    let actorId: ActorId

    @State private var activeAthletes: [AthleteProfile]

    init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteRepository: AthleteRepository,
        actorId: ActorId
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteRepository = athleteRepository
        self.actorId = actorId
        _activeAthletes = State(initialValue: family.activeAthletes)
    }

    var body: some View {
        NavigationStack {
            Group {
                if activeAthletes.isEmpty {
                    ContentUnavailableView(
                        "No athletes yet",
                        systemImage: "figure.run",
                        description: Text("Add an athlete from Profile to start logging training.")
                    )
                } else {
                    List {
                        Section("Daily Training") {
                            ForEach(activeAthletes, id: \.athleteId) { athlete in
                                NavigationLink(athlete.givenName) {
                                    DailyTrainingView(
                                        viewModel: DailyTrainingViewModel(
                                            trainingService: trainingService,
                                            coordinationService: trainingPlanningCoordinationService,
                                            trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                                            authorId: actorId,
                                            athleteId: athlete.athleteId,
                                            athleteDisplayName: athlete.givenName,
                                            todayActivityComposer: TodayActivityComposer(
                                                planningService: planningService,
                                                trainingService: trainingService,
                                                trainingPlanningCoordinationService: trainingPlanningCoordinationService
                                            )
                                        ),
                                        planningService: planningService,
                                        trainingService: trainingService,
                                        trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                                        actorId: actorId,
                                        athleteDisplayName: athlete.givenName
                                    )
                                }
                                .accessibilityIdentifier("parentTraining.dailyTrainingLink.\(athlete.athleteId.rawValue.uuidString)")
                            }
                        }
                        Section("Weekly Review") {
                            ForEach(activeAthletes, id: \.athleteId) { athlete in
                                NavigationLink(athlete.givenName) {
                                    WeeklyReviewView(
                                        viewModel: WeeklyReviewViewModel(
                                            coordinationService: weeklyReviewCoordinationService,
                                            coachingPresentationProvider: coachingApplicationService,
                                            athleteId: athlete.athleteId,
                                            weekStart: WeeklyPlanningViewModel.currentWeekStart()
                                        ),
                                        athleteDisplayName: athlete.givenName,
                                        reflectionService: weeklyReflectionService,
                                        authorId: actorId
                                    )
                                }
                                .accessibilityIdentifier("parentTraining.weeklyReviewLink.\(athlete.athleteId.rawValue.uuidString)")
                            }
                        }
                        Section("Week by Week") {
                            ForEach(activeAthletes, id: \.athleteId) { athlete in
                                NavigationLink(athlete.givenName) {
                                    WeeklyHistoryListView(
                                        viewModel: WeeklyHistoryListViewModel(
                                            coordinationService: weeklyReviewCoordinationService,
                                            athleteId: athlete.athleteId,
                                            currentWeekStart: WeeklyPlanningViewModel.currentWeekStart()
                                        ),
                                        athleteDisplayName: athlete.givenName,
                                        currentWeekStart: WeeklyPlanningViewModel.currentWeekStart(),
                                        makeDetailView: { selectedWeekStart in
                                            WeeklyHistoryView(
                                                viewModel: WeeklyHistoryViewModel(
                                                    coordinationService: weeklyReviewCoordinationService,
                                                    athleteId: athlete.athleteId,
                                                    weekStart: selectedWeekStart
                                                ),
                                                athleteDisplayName: athlete.givenName,
                                                reflectionService: weeklyReflectionService,
                                                authorId: actorId
                                            )
                                        }
                                    )
                                }
                                .accessibilityIdentifier("parentTraining.weeklyHistoryLink.\(athlete.athleteId.rawValue.uuidString)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Training")
        }
        .onAppear {
            activeAthletes = fetchActiveAthletes(workspaceId: WorkspaceId(rawValue: family.workspace.id), athleteRepository: athleteRepository)
        }
    }
}

/// Statistics tab root: an approved primary destination whose actual
/// feature is explicitly out of scope for this package. Exists only so
/// the tab is real and navigable in TestFlight — no charts, no
/// aggregation, no invented repository, no schema. Future direction
/// (Sport -> ActivityType -> optional Title/Focus) is documented here
/// only as a pointer for whoever implements it next, not acted on.
private struct StatisticsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Statistics",
            systemImage: "chart.bar",
            description: Text("Training and development statistics are coming soon.")
        )
        .navigationTitle("Statistics")
        .accessibilityIdentifier("parentStatistics.placeholder")
    }
}
