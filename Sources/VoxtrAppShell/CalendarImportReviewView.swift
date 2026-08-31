import SwiftUI
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAthleteDomain
import VoxtrCalendarPlanningDomain

/// Calendar Import Review V1.1 (Inline Review + Ready Staging + Bulk
/// Import + Remembered Exact Choices): the actual working surface for
/// classifying many upcoming events efficiently, for ONE source. Two
/// conceptual sections — NEEDS REVIEW (classify Athlete/Sport/Activity
/// Type directly on this screen) and READY TO IMPORT (a compact summary
/// row for every fully staged event) — plus one explicit bulk-import
/// action. Classifying, editing, and ignoring all happen right here;
/// `CalendarImportReviewDetailView` below is retained ONLY as an
/// optional metadata inspection surface (notes/location), never required
/// for normal classification.
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

            if viewModel.reviewQueue.isEmpty {
                Text(CalendarPlanningStrings.reviewEmpty)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            } else {
                if !viewModel.needsReviewItems.isEmpty {
                    Section {
                        ForEach(viewModel.needsReviewItems, id: \.externalEventKey) { item in
                            needsReviewRow(item)
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

    // MARK: - NEEDS REVIEW: classify Athlete/Sport/Activity Type directly on this screen

    @ViewBuilder
    private func needsReviewRow(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            eventSummary(item)

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

            HStack {
                // Optional metadata-only disclosure — never required for
                // classification, which already happens above via the
                // three pickers.
                NavigationLink("Details") {
                    CalendarImportReviewDetailView(item: item)
                }
                .font(VoxtrTypography.metadata)
                .accessibilityIdentifier("calendarImportReview.detailLink")

                Spacer()

                Button(CalendarPlanningStrings.ignoreButton, role: .destructive) {
                    itemPendingIgnore = item
                }
                .font(VoxtrTypography.metadata)
                .accessibilityIdentifier("calendarImportReview.ignoreButton")

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

    @ViewBuilder
    private func eventSummary(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) -> some View {
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

/// Calendar Import Review V1.1: an OPTIONAL metadata inspection surface
/// only — notes/location for one event, never required for normal
/// classification (that now happens inline on `CalendarImportReviewView`
/// itself). Read-only; no Import/Ignore action lives here.
struct CalendarImportReviewDetailView: View {
    let item: CalendarPlanningCoordinationService.CalendarReviewItem

    var body: some View {
        Form {
            Section {
                Text(item.event.title?.isEmpty == false ? item.event.title! : "(no title)")
                    .font(VoxtrTypography.cardTitle)
                    .foregroundStyle(VoxtrColor.textPrimary)
                Text(item.event.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
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
        }
        .navigationTitle(CalendarPlanningStrings.reviewDetailTitle)
    }
}
