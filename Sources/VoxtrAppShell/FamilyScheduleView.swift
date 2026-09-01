import SwiftUI
import VoxtrCoreContracts
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
public struct FamilyScheduleView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: FamilyScheduleViewModel
    private let actorId: ActorId
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    private let notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService
    private let calendarSourcesViewModel: FamilyCalendarSourcesViewModel?

    public init(
        viewModel: FamilyScheduleViewModel,
        actorId: ActorId,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService,
        calendarSourcesViewModel: FamilyCalendarSourcesViewModel? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.actorId = actorId
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.notificationsPlanningCoordinationService = notificationsPlanningCoordinationService
        self.calendarSourcesViewModel = calendarSourcesViewModel
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

            if viewModel.dayGroups.isEmpty {
                Section {
                    Text("No upcoming activities planned yet.")
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                }
                .voxtrRowSurface()
            } else {
                ForEach(viewModel.dayGroups) { group in
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
        }
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle("Family Schedule")
        .onAppear {
            viewModel.loadSchedule()
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
