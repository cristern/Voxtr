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
    // Athlete Home "Now" restructure round (Part C, Sleep compaction):
    // `.sleepHistory` and its `sleepHistoryDestination` view were
    // removed together with the standalone "Sleep History" row that
    // was their only trigger in this file. `SleepHistoryView` itself is
    // untouched and remains reachable via Family Home's own separate
    // "Sleep History" entry point (`FamilyHomeContentView`).
    //
    // Athlete Home Sleep inline round: `.sleepCapture(localDate:)` is
    // removed the same way — its only trigger was the Sleep row's
    // `NavigationLink`, which is now the inline 1-5 control below (see
    // `sleepSection`'s own doc comment). This screen's Sleep control no
    // longer navigates anywhere for today; `SleepCaptureView`/
    // `SleepCaptureViewModel` themselves are untouched and remain used
    // by `SleepHistoryView`'s own per-date rows (historical
    // correction/backfill), so nothing was removed from the app —
    // only this file's now-unreachable trigger for it.
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
    /// VX-023 (Sleep V1): threaded through to the "Manage Athletes"
    /// sheet's own nested `HomeDashboardViewModel`/
    /// `AthleteSleepSettingsViewModel` construction below — its only
    /// remaining use in this file. Athlete Home Sleep inline round: no
    /// longer used to construct `SleepCaptureViewModel` here — this
    /// screen's Sleep control is now inline and saves through
    /// `viewModel.recordSleep(quality:)` instead of navigating to a
    /// capture screen (see `sleepSection`'s own doc comment); this
    /// concrete service is not threaded into `HomeDashboardViewModel`
    /// itself for that either, since `HomeDashboardViewModel` already
    /// holds its own protocol-typed `SleepStatusProviding` seam
    /// (extended with `recordSleep` this round) rather than taking a
    /// second, concrete Sleep dependency.
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
        // Design Foundation V0.1: same screen background token Family
        // Home uses, applied identically — ONE consistent Parent App
        // visual system, never a distinct Athlete Home theme. Structure/
        // navigation/rows below are unchanged.
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
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

    /// Athlete Home Sleep inline round: applies this app's approved
    /// interaction principle ("complete simple actions in context") —
    /// Sleep quality for today is one value with five options, so it is
    /// now completed directly here rather than behind a navigation push.
    /// "enabled + missing -> question + five tappable values, none
    /// selected; enabled + recorded -> five values, the canonical one
    /// selected; disabled -> no card at all." Same native
    /// button-row-with-selected-state visual convention
    /// `WeekdayMultiSelectView` already establishes elsewhere in this
    /// app (circular/rounded buttons, accent-filled when selected,
    /// `.isSelected` accessibility trait) — not a new control shape.
    ///
    /// Tapping a value calls `viewModel.recordSleep(quality:)` directly
    /// — no chevron, no separate current-day capture screen, no Save
    /// button. Tapping a DIFFERENT value later corrects today's value
    /// through the exact same call (canonical upsert — see that
    /// method's own doc comment). `sleepState` itself is the single
    /// source of truth for which value (if any) is selected; a
    /// successful save reloads it from canonical truth via
    /// `loadSleepState()` inside `recordSleep(quality:)` — no locally
    /// held "just tapped" value is ever displayed ahead of what was
    /// actually persisted.
    ///
    /// The previous separate, ambiguous "How did you sleep last night? /
    /// Dismiss" morning prompt row is removed — the missing-Sleep
    /// question and the input are now the same element, so a second,
    /// dismissible prompt asking the identical question would be
    /// duplicate prompting for the same missing value. This inline
    /// control has no dismiss action; it doesn't need one, since it's
    /// the answer, not a reminder to go answer elsewhere.
    /// `HomeDashboardViewModel.isSleepPromptEligible()`/
    /// `dismissSleepPrompt()` are deliberately left in place, unused by
    /// this screen now — see this file's own audit notes in the
    /// delivery report for why they were not deleted.
    ///
    /// Athlete Home "Now" restructure round (Part C, still true here):
    /// no separate "Sleep History" row — Family Home's own entry point
    /// remains the path to the full history/backfill list.
    @ViewBuilder
    private var sleepSection: some View {
        switch viewModel.sleepState {
        case .loading, .trackingDisabled, .failed:
            EmptyView()
        case .loaded(let sleepQuality):
            Section {
                if sleepQuality == nil {
                    Text("How did you sleep last night?")
                        .font(VoxtrTypography.body)
                        .foregroundStyle(VoxtrColor.textSecondary)
                        .accessibilityIdentifier("homeDashboard.sleepPrompt")
                }

                // Design Foundation V0.1: the inline 1-5 control gets
                // its own bordered `surfaceSubtle` card (via
                // `voxtrCardSurface()`) — distinct from a plain Form
                // row — so it reads as an intentional input surface,
                // not a temporary/debug-looking row of plain buttons.
                // Selected: filled `accent`, white numeral. Unselected:
                // calm `surfaceSubtle`-on-`surfaceSubtle` (effectively
                // just the divider-bordered card background showing
                // through) with `textSecondary` numerals — never
                // competing visually with the selected value. Save
                // semantics (direct tap, canonical upsert) are
                // completely unchanged — only the visual treatment.
                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { value in
                        let isSelected = value == sleepQuality
                        Button {
                            viewModel.recordSleep(quality: value)
                        } label: {
                            Text("\(value)")
                                .font(VoxtrTypography.value)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(isSelected ? VoxtrColor.accent : Color.clear)
                                .foregroundStyle(isSelected ? .white : VoxtrColor.textSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("homeDashboard.sleepValueButton.\(value)")
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }
                .padding(6)
                .voxtrCardSurface(cornerRadius: 12)
                .accessibilityIdentifier("homeDashboard.sleepValuePicker")

                if let sleepErrorMessage = viewModel.sleepErrorMessage {
                    Text(sleepErrorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("homeDashboard.sleepErrorMessage")
                }
            } header: {
                VoxtrSectionHeading("Sleep")
            }
            .voxtrRowSurface()
            .accessibilityIdentifier("homeDashboard.sleepSection")
        }
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
            Section {
                Text(CoachingPresentationStrings.unavailable)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("homeDashboard.coaching.unavailable")
            } header: {
                VoxtrSectionHeading("Coaching")
            }
            .voxtrRowSurface()
        case .loaded(let presentation):
            if let topSection = presentation.sections.first {
                // Visual goal: Coaching must not overpower Today — its
                // own title stays at `metadata` weight (same
                // sub-emphasis as before), and its content uses `body`
                // rather than `cardTitle`, so it never reads as more
                // prominent than Today's own activity rows above it.
                Section {
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
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                            ForEach(topSection.items, id: \.insight) { item in
                                Text(item.text)
                                    .font(VoxtrTypography.body)
                                    .foregroundStyle(VoxtrColor.textPrimary)
                            }
                        }
                    }
                    .accessibilityIdentifier("homeDashboard.coaching.summary")
                } header: {
                    VoxtrSectionHeading("Coaching")
                }
                .voxtrRowSurface()
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
                            .font(VoxtrTypography.cardTitle)
                            .foregroundStyle(VoxtrColor.textPrimary)
                        if let location = familyHomeRow.plannedActivity.location, !location.isEmpty {
                            Text(location)
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
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
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                        if familyHomeRow.isFromRecurring {
                            Text("Recurring")
                                .font(VoxtrTypography.caption)
                                .foregroundStyle(VoxtrColor.textSecondary)
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
                            .font(VoxtrTypography.cardTitle)
                            .foregroundStyle(VoxtrColor.textPrimary)
                        if let location = suggestion.location, !location.isEmpty {
                            Text(location)
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                        }
                    }
                    Spacer()
                    Text("Recurring")
                        .font(VoxtrTypography.caption)
                        .foregroundStyle(VoxtrColor.textSecondary)
                }
            }
            .accessibilityIdentifier("homeDashboard.todaysTraining.recurringRow.\(suggestion.id)")
        case .unplannedLogged(_, _, let loggedActivity):
            HStack {
                VStack(alignment: .leading) {
                    Text(loggedActivity.title)
                        .font(VoxtrTypography.cardTitle)
                        .foregroundStyle(VoxtrColor.textPrimary)
                    Text("Unplanned · Logged")
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
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
        Section {
            Text(Self.todayDateLabel(for: TrainingPlanningCoordinationService.today()))
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
                .accessibilityIdentifier("homeDashboard.todayDateLabel")

            switch viewModel.todayActivityState {
            case .loading:
                EmptyView()
            case .failed:
                Text(CoachingPresentationStrings.unavailable)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("homeDashboard.todaysTraining.unavailable")
            case .loaded(let rows):
                if rows.isEmpty {
                    Text("No training today")
                        .font(VoxtrTypography.body)
                        .foregroundStyle(VoxtrColor.textSecondary)
                        .accessibilityIdentifier("homeDashboard.today.noTrainingToday")
                } else {
                    ForEach(rows) { row in
                        todayActivityRow(row)
                    }
                }
            }
        } header: {
            VoxtrSectionHeading("Today")
        }
        .voxtrRowSurface()
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
        Section {
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
        } header: {
            VoxtrSectionHeading("Reflection")
        }
        .voxtrRowSurface()
    }
}
