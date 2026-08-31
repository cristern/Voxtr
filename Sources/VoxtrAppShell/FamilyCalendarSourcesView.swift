import SwiftUI
import UIKit
import VoxtrCalendarPlanningDomain

/// Family-Owned Calendar Sources V1: the family-level Calendar
/// configuration screen, reached from Profile / Manage Athletes (see
/// `AthleteFamilyManagementView`'s own doc comment for exactly where).
/// Replaces the old per-athlete `AthleteCalendarPlanningView` — a
/// calendar is connected ONCE for the whole family here, never
/// separately per athlete (see `ExternalPlanningSource`'s own doc
/// comment for why). Shows every connected source, lets the Parent
/// connect a new one, and links into each source's own detail screen
/// for enable/disable, sync, review, recovery, and diagnostics.
public struct FamilyCalendarSourcesView: View {
    @Bindable var viewModel: FamilyCalendarSourcesViewModel

    public init(viewModel: FamilyCalendarSourcesViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("familyCalendarSources.errorMessage")
                }
            }

            if !viewModel.sources.isEmpty {
                Section {
                    ForEach(viewModel.sources, id: \.externalPlanningSourceId) { source in
                        NavigationLink {
                            CalendarSourceDetailView(viewModel: viewModel, source: source)
                        } label: {
                            sourceRow(source)
                        }
                        .accessibilityIdentifier("familyCalendarSources.sourceRow.\(source.externalPlanningSourceId.rawValue.uuidString)")
                    }
                } header: {
                    VoxtrSectionHeading("Connected calendars")
                }
            }

            switch viewModel.authorizationStatus {
            case .notDetermined:
                connectSection
            case .denied:
                deniedSection
            case .authorized:
                setupSection
            }
        }
        .navigationTitle(CalendarPlanningStrings.screenTitle)
        .onAppear { viewModel.load() }
    }

    @ViewBuilder
    private func sourceRow(_ source: ExternalPlanningSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.displayName)
                .font(VoxtrTypography.cardTitle)
                .foregroundStyle(VoxtrColor.textPrimary)
            let reviewCount = viewModel.reviewCounts[source.externalPlanningSourceId] ?? 0
            Text(source.isEnabled ? (reviewCount > 0 ? "\(reviewCount) new event(s) to review" : "Up to date") : "Not bringing in events")
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
        }
    }

    @ViewBuilder
    private var connectSection: some View {
        Section {
            Text(CalendarPlanningStrings.connectCalendarExplanation)
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            Button(CalendarPlanningStrings.connectCalendarButton) {
                viewModel.connectCalendar()
            }
            .accessibilityIdentifier("familyCalendarSources.connectButton")
        }
    }

    @ViewBuilder
    private var deniedSection: some View {
        Section {
            Text(CalendarPlanningStrings.authorizationDenied)
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            Button(CalendarPlanningStrings.openSettings) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .accessibilityIdentifier("familyCalendarSources.openSettingsButton")
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        Section {
            if viewModel.availableCalendars.isEmpty {
                Text(CalendarPlanningStrings.noCalendarsFound)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            } else {
                Picker(CalendarPlanningStrings.chooseCalendar, selection: $viewModel.selectedCalendarId) {
                    Text(CalendarPlanningStrings.chooseCalendar).tag(String?.none)
                    ForEach(viewModel.availableCalendars) { calendar in
                        Text("\(calendar.title) (\(calendar.sourceTitle))").tag(String?.some(calendar.id))
                    }
                }
                .accessibilityIdentifier("familyCalendarSources.calendarPicker")

                Button(viewModel.sources.isEmpty ? CalendarPlanningStrings.saveSource : CalendarPlanningStrings.connectAnotherCalendarButton) {
                    viewModel.saveSource()
                }
                .disabled(viewModel.selectedCalendarId == nil)
                .accessibilityIdentifier("familyCalendarSources.saveButton")
            }
        } header: {
            VoxtrSectionHeading(viewModel.sources.isEmpty ? "Choose a calendar" : "Connect another calendar")
        }
    }
}
