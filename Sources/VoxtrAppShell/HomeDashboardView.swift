import SwiftUI
import VoxtrCoreContracts
import VoxtrCoachingDomain
import VoxtrMotivationDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// TestFlight regression fix (stale mounted Athlete Home after Log/Cancel):
/// temporary, `#if DEBUG`-only tracing for the exact boundary this
/// investigation needed to prove — whether the reload callback fires,
/// which `HomeDashboardViewModel` instance it fires on, what rows come
/// back, and what the row actually renders. No sensitive/private user
/// content — activity titles/notes are never logged, only stable row
/// ids, an outcome enum case, and object identities. Retained
/// (deliberately, not removed) as a reusable diagnostic for this exact
/// class of "mounted screen didn't refresh" bug, which has recurred
/// multiple times on this exact screen — but it compiles to nothing in
/// a Release build.
#if DEBUG
func homeDashboardDebugLog(_ message: @autoclosure () -> String) {
    print("[HomeDashboardView] \(message())")
}
#else
@inline(__always)
func homeDashboardDebugLog(_ message: @autoclosure () -> String) {}
#endif

/// Sprint 12: the application's first Home Dashboard — the primary
/// entry point after onboarding. Deliberately minimal: native SwiftUI
/// components only, no custom styling system, no decoration. This
/// sprint establishes the architecture (ViewModel → existing
/// application services → domain), not a finished dashboard
/// experience.
///
/// Sprint 15: reordered to Welcome → Daily Quote → Daily Focus →
/// existing cards, per that sprint's explicit recommended order.
/// `DailyQuoteView()` is self-contained — it owns its own
/// `DailyQuoteViewModel` (default-constructed, no dependency threaded
/// through `FamilyHomeView`/`RootView`/`CompositionRoot` needed) since
/// Daily Quote has no overlap with anything `HomeDashboardViewModel`
/// already loads. Coaching logic and Daily Focus are unmodified by
/// this sprint — only their position in this list changed.
///
/// Every section here reuses an already-existing destination or
/// service — `WeeklyReviewView` (via the Coaching summary) is exactly
/// the same screen `FamilyHomeView` already links to, constructed the
/// same way. This view adds no new navigation destinations, only two
/// small summaries (today's activities, coaching) built purely from
/// what `HomeDashboardViewModel` already loaded.
///
/// Athlete Home "Now" restructure round: this screen no longer links
/// to `WeeklyPlanningView`/`DailyTrainingView` at all — both permanent
/// "menu" rows into Plan/Training's own dedicated tabs were removed
/// (see `todaySection`'s and the removed `planningSection`'s own doc
/// comments) in favor of showing today's actual activity content
/// directly. Neither destination was changed or made unreachable —
/// both keep their own independent construction site in
/// `ParentTabShellView`.
///
/// TestFlight regression fix (stale mounted Athlete Home after Log/Cancel):
/// `todayActivityRow(_:)`'s `.planned`/`.recurringOccurrence` cases used
/// to embed their destination directly — `NavigationLink { ActivityDetailViewLoader(...) } label: { ... }`
/// (the legacy, eager-destination initializer) — instead of the
/// value-based `NavigationLink(value:) + .navigationDestination(for:)`
/// pattern `FamilyHomeContentView` already uses successfully for the
/// identical "planned activity" and "recurring occurrence" pushes. Both
/// the destination AND the label of that legacy form are captured as
/// part of ONE `NavigationLink` view value that SwiftUI's
/// `NavigationStack`/`List`-row machinery treats as tied to a single,
/// already-established push identity once tapped — so a mutation that
/// happens while that destination is on screen (Log Activity Save,
/// Cancel Activity) updated `HomeDashboardViewModel` correctly (proven:
/// `onActivityLogged` fires, `loadTodaysTraining()`/`loadTodayActivityRows()`
/// run, canonical rows come back fresh — see the `#if DEBUG` diagnostics
/// below), but the row's own already-rendered label did not reliably
/// pick the fresh value back up purely by popping back to it. Switching
/// to `NavigationLink(value:)` decouples the destination resolution
/// from the row's rendering entirely: `.navigationDestination(for:)`
/// resolves the CURRENT row fresh from `viewModel.todayActivityState`
/// every time it runs, and the row's label is rebuilt from the current
/// `ForEach` element on every body pass exactly like every other row in
/// this app already does — the same mechanism already verified working
/// for Family Home's identical navigation.
///
/// Mirrors `FamilyHomeDestination`'s own `.activity(rowId:)`/
/// `.recurringOccurrence(id:)` cases exactly — resolved the same way,
/// against this screen's own `viewModel.todayActivityState` instead of
/// `FamilyHomeViewModel.rows`.
enum HomeDashboardDestination: Hashable {
    case activity(rowId: String)
    case recurringOccurrence(id: String)
    /// VX-023 (Sleep V1): the canonical Sleep capture destination for
    /// one `LocalDate` — used identically for both "log today's Sleep"
    /// (from the Sleep card) and the morning prompt's own "log now"
    /// action; `LocalDate` is `Hashable`, so no wrapper id is needed.
    case sleepCapture(localDate: LocalDate)
    // Athlete Home "Now" restructure round (Part C, Sleep compaction):
    // `.sleepHistory` and its `sleepHistoryDestination` view were
    // removed together with the standalone "Sleep History" row that
    // was their only trigger in this file — see `sleepSection`'s own
    // doc comment. `SleepHistoryView` itself is untouched and remains
    // reachable via Family Home's own separate "Sleep History" entry
    // point (`FamilyHomeContentView`), so this is a same-file
    // dead-code removal, not a destination removed from the app.
}

/// Resolves a `HomeDashboardDestination` against a `TodayActivityLoadState`
/// — extracted as a plain, `View`-independent function (not a method on
/// `HomeDashboardView` itself) specifically so the exact mechanism this
/// regression fix depends on is directly unit-testable without
/// constructing or hosting any SwiftUI view: pass the SAME row id
/// against a state captured BEFORE a mutation and again against a fresh
/// state loaded AFTER one, and the second call must return the updated
/// row — never a value frozen at some earlier point. This is what
/// `.navigationDestination(for:)` calls on every invocation, always
/// against `viewModel.todayActivityState` as it stands AT THAT MOMENT,
/// never a `TodayActivityRow`/`FamilyHomeRow` captured earlier at
/// row-render time (the legacy `NavigationLink(destination:)` pattern
/// this fix replaces).
enum HomeDashboardRowResolver {
    static func plannedRow(forId rowId: String, in state: TodayActivityLoadState) -> FamilyHomeRow? {
        guard case .loaded(let rows) = state else { return nil }
        for row in rows {
            if case .planned(let familyHomeRow) = row, familyHomeRow.id == rowId {
                return familyHomeRow
            }
        }
        return nil
    }

    static func recurringSuggestion(forId id: String, in state: TodayActivityLoadState) -> RecurringActivitySuggestion? {
        guard case .loaded(let rows) = state else { return nil }
        for row in rows {
            if case .recurringOccurrence(_, _, let suggestion) = row, suggestion.id == id {
                return suggestion
            }
        }
        return nil
    }
}

public struct HomeDashboardView: View {
    @State private var viewModel: HomeDashboardViewModel
    private let athleteDisplayName: String
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    /// Athlete Home "Now" restructure round: this property is no
    /// longer read anywhere in this file's body — its only use was
    /// constructing the now-removed "Daily Training" `NavigationLink`'s
    /// destination (see `todaySection`'s doc comment). Left in the
    /// initializer deliberately rather than removed: dropping it would
    /// change this view's public `init` signature, which would require
    /// editing its one construction site in `FamilyHomeContentView.swift`
    /// — out of this round's explicit scope ("Do not change: Family
    /// Home"). Reported as follow-up cleanup, not silently expanded
    /// into.
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let weeklyReviewCoordinationService: WeeklyReviewCoordinationService
    private let weeklyReflectionService: WeeklyReflectionService
    private let coachingApplicationService: CoachingApplicationService
    private let athleteId: AthleteId
    private let committedByActorId: ActorId
    private let athleteManagementViewModel: AthleteFamilyManagementViewModel
    /// Recurring reopen stale-Athlete-Home fix (architecture round):
    /// threaded through only to pass to the "Manage Athletes" sheet's
    /// own `HomeDashboardViewModel` construction below — this screen's
    /// own `viewModel` above already subscribed with whatever broadcaster
    /// its own constructor received.
    private let activityChangeBroadcaster: AthleteActivityChangeBroadcaster
    /// VX-023 (Sleep V1): threaded through to construct
    /// `SleepCaptureViewModel` at this screen's Sleep capture
    /// destination, and to the "Manage Athletes" sheet's own nested
    /// `HomeDashboardViewModel`/`AthleteSleepSettingsViewModel`
    /// construction below. Athlete Home "Now" restructure round: this
    /// screen's separate Sleep History destination/link was removed
    /// (see `sleepSection`'s own doc comment) — only one Sleep
    /// navigation destination remains here now.
    private let sleepCoordinationService: SleepCoordinationService
    /// VX-023: threaded through only to pass to the "Manage Athletes"
    /// sheet's own nested `HomeDashboardViewModel` construction below —
    /// same rationale as `activityChangeBroadcaster` immediately above.
    private let sleepChangeBroadcaster: AthleteSleepChangeBroadcaster
    @State private var isManagingAthletes: Bool = false

    public init(
        viewModel: HomeDashboardViewModel,
        athleteDisplayName: String,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReviewCoordinationService: WeeklyReviewCoordinationService,
        weeklyReflectionService: WeeklyReflectionService,
        coachingApplicationService: CoachingApplicationService,
        athleteId: AthleteId,
        committedByActorId: ActorId,
        athleteManagementViewModel: AthleteFamilyManagementViewModel,
        activityChangeBroadcaster: AthleteActivityChangeBroadcaster,
        sleepCoordinationService: SleepCoordinationService,
        sleepChangeBroadcaster: AthleteSleepChangeBroadcaster
    ) {
        _viewModel = State(initialValue: viewModel)
        self.athleteDisplayName = athleteDisplayName
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReviewCoordinationService = weeklyReviewCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.coachingApplicationService = coachingApplicationService
        self.athleteId = athleteId
        self.committedByActorId = committedByActorId
        self.athleteManagementViewModel = athleteManagementViewModel
        self.activityChangeBroadcaster = activityChangeBroadcaster
        self.sleepCoordinationService = sleepCoordinationService
        self.sleepChangeBroadcaster = sleepChangeBroadcaster
    }

    public var body: some View {
        Form {
            // Athlete Home "Now" restructure round: target hierarchy is
            // Today, Sleep, existing contextual Coaching content,
            // Reflection lower — see this round's own doc comments on
            // `todaySection`/`sleepSection` for what changed in each.
            // `DailyQuoteView()` and `coachingSection` are unmodified by
            // this round and keep their prior relative position
            // (immediately adjacent to each other) — neither is named
            // in this round's approved hierarchy, so neither was moved
            // or redesigned, only the sections around them.
            todaySection
            sleepSection
            DailyQuoteView()
            coachingSection
            reflectionSection
        }
        .navigationTitle("\(athleteDisplayName) Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Manage Athletes") {
                    isManagingAthletes = true
                }
                .accessibilityIdentifier("home.manageAthletesButton")
            }
        }
        // Round 8 (TestFlight IA correction) modal-entry-point audit,
        // answered from the actual code: (1) this button/sheet exists
        // because Athlete Home is a screen a parent can be pushed deep
        // into from Family Home, with no NavigationStack of its own to
        // reach Profile's Manage Athletes through — the sheet was the
        // only way to reach athlete management without leaving Athlete
        // Home; its original value was letting a parent jump straight
        // into ANOTHER athlete's Home from here via `athleteHomeDestination`.
        // (2) That specific value is gone now that Manage Athletes'
        // row opens the athlete's configuration hub instead of Athlete
        // Home (see `AthleteFamilyManagementView`'s own round 8 doc
        // comment) — quick-switching to another athlete's configuration
        // mid-Athlete-Home is a materially different, less obviously
        // useful action, so this entry point's purpose is genuinely
        // less clear under the new IA. Per this round's explicit
        // instruction, left in place rather than removed or redesigned
        // — reported here as follow-up to evaluate, not resolved
        // silently. (3) It still works correctly either way: the sheet
        // now uniformly reuses the same `AthleteFamilyManagementView`
        // row → `AthleteSettingsView` destination as every other call
        // site, and `presentationMode: .modal` is unchanged, so "Done"
        // still dismisses it.
        .sheet(isPresented: $isManagingAthletes) {
            NavigationStack {
                AthleteFamilyManagementView(
                    viewModel: athleteManagementViewModel,
                    presentationMode: .modal,
                    sleepSettingsViewModel: { athlete in
                        AthleteSleepSettingsViewModel(
                            sleepCoordinationService: sleepCoordinationService,
                            athleteId: athlete.athleteId,
                            athleteDisplayName: athlete.givenName
                        )
                    }
                )
            }
        }
        .navigationDestination(for: HomeDashboardDestination.self) { destination in
            switch destination {
            case .activity(let rowId):
                if let familyHomeRow = HomeDashboardRowResolver.plannedRow(forId: rowId, in: viewModel.todayActivityState) {
                    ActivityDetailViewLoader(
                        plannedActivity: familyHomeRow.plannedActivity,
                        athleteId: athleteId,
                        athleteDisplayName: athleteDisplayName,
                        actorId: committedByActorId,
                        planningService: planningService,
                        trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                        onActivityLogged: {
                            homeDashboardDebugLog("onActivityLogged fired for rowId=\(rowId)")
                            viewModel.loadTodaysTraining()
                            viewModel.loadTodayActivityRows()
                        }
                    )
                }
            case .recurringOccurrence(let id):
                if let suggestion = HomeDashboardRowResolver.recurringSuggestion(forId: id, in: viewModel.todayActivityState) {
                    RecurringOccurrencePreviewView(
                        suggestion: suggestion,
                        athleteDisplayName: athleteDisplayName,
                        planningService: planningService,
                        trainingService: trainingService,
                        trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                        actorId: committedByActorId,
                        onActivityLogged: {
                            homeDashboardDebugLog("onActivityLogged fired for recurringOccurrence id=\(id)")
                            viewModel.loadTodaysTraining()
                            viewModel.loadTodayActivityRows()
                        }
                    )
                }
            case .sleepCapture(let localDate):
                sleepCaptureDestination(localDate: localDate)
            }
        }
        .onAppear {
            homeDashboardDebugLog("onAppear athleteId=\(athleteId.rawValue.uuidString) viewModel=\(ObjectIdentifier(viewModel))")
            viewModel.loadTodaysTraining()
            viewModel.loadTodayActivityRows()
            viewModel.loadCoachingSummary()
            viewModel.loadSleepState()
        }
    }

    /// VX-023 (Sleep V1): compact card — "enabled + today has Sleep ->
    /// 'Sleep / 4/5'; enabled + missing -> 'Sleep / Sleep not logged
    /// yet'; disabled -> no card at all." Tapping opens the SAME
    /// canonical Sleep capture used everywhere else (today's
    /// `LocalDate`). The morning in-app prompt (below) is a SEPARATE,
    /// additional element — this card itself never changes shape based
    /// on prompt eligibility.
    ///
    /// Athlete Home "Now" restructure round (Part C): this used to be
    /// followed by a second, separate "Sleep History" row/link. Removed
    /// — "one compact Sleep row/card only" per that round's approved
    /// direction. The remaining "Sleep" row's own destination is
    /// UNCHANGED (still today's `.sleepCapture`, exactly as before);
    /// only the extra row disappeared. `SleepHistoryView` itself,
    /// `SleepHistoryViewModel`, and Sleep history semantics are
    /// untouched — Family Home still links to Sleep History directly
    /// (`FamilyHomeContentView`'s own separate entry point), so the
    /// full history list remains reachable in the app; it is simply no
    /// longer duplicated as a second row on this screen.
    @ViewBuilder
    private var sleepSection: some View {
        switch viewModel.sleepState {
        case .loading, .trackingDisabled, .failed:
            EmptyView()
        case .loaded(let sleepQuality):
            let today = SleepCoordinationService.today()
            Section {
                NavigationLink(value: HomeDashboardDestination.sleepCapture(localDate: today)) {
                    HStack {
                        Text("Sleep")
                        Spacer()
                        if let sleepQuality {
                            Text("\(sleepQuality)/5")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Sleep not logged yet")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("homeDashboard.sleepCard")

                if viewModel.isSleepPromptEligible() {
                    // Lightweight, non-blocking, dismissible morning
                    // prompt — never a phone notification (that's
                    // VX-026/VX-027, explicitly out of scope here).
                    // Dismissing only records local, in-memory
                    // presentation state (`dismissSleepPrompt()`) — it
                    // never disables Sleep tracking itself.
                    HStack {
                        Text("How did you sleep last night?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") {
                            viewModel.dismissSleepPrompt()
                        }
                        .font(.caption)
                        .accessibilityIdentifier("homeDashboard.sleepPrompt.dismissButton")
                    }
                    .accessibilityIdentifier("homeDashboard.sleepPrompt")
                }
            }
            .accessibilityIdentifier("homeDashboard.sleepSection")
        }
    }

    private func sleepCaptureDestination(localDate: LocalDate) -> some View {
        let today = SleepCoordinationService.today()
        let existing: Int? = {
            if case .loaded(let sleepQuality) = viewModel.sleepState, localDate == today {
                return sleepQuality
            }
            return try? sleepCoordinationService.fetchDailyStatus(forAthlete: athleteId, localDate: localDate)?.sleepQuality
        }()
        return SleepCaptureView(
            viewModel: SleepCaptureViewModel(
                sleepCoordinationService: sleepCoordinationService,
                athleteId: athleteId,
                athleteDisplayName: athleteDisplayName,
                localDate: localDate,
                existingSleepQuality: existing,
                today: today
            ),
            onSaved: {
                viewModel.loadSleepState()
            }
        )
    }

    /// Sprint 1.1, P2: the `dailyFocusCard` UI section that used to live
    /// here (`DailyFocusCardView`) was removed — it duplicated
    /// `trainingSection`'s own "Strength — Not yet logged" content with
    /// no additional information, exactly the redundancy this work
    /// package identified. Removed the VIEW only:
    /// `HomeDashboardViewModel.dailyFocusState`,
    /// `loadCoachingSummary()`, and `DailyFocusComposer` are all
    /// untouched — no domain concept or persistence was deleted, and
    /// nothing was invented to replace this section, per this work
    /// package's own explicit constraint. A future, genuinely
    /// contextual Daily Focus (reflection/load/recommendation-based) is
    /// out of scope here.
    ///
    /// Athlete Home "Now" restructure round (Part A): the separate
    /// `welcomeSection` card that used to sit here — a large,
    /// standalone "Victor / 2026-08-17" block — is removed entirely.
    /// It duplicated the athlete's identity, which the navigation title
    /// (`"\(athleteDisplayName) Home"`) already states, and its date
    /// was the week's Monday (`weekStart.isoString`), not today. The
    /// compact replacement — today's actual date, secondary-styled —
    /// now lives at the top of `todaySection` below, per this round's
    /// own preferred direction ("a small secondary date line near the
    /// top / Today section"). No second athlete-identity presentation
    /// was introduced.

    /// A summary, not the entire Weekly Review — shows only the
    /// highest-priority section. "Highest-priority" here means
    /// `sections.first`: `CoachingPresentation.sections` is already in
    /// a fixed, deterministic order (Planned Activities → Weekly
    /// Reflection → Parent Observations — see
    /// `CoachingPresentationMapper`), and that existing order is reused
    /// as the priority signal rather than this view inventing a new
    /// ranking. No new coaching logic is introduced here — the section
    /// is simply reused, not recomputed or reinterpreted.
    @ViewBuilder
    private var coachingSection: some View {
        switch viewModel.coachingSummaryState {
        case .loading:
            EmptyView()
        case .failed:
            Section("Coaching") {
                Text(CoachingPresentationStrings.unavailable)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("homeDashboard.coaching.unavailable")
            }
        case .loaded(let presentation):
            if let topSection = presentation.sections.first {
                Section("Coaching") {
                    NavigationLink {
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
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(topSection.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ForEach(topSection.items, id: \.insight) { item in
                                Text(item.text)
                            }
                        }
                    }
                    .accessibilityIdentifier("homeDashboard.coaching.summary")
                }
            }
            // An empty presentation (no findings) renders nothing here
            // — no invented "everything looks good" message, matching
            // the same rule `WeeklyReviewView`'s own coaching section
            // already follows.
        }
    }

    /// Athlete Home "Now" restructure round (Part D): the permanent
    /// "Planning / Weekly Plan >" menu row that used to live here is
    /// removed — Plan already has its own dedicated top-level tab
    /// (`ParentTabShellView`, which constructs `WeeklyPlanningView`
    /// independently of this screen), so this was a duplicate,
    /// permanent navigation entry rather than "Now" content. Per this
    /// round's explicit instruction, nothing replaces it — no new
    /// planning insight/card was invented, and `WeeklyPlanningView`/
    /// `WeeklyPlanningViewModel`/Planning semantics are all untouched
    /// and remain fully reachable via the Plan tab.

    /// Renders one row of today's activities (with completion state
    /// already derived by `TrainingPlanningCoordinationService`, never
    /// recomputed here). The permanent "Daily Training >" shortcut that
    /// used to sit below these rows in `todaySection` was removed in
    /// the Athlete Home "Now" restructure round (Part B/ownership) —
    /// Training already has its own dedicated top-level tab.
    @ViewBuilder
    private func todayActivityRow(_ row: TodayActivityRow) -> some View {
        switch row {
        case .planned(let familyHomeRow):
            NavigationLink(value: HomeDashboardDestination.activity(rowId: familyHomeRow.id)) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(familyHomeRow.plannedActivity.title)
                        if let location = familyHomeRow.plannedActivity.location, !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        // Activity outcome consistency closeout (item B):
                        // the real outcome — a Cancelled or Missed
                        // activity must never show as Completed here,
                        // the same fix already applied to Family Home's
                        // equivalent row label.
                        let _ = homeDashboardDebugLog("render row=\(familyHomeRow.id) outcomeStatus=\(String(describing: familyHomeRow.outcomeStatus))")
                        Text(TrainingStrings.outcomeLabel(for: familyHomeRow.outcomeStatus))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if familyHomeRow.isFromRecurring {
                            Text("Recurring")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier("homeDashboard.todaysTraining.row.\(familyHomeRow.id)")
        case .recurringOccurrence(_, _, let suggestion):
            NavigationLink(value: HomeDashboardDestination.recurringOccurrence(id: suggestion.id)) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(suggestion.title)
                        if let location = suggestion.location, !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("Recurring")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("homeDashboard.todaysTraining.recurringRow.\(suggestion.id)")
        case .unplannedLogged(_, _, let loggedActivity):
            HStack {
                VStack(alignment: .leading) {
                    Text(loggedActivity.title)
                    Text("Unplanned · Logged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityIdentifier("homeDashboard.todaysTraining.unplannedLoggedRow.\(loggedActivity.id.uuidString)")
        }
    }

    /// Athlete Home "Now" restructure round (Parts A/B): the primary
    /// section, first in the Form. Two things merged into one section
    /// here, deliberately:
    ///
    /// 1. The compact date line that replaces the removed
    ///    `welcomeSection` card (Part A) — today's actual date
    ///    (`TrainingPlanningCoordinationService.today()`, the same
    ///    canonical "today" this screen's Sleep card already computes
    ///    with), formatted via `Self.todayDateLabel(for:)` below, which
    ///    composes two already-established formatting techniques
    ///    (`WeeklyPlanningView.weekdayLabel(for:)`, and the
    ///    `Calendar(identifier: .gregorian)`/`monthSymbols` technique
    ///    `AthleteBirthDateFormatter` already establishes) — not a new
    ///    date computation.
    /// 2. What used to be `trainingSection`'s activity rows (Part B) —
    ///    same `viewModel.todayActivityState`/`todayActivityRow(_:)` as
    ///    before, the exact canonical, already-deduplicated "today" read
    ///    model `TodayActivityComposer` already provides (shared with
    ///    Family Home) — reused verbatim, not recomputed. The permanent
    ///    "Daily Training >" menu link that used to sit at the bottom of
    ///    this section is removed (Training already has its own
    ///    dedicated top-level tab, same reasoning as Part D's Weekly
    ///    Plan row removal below) and a `.loaded([])` empty state ("No
    ///    training today") is now shown explicitly rather than rendering
    ///    nothing.
    private var todaySection: some View {
        Section("Today") {
            Text(Self.todayDateLabel(for: TrainingPlanningCoordinationService.today()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("homeDashboard.todayDateLabel")

            switch viewModel.todayActivityState {
            case .loading:
                EmptyView()
            case .failed:
                Text(CoachingPresentationStrings.unavailable)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("homeDashboard.todaysTraining.unavailable")
            case .loaded(let rows):
                if rows.isEmpty {
                    Text("No training today")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("homeDashboard.today.noTrainingToday")
                } else {
                    ForEach(rows) { row in
                        todayActivityRow(row)
                    }
                }
            }
        }
    }

    /// See `todaySection`'s own doc comment for the two existing
    /// techniques this composes — purely presentational, no new date
    /// arithmetic. "Tuesday, 18 August": weekday name, day, full month;
    /// no year, matching this round's own approved target concept.
    private static func todayDateLabel(for today: LocalDate) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        let month = formatter.monthSymbols[today.month - 1]
        return "\(WeeklyPlanningView.weekdayLabel(for: today.weekday)), \(today.day) \(month)"
    }

    private var reflectionSection: some View {
        Section("Reflection") {
            NavigationLink("Add Reflection") {
                ReflectionFormViewLoader(
                    athleteId: athleteId,
                    athleteDisplayName: athleteDisplayName,
                    weekStart: viewModel.weekStart,
                    authorId: committedByActorId,
                    weeklyReflectionService: weeklyReflectionService
                )
            }
            .accessibilityIdentifier("homeDashboard.addReflectionLink")

            NavigationLink("Weekly Review") {
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
            .accessibilityIdentifier("homeDashboard.weeklyReviewLink")
        }
    }
}
