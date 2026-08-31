import SwiftUI
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAthleteDomain
import VoxtrCalendarPlanningDomain

/// Family-Owned Calendar Sources V1 — Calendar Import Review: the list
/// of external events awaiting an explicit Parent decision for ONE
/// source. Tapping a row opens `CalendarImportReviewDetailView`, the
/// ONE place classification (Athlete/Sport/Activity Type) plus
/// Import/Ignore happen — this list itself never mutates anything.
struct CalendarImportReviewView: View {
    @Bindable var viewModel: CalendarImportReviewViewModel

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
                Section {
                    ForEach(viewModel.reviewQueue, id: \.externalEventKey) { item in
                        NavigationLink {
                            CalendarImportReviewDetailView(viewModel: viewModel, item: item)
                        } label: {
                            reviewRow(item)
                        }
                        .accessibilityIdentifier("calendarImportReview.reviewRow")
                    }
                } footer: {
                    Text(CalendarPlanningStrings.reviewExplanation)
                }
            }
        }
        .navigationTitle(CalendarPlanningStrings.reviewScreenTitle)
        .onAppear { viewModel.load() }
    }

    @ViewBuilder
    private func reviewRow(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.event.title?.isEmpty == false ? item.event.title! : "(no title)")
                .font(VoxtrTypography.cardTitle)
                .foregroundStyle(VoxtrColor.textPrimary)
            Text(item.event.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            if let location = item.event.location, !location.isEmpty {
                Text(location)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The actual classification form for ONE reviewed event — Athlete,
/// Sport, Activity Type, then Import or Ignore. A genuinely multi-field
/// decision, so this is a pushed screen, not an inline row (Simple
/// Settings Rule, same rationale every other multi-field screen in this
/// app already follows).
struct CalendarImportReviewDetailView: View {
    @Bindable var viewModel: CalendarImportReviewViewModel
    let item: CalendarPlanningCoordinationService.CalendarReviewItem
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAthleteId: AthleteId?
    @State private var selectedActivityType: ActivityType = .individualTraining
    @State private var selectedSportId: SportId?
    @State private var isShowingIgnoreConfirmation = false

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

            Section {
                Picker(CalendarPlanningStrings.chooseAthlete, selection: $selectedAthleteId) {
                    Text(CalendarPlanningStrings.chooseAthlete).tag(AthleteId?.none)
                    ForEach(viewModel.athletes, id: \.athleteId) { athlete in
                        Text(athlete.givenName).tag(AthleteId?.some(athlete.athleteId))
                    }
                }
                .accessibilityIdentifier("calendarImportReviewDetail.athletePicker")

                Picker(CalendarPlanningStrings.chooseActivityType, selection: $selectedActivityType) {
                    ForEach(ActivityType.selectableCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .accessibilityIdentifier("calendarImportReviewDetail.activityTypePicker")

                Picker(CalendarPlanningStrings.chooseSport, selection: $selectedSportId) {
                    Text("None").tag(SportId?.none)
                    ForEach(viewModel.sports, id: \.sportId) { sport in
                        Text(sport.displayName).tag(SportId?.some(sport.sportId))
                    }
                }
                .accessibilityIdentifier("calendarImportReviewDetail.sportPicker")
            } header: {
                VoxtrSectionHeading("This event belongs to")
            }

            Section {
                Button(CalendarPlanningStrings.importButton) {
                    guard let selectedAthleteId else { return }
                    viewModel.classifyAndImport(
                        item, athleteId: selectedAthleteId, sportId: selectedSportId, activityType: selectedActivityType
                    )
                    dismiss()
                }
                .disabled(selectedAthleteId == nil)
                .accessibilityIdentifier("calendarImportReviewDetail.importButton")

                Button(CalendarPlanningStrings.ignoreButton, role: .destructive) {
                    isShowingIgnoreConfirmation = true
                }
                .accessibilityIdentifier("calendarImportReviewDetail.ignoreButton")
            }
        }
        .navigationTitle(CalendarPlanningStrings.reviewDetailTitle)
        .confirmationDialog(
            CalendarPlanningStrings.ignoreConfirmationTitle,
            isPresented: $isShowingIgnoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(CalendarPlanningStrings.ignoreButton, role: .destructive) {
                viewModel.ignore(item)
                dismiss()
            }
            .accessibilityIdentifier("calendarImportReviewDetail.confirmIgnoreButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CalendarPlanningStrings.ignoreConfirmationMessage)
        }
    }
}
