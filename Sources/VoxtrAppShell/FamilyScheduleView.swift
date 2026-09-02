import SwiftUI
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrCalendarPlanningDomain

/// Sprint 1 completion package, Part 5, extended in Sprint 1.1 P1.
/// "Family Schedule" — a forward-looking overview of upcoming planned
/// activity across every active athlete, grouped clearly by date.
/// Deliberately not a calendar grid, per this work's own constraint
/// ("Vǫxtr is a development/planning product, not Google Calendar").
///
/// Now shows both real, planned activities AND recurring occurrences
/// that have not yet been materialized into a real `PlannedActivity`
/// (see `FamilyScheduleRow`'s own doc comment). A `.planned` row opens
/// the SAME shared `ActivityDetailView` every other surface uses, via
/// `ActivityDetailViewLoader` — "tapping an occurrence uses the
/// canonical Activity Detail path where the domain model supports it."
/// A `.recurringSuggestion` row has no `PlannedActivityId` yet, so it
/// is shown but not tappable into Activity Detail — accepting it
/// remains that athlete's Weekly Plan screen's own job, not duplicated
/// here.
///
/// Plan/Ahead root round: also shows an optional, calm, contextual
/// "N calendar events to review" entry point near the top of the
/// screen — ONLY when `viewModel.calendarReviewPrompt.totalPendingCount`
/// is actually positive (Calm by Default: no permanent "0 events"
/// section). Tapping it reuses the EXISTING Calendar Import Review /
/// Calendar Sources screens verbatim — never a second, parallel review
/// implementation: straight to that ONE source's own
/// `CalendarImportReviewView` when exactly one connected source has
/// pending work, or to the existing `FamilyCalendarSourcesView` list
/// (which already shows every source's own review count and its own
/// link into `CalendarImportReviewView`) when more than one does. Only
/// meaningful when `calendarSourcesViewModel` is supplied — `nil` for
/// this view's OTHER production entry point
/// (`FamilyHomeContentView`'s "View upcoming schedule" destination),
/// which does not opt into this feature; `viewModel.calendarReviewPrompt`
/// itself already defaults to `.none` there regardless, so this is
/// purely a defensive "no destination to navigate to" guard, never the
/// actual gate.
///
/// VX-037 round: also shows a compact, toolbar-based athlete filter
/// (`viewModel.selectedAthleteIds`, empty = "All," the default) — pure
/// VIEW STATE that only changes which of `viewModel.dayGroups`' rows
/// `viewModel.visibleDayGroups` returns, never Planning truth, athlete
/// ownership, or calendar import state. `viewModel.calendarReviewPrompt`
/// is deliberately unaffected by this filter (family/source work, not
/// athlete-filtered schedule truth). When the filter narrows to exactly
/// one athlete, the toolbar's Weekly Plan action collapses to a single
/// direct button to that athlete's EXISTING `WeeklyPlanningView` (via
/// `onNavigateToWeeklyPlan`, supplied by the caller that owns the real
/// navigation stack/path — see that property's own doc comment);
/// otherwise it stays the full, explicit picker across every active
/// athlete — this view never guesses which athlete's Weekly Plan the
/// Parent wants.
///
/// "Show 2 more weeks" round: a calm, secondary action at the bottom of
/// the list (after the last loaded day, or after the empty-state
/// message — never a dead end) lets the Parent progressively widen
/// `viewModel.horizonDays` via `viewModel.extendHorizon()`, up to a
/// bounded maximum (`viewModel.canExtendHorizon` gates whether the
/// action is even shown). The schedule's default, calm short horizon
/// itself is unchanged — this only adds an explicit, capped way to look
/// further ahead in the SAME view, never a permanent long horizon or a
/// date-range picker.
public struct FamilyScheduleView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: FamilyScheduleViewModel
    private let actorId: ActorId
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    private let notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService
    private let calendarSourcesViewModel: FamilyCalendarSourcesViewModel?
    /// VX-037: when supplied, drives the toolbar's Weekly Plan action —
    /// called with the athlete to navigate to. The CALLER owns the real
    /// `NavigationPath`/`.navigationDestination(for:)` this pushes onto
    /// (see `ParentPlanTabView`'s own doc comment for why: `FamilyScheduleView`
    /// deliberately owns no `NavigationStack` of its own, so it cannot
    /// safely hold a path binding that would work identically from both
    /// of this view's production entry points). `nil` for the OTHER
    /// entry point (`FamilyHomeContentView`'s "View upcoming schedule"
    /// destination), which never offered a Weekly Plan shortcut before
    /// this round either — so that entry point's behavior here is
    /// unchanged; only the NEW athlete filter is shared across both.
    private let onNavigateToWeeklyPlan: ((AthleteId) -> Void)?

    public init(
        viewModel: FamilyScheduleViewModel,
        actorId: ActorId,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        calendarSourcesViewModel: FamilyCalendarSourcesViewModel? = nil,
        onNavigateToWeeklyPlan: ((AthleteId) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.actorId = actorId
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.notificationsPlanningCoordinationService = notificationsPlanningCoordinationService
        self.calendarSourcesViewModel = calendarSourcesViewModel
        self.onNavigateToWeeklyPlan = onNavigateToWeeklyPlan
    }

    public var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("familySchedule.errorMessage")
                }
                .voxtrRowSurface()
            }

            // Plan/Ahead root round: calm, contextual — never shown at
            // all when there is nothing to review (Calm by Default), and
            // never rendered without a real destination to navigate to.
            if let calendarSourcesViewModel, viewModel.calendarReviewPrompt.totalPendingCount > 0 {
                Section {
                    NavigationLink {
                        calendarReviewDestination(calendarSourcesViewModel: calendarSourcesViewModel)
                    } label: {
                        Text(CalendarPlanningStrings.familyScheduleCalendarReviewPrompt(count: viewModel.calendarReviewPrompt.totalPendingCount))
                            .font(VoxtrTypography.cardTitle)
                            .foregroundStyle(VoxtrColor.textPrimary)
                    }
                    .accessibilityIdentifier("familySchedule.calendarReviewLink")
                }
                .voxtrRowSurface()
            }

            if viewModel.visibleDayGroups.isEmpty {
                Section {
                    Text("No upcoming activities planned yet.")
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                }
                .voxtrRowSurface()
            } else {
                ForEach(viewModel.visibleDayGroups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            scheduleRow(row)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        VoxtrSectionHeading(Self.dayHeading(for: group.date))
                    }
                    .voxtrRowSurface()
                    .accessibilityIdentifier("familySchedule.dayGroup.\(group.id)")
                }
            }

            // "Show 2 more weeks" round: placed AFTER the last loaded
            // day (or after the empty-state message, so an empty short
            // window is never a dead end — the Parent can still ask to
            // look further ahead). Visible whenever
            // `viewModel.canExtendHorizon` is true, regardless of the
            // current athlete filter or whether the current window has
            // any rows — this is about the schedule's TIME horizon, not
            // which athletes/rows are currently shown.
            if viewModel.canExtendHorizon {
                Section {
                    Button {
                        viewModel.extendHorizon()
                        viewModel.loadSchedule()
                    } label: {
                        Text("Show 2 more weeks")
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .accessibilityIdentifier("familySchedule.showMoreWeeksButton")
                }
                .voxtrRowSurface()
            }
        }
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle("Family Schedule")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                weeklyPlanToolbarContent
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                athleteFilterMenu
            }
        }
        .onAppear {
            viewModel.loadSchedule()
        }
    }

    /// VX-037: family Ahead → athlete filter. Compact, native `Menu` —
    /// never a large permanent selector section pushing the schedule
    /// down (per this round's own "Calm by Default" contract). "All
    /// Athletes" (empty selection) and every active athlete are each a
    /// toggle — tapping an already-selected athlete deselects it, so
    /// multiple athletes can be built up one tap at a time. Shown
    /// whenever there is at least one active athlete to filter by,
    /// regardless of which of `FamilyScheduleView`'s two production
    /// entry points pushed this screen — the SAME shared filter state
    /// (`viewModel.selectedAthleteIds`) either way, never a second,
    /// locally-invented selection model.
    @ViewBuilder
    private var athleteFilterMenu: some View {
        if !viewModel.activeAthletes.isEmpty {
            Menu {
                Button {
                    viewModel.setSelectedAthletes([])
                } label: {
                    if viewModel.selectedAthleteIds.isEmpty {
                        Label("All Athletes", systemImage: "checkmark")
                    } else {
                        Text("All Athletes")
                    }
                }
                .accessibilityIdentifier("familySchedule.athleteFilter.all")

                Divider()

                ForEach(viewModel.activeAthletes, id: \.athleteId) { athlete in
                    Button {
                        toggleAthleteFilter(athlete.athleteId)
                    } label: {
                        if viewModel.selectedAthleteIds.contains(athlete.athleteId) {
                            Label(athlete.givenName, systemImage: "checkmark")
                        } else {
                            Text(athlete.givenName)
                        }
                    }
                    .accessibilityIdentifier("familySchedule.athleteFilter.athlete.\(athlete.athleteId.rawValue.uuidString)")
                }
            } label: {
                Label(athleteFilterSummary, systemImage: "person.crop.circle.badge.checkmark")
            }
            .accessibilityIdentifier("familySchedule.athleteFilterMenu")
        }
    }

    private func toggleAthleteFilter(_ athleteId: AthleteId) {
        var updated = viewModel.selectedAthleteIds
        if updated.contains(athleteId) {
            updated.remove(athleteId)
        } else {
            updated.insert(athleteId)
        }
        viewModel.setSelectedAthletes(updated)
    }

    /// Compact toolbar label text for the current filter — "All" by
    /// default, the one athlete's given name when exactly one is
    /// selected, otherwise a plain count. Deliberately never a ranking
    /// or performance-flavored count — purely how many athletes are
    /// currently included in the view.
    private var athleteFilterSummary: String {
        if viewModel.selectedAthleteIds.isEmpty {
            return "All"
        }
        if let onlyId = viewModel.singleSelectedAthleteId,
           let athlete = viewModel.activeAthletes.first(where: { $0.athleteId == onlyId }) {
            return athlete.givenName
        }
        return "\(viewModel.selectedAthleteIds.count) athletes"
    }

    /// VX-037: family Ahead → one athlete → Weekly Plan. Only rendered
    /// when a destination is actually reachable
    /// (`onNavigateToWeeklyPlan` supplied) and there is at least one
    /// active athlete. Exactly one selected athlete collapses this to a
    /// single direct action — no submenu needed, since the filter has
    /// already made the choice unambiguous; `All` or multiple selected
    /// athletes keeps the full explicit picker across every active
    /// athlete (never narrowed to just the filtered subset — the filter
    /// controls what the SCHEDULE shows, not which athlete's Weekly Plan
    /// is reachable), so the Parent's choice is always explicit, never
    /// guessed.
    @ViewBuilder
    private var weeklyPlanToolbarContent: some View {
        if let onNavigateToWeeklyPlan, !viewModel.activeAthletes.isEmpty {
            if let singleAthleteId = viewModel.singleSelectedAthleteId,
               viewModel.activeAthletes.contains(where: { $0.athleteId == singleAthleteId }) {
                Button {
                    onNavigateToWeeklyPlan(singleAthleteId)
                } label: {
                    Label("Weekly Plan", systemImage: "calendar.badge.clock")
                }
                .accessibilityIdentifier("familySchedule.weeklyPlanDirectButton")
            } else {
                Menu {
                    ForEach(viewModel.activeAthletes, id: \.athleteId) { athlete in
                        Button(athlete.givenName) {
                            onNavigateToWeeklyPlan(athlete.athleteId)
                        }
                    }
                } label: {
                    Label("Weekly Plan", systemImage: "calendar.badge.clock")
                }
                .accessibilityIdentifier("familySchedule.weeklyPlanMenu")
            }
        }
    }

    /// Plan/Ahead root round: the smallest coherent navigation reusing
    /// the EXISTING Calendar Import Review / Calendar Sources screens —
    /// never a second, parallel review implementation, and never a
    /// relocation of Calendar Sources configuration ownership (still
    /// reached from Profile as before; this is only a SECOND navigation
    /// path into the SAME screens). Exactly one actionable source routes
    /// straight to that source's own `CalendarImportReviewView` (via the
    /// EXISTING `FamilyCalendarSourcesViewModel.makeImportReviewViewModel(for:)`
    /// factory `CalendarSourceDetailView` already uses); more than one
    /// routes to the EXISTING `FamilyCalendarSourcesView` list, which
    /// already shows every source's own review count and its own link
    /// into `CalendarImportReviewView` — never a NEW multi-source list.
    ///
    /// Codemagic compile fix: `viewModel.calendarReviewPrompt.actionableSources`
    /// is now `[ExternalPlanningSourceId]` (see that type's own doc
    /// comment), so the single-source case resolves the actual
    /// `ExternalPlanningSource` from `calendarSourcesViewModel.sources` —
    /// the SAME already-loaded list `calendarReviewPrompt` was computed
    /// from, never a second fetch. If the id somehow does not resolve
    /// (never expected in practice, since both come from the same
    /// underlying `FamilyCalendarSourcesViewModel`), this falls back to
    /// the multi-source list rather than crashing or showing nothing.
    @ViewBuilder
    private func calendarReviewDestination(calendarSourcesViewModel: FamilyCalendarSourcesViewModel) -> some View {
        let actionableSourceIds = viewModel.calendarReviewPrompt.actionableSources
        if actionableSourceIds.count == 1,
           let onlySourceId = actionableSourceIds.first,
           let onlySource = calendarSourcesViewModel.sources.first(where: { $0.externalPlanningSourceId == onlySourceId }) {
            CalendarImportReviewView(viewModel: calendarSourcesViewModel.makeImportReviewViewModel(for: onlySource))
        } else {
            FamilyCalendarSourcesView(viewModel: calendarSourcesViewModel)
        }
    }

    @ViewBuilder
    private func scheduleRow(_ row: FamilyScheduleRow) -> some View {
        switch row {
        case .planned(let familyRow):
            NavigationLink {
                ActivityDetailViewLoader(
                    plannedActivity: familyRow.plannedActivity,
                    athleteId: familyRow.athleteId,
                    athleteDisplayName: familyRow.athleteName,
                    actorId: actorId,
                    planningService: planningService,
                    trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                    notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                    onActivityLogged: { viewModel.loadSchedule() }
                )
            } label: {
                rowContent(
                    athleteName: familyRow.athleteName,
                    title: ActivityLabelResolver(modelContext: modelContext).primaryLabel(for: familyRow.plannedActivity),
                    subtitle: Self.rowSubtitle(
                        startLocalTime: familyRow.plannedActivity.startLocalTime,
                        location: familyRow.plannedActivity.location,
                        outcomeStatus: familyRow.outcomeStatus
                    )
                )
            }
            .voxtrAthleteIdentityOutline(viewModel.resolvedAthleteColor(for: familyRow.athleteId).color)
            .accessibilityIdentifier("familySchedule.activityRow.\(row.id)")
        case .recurringSuggestion(_, let athleteId, let athleteName, let suggestion):
            NavigationLink {
                RecurringOccurrencePreviewView(
                    suggestion: suggestion,
                    athleteDisplayName: athleteName,
                    planningService: planningService,
                    trainingService: trainingService,
                    trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                    notificationsPlanningCoordinationService: notificationsPlanningCoordinationService,
                    actorId: actorId,
                    onActivityLogged: { viewModel.loadSchedule() }
                )
            } label: {
                rowContent(
                    athleteName: athleteName,
                    title: ActivityLabelResolver(modelContext: modelContext).primaryLabel(for: suggestion),
                    // Same-pattern fix (Family Home's own "Recurring
                    // metadata demotion" round): "Recurring" no longer
                    // renders as its own trailing label competing with
                    // this row's single chevron — folded into the same
                    // metadata subtitle line instead, matching Family
                    // Home's `.recurringOccurrence` row exactly.
                    subtitle: Self.recurringRowSubtitle(startLocalTime: suggestion.startLocalTime, location: suggestion.location)
                )
            }
            .voxtrAthleteIdentityOutline(viewModel.resolvedAthleteColor(for: athleteId).color)
            .accessibilityIdentifier("familySchedule.recurringRow.\(row.id)")
        }
    }

    private func rowContent(athleteName: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Athlete name leads each row — the simplest, most direct
            // way to make multiple athletes visually distinguishable in
            // one shared list, without separate per-athlete schedules.
            Text(athleteName)
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            HStack {
                VStack(alignment: .leading) {
                    Text(title)
                        .font(VoxtrTypography.cardTitle)
                        .foregroundStyle(VoxtrColor.textPrimary)
                    Text(subtitle)
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                }
                Spacer()
            }
        }
        // Outline geometry: no local horizontal/vertical padding here —
        // owned entirely by `voxtrAthleteIdentityOutline` itself, same
        // as every Family Home activity row.
    }

    /// Sprint 1.1 closeout, Item 3: weekday added, reusing the existing
    /// `WeeklyPlanningView.weekdayLabel(for:)` helper (already this
    /// app's own established weekday-name approach — see that
    /// function's own definition) rather than introducing a second,
    /// differently-sourced formatting approach for one screen. Derived
    /// from `LocalDate.weekday`, the same value every other weekday
    /// display in this app already uses. Presentation only — does not
    /// change `FamilyScheduleViewModel`'s sort/group semantics at all.
    private static func dayHeading(for date: LocalDate) -> String {
        "\(WeeklyPlanningView.weekdayLabel(for: date.weekday)) · \(date.isoString)"
    }

    /// Activity outcome consistency closeout (item B): `outcomeStatus`,
    /// not a blanket `isCompleted` Bool — a Cancelled or Missed activity
    /// must never show as Completed here, the same fix already applied
    /// to Family Home's/Athlete Home's equivalent labels. `nil` (never
    /// logged, including every recurring suggestion — inherently
    /// unresolved) appends nothing, matching this function's prior
    /// behavior for that exact case.
    private static func rowSubtitle(startLocalTime: LocalTime?, location: String?, outcomeStatus: ActivityStatus?) -> String {
        var parts: [String] = []
        if let startLocalTime {
            parts.append(String(format: "%02d:%02d", startLocalTime.hour, startLocalTime.minute))
        }
        if let location, !location.isEmpty {
            parts.append(location)
        }
        if let outcomeStatus {
            parts.append(TrainingStrings.outcomeLabel(for: outcomeStatus))
        }
        return parts.isEmpty ? "Ready to log" : parts.joined(separator: " · ")
    }

    /// Same-pattern fix (Family Home's own "Recurring metadata
    /// demotion" round, `FamilyHomeContentView.recurringRowSubtitle(for:)`):
    /// "Recurring" joins this row's metadata line instead of rendering
    /// as its own separate trailing label — the exact local hard-coded
    /// styling this round's same-pattern audit flags. Recurrence
    /// semantics are unchanged; only where this text renders changed.
    private static func recurringRowSubtitle(startLocalTime: LocalTime?, location: String?) -> String {
        var parts: [String] = []
        if let startLocalTime {
            parts.append(String(format: "%02d:%02d", startLocalTime.hour, startLocalTime.minute))
        }
        if let location, !location.isEmpty {
            parts.append(location)
        }
        parts.append("Recurring")
        return parts.joined(separator: " · ")
    }
}
