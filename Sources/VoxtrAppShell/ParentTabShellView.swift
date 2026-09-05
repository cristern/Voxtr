import SwiftUI
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrCoreReferenceData
import VoxtrCalendarPlanningDomain

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
    public let notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService
    public let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    public let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    public let weeklyReflectionService: WeeklyReflectionService
    public let coachingApplicationService: CoachingApplicationService
    public let athleteRepository: AthleteRepository
    public let athleteFamilyManagementService: AthleteFamilyManagementService
    /// Recurring reopen stale-Athlete-Home fix (architecture round): the
    /// one shared instance for this app run — threaded to the Home tab
    /// and the Profile tab's own Athlete Overview construction below,
    /// the only two places in this shell that construct a
    /// `HomeDashboardViewModel`.
    public let activityChangeBroadcaster: AthleteActivityChangeBroadcaster
    /// VX-023 (Sleep V1): same threading rationale as
    /// `activityChangeBroadcaster` above, for the separate Sleep
    /// coordination service/broadcaster pair.
    public let sleepCoordinationService: SleepCoordinationService
    public let sleepChangeBroadcaster: AthleteSleepChangeBroadcaster
    /// Statistics V1 UI round: threaded the same way every other cross-
    /// domain service above is — resolved once in `CompositionRoot`,
    /// passed down through `RootView`.
    public let statisticsService: StatisticsService
    public let sportRepository: SportRepository
    /// Calendar Planning Source V1: same threading rationale as
    /// `notificationsPlanningCoordinationService` above.
    public let calendarPlanningCoordinationService: CalendarPlanningCoordinationService
    /// Athlete Connection Foundation B2.6: same threading rationale as
    /// every other cross-domain service above — resolved once in
    /// `CompositionRoot`, passed down through `RootView`, threaded to
    /// both `AthleteFamilyManagementViewModel` construction sites this
    /// shell owns (the Home tab's, via `FamilyHomeView`, and the Profile
    /// tab's own, directly below).
    public let athleteConnectionOwnerHandoffService: AthleteConnectionOwnerHandoffService

    public init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteRepository: AthleteRepository,
        athleteFamilyManagementService: AthleteFamilyManagementService,
        activityChangeBroadcaster: AthleteActivityChangeBroadcaster,
        sleepCoordinationService: SleepCoordinationService,
        sleepChangeBroadcaster: AthleteSleepChangeBroadcaster,
        statisticsService: StatisticsService,
        sportRepository: SportRepository,
        calendarPlanningCoordinationService: CalendarPlanningCoordinationService,
        athleteConnectionOwnerHandoffService: AthleteConnectionOwnerHandoffService
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.notificationsPlanningCoordinationService = notificationsPlanningCoordinationService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteRepository = athleteRepository
        self.athleteFamilyManagementService = athleteFamilyManagementService
        self.activityChangeBroadcaster = activityChangeBroadcaster
        self.sleepCoordinationService = sleepCoordinationService
        self.sleepChangeBroadcaster = sleepChangeBroadcaster
        self.statisticsService = statisticsService
        self.sportRepository = sportRepository
        self.calendarPlanningCoordinationService = calendarPlanningCoordinationService
        self.athleteConnectionOwnerHandoffService = athleteConnectionOwnerHandoffService
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
                notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                weeklyReviewCoordinationService: weeklyReviewCoordinationService,
                weeklyReflectionService: weeklyReflectionService,
                coachingApplicationService: coachingApplicationService,
                athleteRepository: athleteRepository,
                athleteFamilyManagementService: athleteFamilyManagementService,
                activityChangeBroadcaster: activityChangeBroadcaster,
                sleepCoordinationService: sleepCoordinationService,
                sleepChangeBroadcaster: sleepChangeBroadcaster,
                calendarPlanningCoordinationService: calendarPlanningCoordinationService,
                sportRepository: sportRepository,
                athleteConnectionOwnerHandoffService: athleteConnectionOwnerHandoffService
            )
            .tabItem { Label("Home", systemImage: "house") }
            .accessibilityIdentifier("parentTabs.home")

            // Plan: "Ahead" — Family Schedule (every athlete's planned
            // activities across a date range) IS the Plan tab's root
            // now, opened directly with no intermediate menu step (see
            // `ParentPlanTabView`'s own doc comment for the full IA
            // rationale). Weekly Planning is deliberately per-athlete
            // (its own existing, unchanged architecture), so it is
            // reached FROM this root via an explicit toolbar action,
            // never auto-selecting one.
            ParentPlanTabView(
                family: family,
                planningService: planningService,
                trainingService: trainingService,
                trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                athleteRepository: athleteRepository,
                activityChangeBroadcaster: activityChangeBroadcaster,
                sportRepository: sportRepository,
                calendarPlanningCoordinationService: calendarPlanningCoordinationService,
                actorId: family.currentActor.actorId
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
            // `FamilyHomeContentView`'s own `athleteOverview(for:)`
            // already establishes for Family Home's per-athlete Home
            // navigation, reused here rather than invented anew.
            ParentTrainingTabView(
                family: family,
                planningService: planningService,
                trainingService: trainingService,
                trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                weeklyReviewCoordinationService: weeklyReviewCoordinationService,
                weeklyReflectionService: weeklyReflectionService,
                coachingApplicationService: coachingApplicationService,
                athleteRepository: athleteRepository,
                actorId: family.currentActor.actorId
            )
            .tabItem { Label("Training", systemImage: "figure.run") }
            .accessibilityIdentifier("parentTabs.training")

            // Statistics: Statistics V1 UI round — a family overview
            // (one card per active athlete) with per-athlete detail
            // navigated by stable `AthleteId`, same as Plan/Training
            // above. `StatisticsRootView` owns its own `onAppear`-
            // triggered load; wrapped in exactly one new
            // `NavigationStack` since it has none of its own.
            NavigationStack {
                StatisticsRootView(
                    viewModel: StatisticsRootViewModel(
                        statisticsService: statisticsService,
                        athleteRepository: athleteRepository,
                        workspaceId: WorkspaceId(rawValue: family.workspace.id)
                    ),
                    statisticsService: statisticsService,
                    sportRepository: sportRepository
                )
            }
            .tabItem { Label("Statistics", systemImage: "chart.bar") }
            .accessibilityIdentifier("parentTabs.statistics")

            // Profile: "Who is in this family and how is the family
            // configured?" — AthleteFamilyManagementView already covers
            // family/athlete configuration; reused verbatim, wrapped in
            // exactly one new NavigationStack since it has none of its
            // own. Round 8: an athlete row here opens that athlete's
            // configuration hub directly — Profile owns people +
            // configuration, never Athlete Home (that stays reachable
            // only through the Home experience).
            NavigationStack {
                AthleteFamilyManagementView(
                    viewModel: AthleteFamilyManagementViewModel(
                        workspaceId: WorkspaceId(rawValue: family.workspace.id),
                        participantId: family.participant.id,
                        athleteRepository: athleteRepository,
                        athleteFamilyManagementService: athleteFamilyManagementService,
                        athleteConnectionOwnerHandoffService: athleteConnectionOwnerHandoffService
                    ),
                    presentationMode: .navigation,
                    sleepSettingsViewModel: { athlete in
                        AthleteSleepSettingsViewModel(
                            sleepCoordinationService: sleepCoordinationService,
                            athleteId: athlete.athleteId,
                            athleteDisplayName: athlete.givenName
                        )
                    },
                    familyCalendarSourcesViewModel: FamilyCalendarSourcesViewModel(
                        calendarPlanningCoordinationService: calendarPlanningCoordinationService,
                        athleteRepository: athleteRepository,
                        sportRepository: sportRepository,
                        workspaceId: WorkspaceId(rawValue: family.workspace.id),
                        actorId: family.currentActor.actorId
                    )
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

/// Plan/Ahead root round: the Plan tab's ROOT is now `FamilyScheduleView`
/// itself — no intermediate menu step. Previously this tab was a
/// two-item menu (Family Schedule / Weekly Plan) that PUSHED Family
/// Schedule as a second screen; per the approved "Plan = Ahead" IA
/// contract, Family Schedule already IS the family-wide Ahead
/// experience, so it becomes what the Plan tab opens directly into.
/// Wraps `FamilyScheduleView`, which deliberately owns no
/// `NavigationStack` of its own, in exactly one.
///
/// Per-athlete Weekly Plan is still reachable — never auto-selecting an
/// athlete — since `WeeklyPlanningView` has no OTHER production entry
/// point in this app (verified: this file is its only construction
/// site). `WeeklyPlanningView` itself is completely unchanged. This
/// view owns the ACTUAL `NavigationStack`/`NavigationPath` (value-based
/// navigation — `NavigationPath` + `.navigationDestination(for:)` —
/// the same "value-based navigation" fix this app's own history already
/// established for Home; see the Athlete Home stale-navigation-state
/// investigation) and the `.navigationDestination(for: AthleteId.self)`
/// that actually constructs `WeeklyPlanningView`, but the toolbar
/// CONTROL that decides which athlete(s) can be reached — a submenu
/// across every active athlete, or (VX-037 round) a single direct
/// button once the schedule is filtered to exactly one athlete — now
/// lives inside `FamilyScheduleView` itself, driven by the
/// `onNavigateToWeeklyPlan` closure passed below. This tab supplies
/// only `weeklyPlanPath.append(_:)`, the SAME value-based push it
/// always used; `FamilyScheduleView` never gets a path/binding of its
/// own (it deliberately still owns no `NavigationStack`).
///
/// Also constructs the ONE `FamilyCalendarSourcesViewModel` this tab
/// needs — the SAME canonical instance both feeds Family Schedule's own
/// "N calendar events to review" prompt (via
/// `FamilyScheduleViewModel.provideCalendarReviewPrompt`) AND is reused,
/// unmodified, as the navigation destination's own view model
/// (`FamilyCalendarSourcesView`/`CalendarImportReviewView`, via
/// `FamilyScheduleView`'s own `calendarSourcesViewModel` parameter) — one
/// instance, one canonical read path
/// (`fetchSources`/`fetchReviewQueue`), never a second, competing read
/// of Calendar Planning state. Calendar Sources configuration itself is
/// completely untouched and still reached from Profile — this only adds
/// a SECOND navigation path into the SAME existing screens, for the
/// specific case where there is pending review work to act on.
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
    let notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService
    let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    let athleteRepository: AthleteRepository
    let activityChangeBroadcaster: AthleteActivityChangeBroadcaster
    let sportRepository: SportRepository
    let calendarPlanningCoordinationService: CalendarPlanningCoordinationService
    let actorId: ActorId

    @State private var activeAthletes: [AthleteProfile]
    /// Design Foundation extension round: this Plan tab is the OTHER
    /// production entry point into `FamilyScheduleView` — distinct from
    /// the "View upcoming schedule" link on Family Home, which already
    /// injects `FamilyHomeViewModel.resolvedAthleteColor(for:)` as its
    /// resolver. This root has no `FamilyHomeViewModel` in scope to
    /// reuse, so it resolves the same way `ParentTrainingTabView` does:
    /// through the ONE canonical `AthleteColor.resolved(forAthlete:using:)`
    /// helper, backed by this view's own already-stored
    /// `athleteRepository` — never a second, locally-invented mapping.
    @State private var athleteColors: [AthleteId: AthleteColor] = [:]
    /// Plan/Ahead root round: constructed once for this tab's lifetime
    /// — see this type's own doc comment for why it is the single,
    /// reused source both for the calendar-review prompt AND its own
    /// navigation destinations.
    @State private var familyCalendarSourcesViewModel: FamilyCalendarSourcesViewModel
    /// Plan/Ahead root round: the explicit, value-based path to
    /// per-athlete Weekly Plan — see this type's own doc comment for why
    /// this shape (never an inline-destination `NavigationLink`) was
    /// chosen. VX-037 round: the toolbar control that decides WHICH
    /// athlete to append now lives inside `FamilyScheduleView` itself
    /// (driven by `onNavigateToWeeklyPlan` below); this tab still owns
    /// the path itself and the real `.navigationDestination(for:)`.
    @State private var weeklyPlanPath = NavigationPath()

    init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        athleteRepository: AthleteRepository,
        activityChangeBroadcaster: AthleteActivityChangeBroadcaster,
        sportRepository: SportRepository,
        calendarPlanningCoordinationService: CalendarPlanningCoordinationService,
        actorId: ActorId
    ) {
        self.family = family
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.notificationsPlanningCoordinationService = notificationsPlanningCoordinationService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.athleteRepository = athleteRepository
        self.activityChangeBroadcaster = activityChangeBroadcaster
        self.sportRepository = sportRepository
        self.calendarPlanningCoordinationService = calendarPlanningCoordinationService
        self.actorId = actorId
        _activeAthletes = State(initialValue: family.activeAthletes)
        _familyCalendarSourcesViewModel = State(initialValue: FamilyCalendarSourcesViewModel(
            calendarPlanningCoordinationService: calendarPlanningCoordinationService,
            athleteRepository: athleteRepository,
            sportRepository: sportRepository,
            workspaceId: WorkspaceId(rawValue: family.workspace.id),
            actorId: actorId
        ))
    }

    var body: some View {
        NavigationStack(path: $weeklyPlanPath) {
            FamilyScheduleView(
                viewModel: FamilyScheduleViewModel(
                    provideActiveAthletes: { activeAthletes },
                    trainingPlanningCoordinationService: trainingPlanningCoordinationService,
                    planningService: planningService,
                    resolveAthleteColor: resolvedColor,
                    provideCalendarReviewPrompt: calendarReviewPrompt
                ),
                actorId: actorId,
                planningService: planningService,
                trainingService: trainingService,
                trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                calendarSourcesViewModel: familyCalendarSourcesViewModel,
                onNavigateToWeeklyPlan: { athleteId in weeklyPlanPath.append(athleteId) }
            )
            .navigationDestination(for: AthleteId.self) { athleteId in
                if let athlete = activeAthletes.first(where: { $0.athleteId == athleteId }) {
                    WeeklyPlanningView(
                        viewModel: WeeklyPlanningViewModel(
                            service: planningService,
                            notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                            athleteId: athlete.athleteId,
                            committedByActorId: actorId,
                            activityChangeBroadcaster: activityChangeBroadcaster
                        ),
                        athleteDisplayName: athlete.givenName,
                        planningService: planningService,
                        trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                        notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                        actorId: actorId
                    )
                    .accessibilityIdentifier("parentPlan.weeklyPlanDestination.\(athleteId.rawValue.uuidString)")
                }
            }
        }
        .onAppear {
            activeAthletes = fetchActiveAthletes(workspaceId: WorkspaceId(rawValue: family.workspace.id), athleteRepository: athleteRepository)
            loadAthleteColors()
        }
    }

    /// Mirrors `FamilyHomeViewModel.loadAthleteColors()`'s own "re-fetch
    /// on appear, no live push" freshness model.
    private func loadAthleteColors() {
        var resolved: [AthleteId: AthleteColor] = [:]
        for athlete in activeAthletes {
            resolved[athlete.athleteId] = AthleteColor.resolved(forAthlete: athlete.athleteId, using: athleteRepository)
        }
        athleteColors = resolved
    }

    /// Passed as `FamilyScheduleViewModel`'s `resolveAthleteColor`
    /// closure above — falls back to the stable mapping directly if
    /// `athleteColors` hasn't been populated for this id yet, so a row
    /// is never left with no colour at all.
    private func resolvedColor(for athleteId: AthleteId) -> AthleteColor {
        athleteColors[athleteId] ?? AthleteColor.forAthleteId(athleteId)
    }

    /// Plan/Ahead root round: the ONE place this tab computes
    /// `FamilyScheduleViewModel.CalendarReviewPrompt`, passed as
    /// `FamilyScheduleViewModel`'s `provideCalendarReviewPrompt`
    /// closure above. Always re-reads FRESH via
    /// `familyCalendarSourcesViewModel.load()` first — the EXACT same
    /// call `FamilyCalendarSourcesView`'s own `.onAppear` already makes
    /// whenever THAT screen appears (a passive EventKit status check
    /// plus the canonical `fetchSources`/`fetchReviewQueue` reads —
    /// never a permission PROMPT; see that ViewModel's own "Calm by
    /// Default" doc comment) — so this never depends on cross-view
    /// `.onAppear` ordering between this tab and `FamilyScheduleView`'s
    /// own internal load. The actual aggregation rule (disabled/
    /// disconnected sources never contribute) lives in the pure, directly
    /// unit-tested `CalendarReviewPrompt.from(sources:reviewCounts:)` —
    /// not duplicated here.
    private func calendarReviewPrompt() -> FamilyScheduleViewModel.CalendarReviewPrompt {
        familyCalendarSourcesViewModel.load()
        return .from(sources: familyCalendarSourcesViewModel.sources, reviewCounts: familyCalendarSourcesViewModel.reviewCounts)
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
    let notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService
    let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    let weeklyReflectionService: WeeklyReflectionService
    let coachingApplicationService: CoachingApplicationService
    let athleteRepository: AthleteRepository
    let actorId: ActorId

    @State private var activeAthletes: [AthleteProfile]
    /// Design Foundation extension round: Training is a shared/multi-
    /// athlete surface here — this tab root lists every active athlete
    /// in the same "Daily Training"/"Weekly Review"/"Week by Week"
    /// rows — so each row gets the same resolved Athlete Color Family
    /// Home/Family Schedule already show. Resolved via the ONE
    /// canonical `AthleteColor.resolved(forAthlete:using:)` helper
    /// (`VoxtrDesignSystem.swift`), reusing this view's own already-
    /// stored `athleteRepository` — never a second, locally-invented
    /// colour-mapping scheme. The screens these rows navigate to
    /// (`DailyTrainingView`, `WeeklyReviewView`, `WeeklyHistoryListView`)
    /// are single-athlete detail screens once opened, and deliberately
    /// receive no Athlete Color theming of their own.
    @State private var athleteColors: [AthleteId: AthleteColor] = [:]

    init(
        family: RestoredFamily,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
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
        self.notificationsPlanningCoordinationService = notificationsPlanningCoordinationService
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
                        Section {
                            ForEach(activeAthletes, id: \.athleteId) { athlete in
                                NavigationLink {
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
                                        notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                                        actorId: actorId,
                                        athleteDisplayName: athlete.givenName
                                    )
                                } label: {
                                    Text(athlete.givenName)
                                        .font(VoxtrTypography.cardTitle)
                                        .foregroundStyle(VoxtrColor.textPrimary)
                                }
                                .voxtrAthleteIdentityOutline(resolvedColor(for: athlete.athleteId).color)
                                .accessibilityIdentifier("parentTraining.dailyTrainingLink.\(athlete.athleteId.rawValue.uuidString)")
                            }
                        } header: {
                            VoxtrSectionHeading("Daily Training")
                        }
                        .voxtrRowSurface()
                        Section {
                            ForEach(activeAthletes, id: \.athleteId) { athlete in
                                NavigationLink {
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
                                } label: {
                                    Text(athlete.givenName)
                                        .font(VoxtrTypography.cardTitle)
                                        .foregroundStyle(VoxtrColor.textPrimary)
                                }
                                .voxtrAthleteIdentityOutline(resolvedColor(for: athlete.athleteId).color)
                                .accessibilityIdentifier("parentTraining.weeklyReviewLink.\(athlete.athleteId.rawValue.uuidString)")
                            }
                        } header: {
                            VoxtrSectionHeading("Weekly Review")
                        }
                        .voxtrRowSurface()
                        Section {
                            ForEach(activeAthletes, id: \.athleteId) { athlete in
                                NavigationLink {
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
                                } label: {
                                    Text(athlete.givenName)
                                        .font(VoxtrTypography.cardTitle)
                                        .foregroundStyle(VoxtrColor.textPrimary)
                                }
                                .voxtrAthleteIdentityOutline(resolvedColor(for: athlete.athleteId).color)
                                .accessibilityIdentifier("parentTraining.weeklyHistoryLink.\(athlete.athleteId.rawValue.uuidString)")
                            }
                        } header: {
                            VoxtrSectionHeading("Week by Week")
                        }
                        .voxtrRowSurface()
                    }
                    .voxtrScreenBackground()
                }
            }
            .navigationTitle("Training")
        }
        .onAppear {
            activeAthletes = fetchActiveAthletes(workspaceId: WorkspaceId(rawValue: family.workspace.id), athleteRepository: athleteRepository)
            loadAthleteColors()
        }
    }

    /// Mirrors `FamilyHomeViewModel.loadAthleteColors()`'s own "re-fetch
    /// on appear, no live push" freshness model — one resolved colour
    /// per active athlete, read fresh every time this tab appears so a
    /// colour change made in Athlete Settings shows up here the next
    /// time the Training tab is opened.
    private func loadAthleteColors() {
        var resolved: [AthleteId: AthleteColor] = [:]
        for athlete in activeAthletes {
            resolved[athlete.athleteId] = AthleteColor.resolved(forAthlete: athlete.athleteId, using: athleteRepository)
        }
        athleteColors = resolved
    }

    /// The one function every row in this tab calls for an athlete's
    /// colour — falls back to the stable mapping directly if
    /// `athleteColors` hasn't been populated for this id yet, so a row
    /// is never left with no colour at all (same guarantee
    /// `FamilyHomeViewModel.resolvedAthleteColor(for:)` already gives
    /// its own rows).
    private func resolvedColor(for athleteId: AthleteId) -> AthleteColor {
        athleteColors[athleteId] ?? AthleteColor.forAthleteId(athleteId)
    }
}
