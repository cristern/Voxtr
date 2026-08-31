import SwiftUI
import UIKit
import VoxtrCoreContracts
import VoxtrCalendarPlanningDomain

/// Calendar Planning Source V1: the athlete-scoped Calendar
/// configuration screen, reached from Athlete Settings' own "Calendar"
/// row (Simple Settings Rule: this genuinely needs more than one
/// value, so it is a pushed screen, not an inline row). Shows exactly
/// what the approved UX asks for: which calendar is connected, which
/// athlete it feeds (this screen's own athlete — never re-selectable
/// here), what Sport/Activity Type imported events use, whether the
/// mapping is enabled, permission/error state, and how to disconnect.
public struct AthleteCalendarPlanningView: View {
    @Bindable var viewModel: AthleteCalendarPlanningViewModel
    let athleteDisplayName: String
    /// Calendar V1 recovery round: confirmation state for the
    /// destructive "Remove imported activities" action — owned by the
    /// View (presentation), never the ViewModel, matching this
    /// codebase's own SwiftUI convention (e.g. `AthleteSettingsView`'s
    /// own Archive confirmation).
    @State private var isShowingRemoveConfirmation = false

    public init(viewModel: AthleteCalendarPlanningViewModel, athleteDisplayName: String) {
        self.viewModel = viewModel
        self.athleteDisplayName = athleteDisplayName
    }

    public var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("athleteCalendarPlanning.errorMessage")
                }
            }

            switch viewModel.authorizationStatus {
            case .notDetermined:
                connectSection
            case .denied:
                deniedSection
            case .authorized:
                if let mapping = viewModel.mapping {
                    mappingSection(mapping)
                } else {
                    setupSection
                }
            }
        }
        .navigationTitle("Calendar")
        .onAppear { viewModel.load() }
        .confirmationDialog(
            CalendarPlanningStrings.removeImportedActivitiesConfirmationTitle,
            isPresented: $isShowingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(CalendarPlanningStrings.removeImportedActivitiesButton, role: .destructive) {
                viewModel.removeImportedActivities()
            }
            .accessibilityIdentifier("athleteCalendarPlanning.confirmRemoveImportedActivitiesButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CalendarPlanningStrings.removeImportedActivitiesConfirmationMessage(athleteDisplayName: athleteDisplayName))
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
            .accessibilityIdentifier("athleteCalendarPlanning.connectButton")
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
            .accessibilityIdentifier("athleteCalendarPlanning.openSettingsButton")
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
                .accessibilityIdentifier("athleteCalendarPlanning.calendarPicker")
            }
        } header: {
            VoxtrSectionHeading("Choose a calendar")
        }

        Section {
            Picker("Activity type", selection: $viewModel.selectedActivityType) {
                ForEach(ActivityType.selectableCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .accessibilityIdentifier("athleteCalendarPlanning.activityTypePicker")

            Picker("Sport", selection: $viewModel.selectedSportId) {
                Text("None").tag(SportId?.none)
                ForEach(viewModel.sports, id: \.sportId) { sport in
                    Text(sport.displayName).tag(SportId?.some(sport.sportId))
                }
            }
            .accessibilityIdentifier("athleteCalendarPlanning.sportPicker")
        } header: {
            VoxtrSectionHeading("Imported events will use")
        }

        Section {
            Button(CalendarPlanningStrings.saveMapping) {
                viewModel.saveMapping()
            }
            .disabled(viewModel.selectedCalendarId == nil)
            .accessibilityIdentifier("athleteCalendarPlanning.saveButton")
        }
    }

    @ViewBuilder
    private func mappingSection(_ mapping: CalendarPlanningMapping) -> some View {
        Section {
            LabeledContent("Calendar", value: mapping.calendarTitle)
            LabeledContent("Activity type", value: mapping.activityType.displayName)
            if let sportId = mapping.sportId, let sport = viewModel.sports.first(where: { $0.id == sportId }) {
                LabeledContent("Sport", value: sport.displayName)
            }
            Toggle(CalendarPlanningStrings.enabledLabel, isOn: Binding(
                get: { mapping.isEnabled },
                set: { viewModel.setEnabled($0) }
            ))
            .accessibilityIdentifier("athleteCalendarPlanning.enabledToggle")
        } header: {
            VoxtrSectionHeading("Connected calendar")
        }

        // Calendar V1 metadata inspection round: Alpha-only, clearly
        // diagnostic — never presented as the final import-review UX.
        // Kept in its own section, separate from every configuration/
        // action row above and below, so it reads as "look, don't
        // touch."
        Section {
            NavigationLink {
                CalendarDiagnosticEventsView(viewModel: viewModel)
            } label: {
                Text(CalendarPlanningStrings.inspectEventsButton)
            }
            .accessibilityIdentifier("athleteCalendarPlanning.inspectEventsLink")
        } footer: {
            Text(CalendarPlanningStrings.inspectEventsExplanation)
        }

        if mapping.isEnabled {
            Section {
                if let outcome = viewModel.lastReconciliationOutcome {
                    Text(CalendarPlanningStrings.lastSynced((outcome.created, outcome.updated, outcome.cancelled)))
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                        .accessibilityIdentifier("athleteCalendarPlanning.lastSyncedMessage")
                }
                Button(CalendarPlanningStrings.syncNow) {
                    viewModel.reconcileNow()
                }
                .accessibilityIdentifier("athleteCalendarPlanning.syncNowButton")
            }
        }

        // Calendar V1 recovery round: deliberately its OWN section,
        // separate from "Disconnect calendar" below — removing already-
        // imported activities and disconnecting the calendar are
        // different actions with different consequences (see this
        // view's own doc comment and `CalendarPlanningCoordinationService.removeImportedActivities(for:removedBy:)`'s
        // own doc comment); neither one implies the other, and a Parent
        // may want either independently.
        Section {
            if let outcome = viewModel.lastCleanupOutcome {
                Text(CalendarPlanningStrings.removeImportedActivitiesResult(
                    (outcome.removed, outcome.preservedLogged, outcome.historicalWeeksSkipped, outcome.failed)
                ))
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
                .accessibilityIdentifier("athleteCalendarPlanning.cleanupResultMessage")
            }
            Button(CalendarPlanningStrings.removeImportedActivitiesButton, role: .destructive) {
                isShowingRemoveConfirmation = true
            }
            .accessibilityIdentifier("athleteCalendarPlanning.removeImportedActivitiesButton")
        }

        Section {
            Button(CalendarPlanningStrings.disconnect, role: .destructive) {
                viewModel.disconnect()
            }
            .accessibilityIdentifier("athleteCalendarPlanning.disconnectButton")
        }
    }
}
