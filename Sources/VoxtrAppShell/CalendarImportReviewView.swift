import SwiftUI
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAthleteDomain
import VoxtrCalendarPlanningDomain

/// Calendar Import Review V1.1 (Inline Review + Ready Staging + Bulk
/// Import + Remembered Exact Choices; runtime fix: inline-only
/// interaction, reversible Ignore): the actual working surface for
/// classifying many upcoming events efficiently, for ONE source. Three
/// conceptual sections — NEEDS REVIEW (classify Athlete/Sport/Activity
/// Type directly on this screen), READY TO IMPORT (a compact summary row
/// for every fully staged event), and IGNORED (a compact, receding row
/// for every currently-ignored event still in the provider horizon,
/// with an explicit "Review again" reversal) — plus one explicit bulk-
/// import action. Classifying, editing, ignoring, and restoring all
/// happen right here on this ONE screen; there is deliberately no
/// per-event pushed detail screen (see this project's own "prefer
/// completing simple/related tasks inline" UX rule) — notes/location,
/// when present, expand inline via `DisclosureGroup` inside the SAME
/// row instead.
struct CalendarImportReviewView: View {
    @Bindable var viewModel: CalendarImportReviewViewModel
    @State private var itemPendingIgnore: CalendarPlanningCoordinationService.CalendarReviewItem?

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("calendarImportReview.errorMessage")
                }
            }

            if viewModel.reviewQueue.isEmpty && viewModel.ignoredItems.isEmpty {
                Text(CalendarPlanningStrings.reviewEmpty)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            } else {
                if !viewModel.needsReviewItems.isEmpty {
                    Section {
                        ForEach(viewModel.needsReviewItems, id: \.externalEventKey) { item in
                            NeedsReviewRow(item: item, viewModel: viewModel) {
                                itemPendingIgnore = item
                            }
                        }
                    } header: {
                        VoxtrSectionHeading(CalendarPlanningStrings.needsReviewSectionTitle)
                    } footer: {
                        Text(CalendarPlanningStrings.reviewExplanation)
                    }
                }

                if !viewModel.readyToImportItems.isEmpty {
                    Section {
                        ForEach(viewModel.readyToImportItems, id: \.externalEventKey) { item in
                            readyToImportRow(item)
                        }
                        Button(CalendarPlanningStrings.bulkImportButton(readyCount: viewModel.readyToImportCount)) {
                            viewModel.bulkImportReadyItems()
                        }
                        .accessibilityIdentifier("calendarImportReview.bulkImportButton")
                    } header: {
                        VoxtrSectionHeading(CalendarPlanningStrings.readyToImportSectionTitle)
                    }
                }

                if !viewModel.ignoredItems.isEmpty {
                    Section {
                        ForEach(viewModel.ignoredItems, id: \.externalEventKey) { item in
                            ignoredRow(item)
                        }
                    } header: {
                        VoxtrSectionHeading(CalendarPlanningStrings.ignoredSectionTitle)
                    }
                }
            }
        }
        .navigationTitle(CalendarPlanningStrings.reviewScreenTitle)
        .onAppear { viewModel.load() }
        .confirmationDialog(
            CalendarPlanningStrings.ignoreConfirmationTitle,
            isPresented: Binding(
                get: { itemPendingIgnore != nil },
                set: { if !$0 { itemPendingIgnore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(CalendarPlanningStrings.ignoreButton, role: .destructive) {
                if let itemPendingIgnore {
                    viewModel.ignore(itemPendingIgnore)
                }
                itemPendingIgnore = nil
            }
            .accessibilityIdentifier("calendarImportReview.confirmIgnoreButton")
            Button("Cancel", role: .cancel) { itemPendingIgnore = nil }
        } message: {
            Text(CalendarPlanningStrings.ignoreConfirmationMessage)
        }
    }

    // MARK: - READY TO IMPORT: compact summary, materially shorter than an editable row

    @ViewBuilder
    private func readyToImportRow(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) -> some View {
        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.event.title?.isEmpty == false ? item.event.title! : "(no title)")
                    .font(VoxtrTypography.cardTitle)
                    .foregroundStyle(VoxtrColor.textPrimary)
                Text(item.event.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                Text(readySummary(staged))
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
            Spacer()
            Text(CalendarPlanningStrings.readyBadge)
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            Button(CalendarPlanningStrings.editButton) {
                viewModel.beginEditing(for: item.externalEventKey)
            }
            .accessibilityIdentifier("calendarImportReview.editButton")
        }
        .accessibilityIdentifier("calendarImportReview.readyRow")
    }

    private func readySummary(_ staged: CalendarImportReviewViewModel.StagedClassification) -> String {
        var parts: [String] = []
        if let athleteId = staged.athleteId, let athlete = viewModel.athletes.first(where: { $0.athleteId == athleteId }) {
            parts.append(athlete.givenName)
        }
        if let sportId = staged.sportId, let sport = viewModel.sports.first(where: { $0.sportId == sportId }) {
            parts.append(sport.displayName)
        }
        parts.append(staged.activityType.displayName)
        return parts.joined(separator: " · ")
    }

    // MARK: - IGNORED: compact, receding row — never shown as though classified

    @ViewBuilder
    private func ignoredRow(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.event.title?.isEmpty == false ? item.event.title! : "(no title)")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                Text(item.event.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
            Spacer()
            Text(CalendarPlanningStrings.ignoredBadge)
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            Button(CalendarPlanningStrings.reviewAgainButton) {
                viewModel.restore(item)
            }
            .font(VoxtrTypography.metadata)
            .accessibilityIdentifier("calendarImportReview.reviewAgainButton")
        }
        .accessibilityIdentifier("calendarImportReview.ignoredRow")
    }
}

/// Calendar Import Review runtime fix: ONE Needs Review row — event
/// summary, inline Athlete/Activity Type/Sport pickers, an optional
/// same-row notes/location disclosure, Ignore, and Ready. A dedicated
/// `View` (not a `@ViewBuilder` function on the parent) so its own
/// `DisclosureGroup` expansion state survives independently per row
/// without any shared/ambiguous tap target — the root cause of the
/// TestFlight Ready/Ignore misrouting was a `NavigationLink` sharing a
/// `List` row with these same `Button`s, which made `List` treat the
/// WHOLE row as the `NavigationLink`'s own tap target and could swallow
/// taps meant for the buttons. Removing that `NavigationLink` (never
/// touched here — replaced by `DisclosureGroup`, which owns only its
/// own header's tap target) removes the structural cause; no gesture or
/// timing workaround was applied.
private struct NeedsReviewRow: View {
    let item: CalendarPlanningCoordinationService.CalendarReviewItem
    @Bindable var viewModel: CalendarImportReviewViewModel
    let onIgnoreRequested: () -> Void
    @State private var isDetailsExpanded = false

    private var hasAdditionalMetadata: Bool {
        item.event.notes?.isEmpty == false || item.event.location?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            eventSummary

            Picker(CalendarPlanningStrings.chooseAthlete, selection: Binding(
                get: { viewModel.stagedClassification(for: item.externalEventKey).athleteId },
                set: { viewModel.setStagedAthlete($0, for: item.externalEventKey) }
            )) {
                Text(CalendarPlanningStrings.chooseAthlete).tag(AthleteId?.none)
                ForEach(viewModel.athletes, id: \.athleteId) { athlete in
                    Text(athlete.givenName).tag(AthleteId?.some(athlete.athleteId))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("calendarImportReview.athletePicker")

            Picker(CalendarPlanningStrings.chooseActivityType, selection: Binding(
                get: { viewModel.stagedClassification(for: item.externalEventKey).activityType },
                set: { viewModel.setStagedActivityType($0, for: item.externalEventKey) }
            )) {
                ForEach(ActivityType.selectableCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("calendarImportReview.activityTypePicker")

            Picker(CalendarPlanningStrings.chooseSport, selection: Binding(
                get: { viewModel.stagedClassification(for: item.externalEventKey).sportId },
                set: { viewModel.setStagedSport($0, for: item.externalEventKey) }
            )) {
                Text("None").tag(SportId?.none)
                ForEach(viewModel.sports, id: \.sportId) { sport in
                    Text(sport.displayName).tag(SportId?.some(sport.sportId))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("calendarImportReview.sportPicker")

            // Same-row progressive disclosure — never a pushed screen or
            // sheet, and purely read-only: expanding/collapsing this
            // never mutates any business truth.
            if hasAdditionalMetadata {
                DisclosureGroup(CalendarPlanningStrings.detailsDisclosureLabel, isExpanded: $isDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let notes = item.event.notes, !notes.isEmpty {
                            Text(notes)
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                        }
                        if let location = item.event.location, !location.isEmpty {
                            Text(location)
                                .font(VoxtrTypography.metadata)
                                .foregroundStyle(VoxtrColor.textSecondary)
                        }
                    }
                    .padding(.top, 2)
                }
                .font(VoxtrTypography.metadata)
                .accessibilityIdentifier("calendarImportReview.detailsDisclosure")
            }

            HStack {
                Button(CalendarPlanningStrings.ignoreButton, role: .destructive) {
                    onIgnoreRequested()
                }
                .font(VoxtrTypography.metadata)
                .accessibilityIdentifier("calendarImportReview.ignoreButton")

                Spacer()

                // Lead Review follow-up: the ONE explicit action that
                // collapses this row into "Ready to Import" — selecting
                // Athlete/Sport/Activity Type above never does this on
                // its own. Disabled until Athlete is actually selected,
                // matching classifyAndImport's own canonical minimum.
                Button(CalendarPlanningStrings.markReadyButton) {
                    viewModel.markReady(for: item.externalEventKey)
                }
                .disabled(!viewModel.stagedClassification(for: item.externalEventKey).satisfiesMinimumImportRequirements)
                .accessibilityIdentifier("calendarImportReview.markReadyButton")
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("calendarImportReview.needsReviewRow")
    }

    @ViewBuilder
    private var eventSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.event.title?.isEmpty == false ? item.event.title! : "(no title)")
                .font(VoxtrTypography.cardTitle)
                .foregroundStyle(VoxtrColor.textPrimary)
            Text(item.event.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
        }
    }
}
