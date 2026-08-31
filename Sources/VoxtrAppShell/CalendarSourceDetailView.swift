import SwiftUI
import VoxtrCalendarPlanningDomain

/// Family-Owned Calendar Sources V1: the per-source detail screen —
/// enable/disable, sync, Calendar Import Review, Alpha diagnostics, and
/// recovery/disconnect, all for ONE `ExternalPlanningSource`. Reached
/// from `FamilyCalendarSourcesView`'s own list row.
struct CalendarSourceDetailView: View {
    @Bindable var viewModel: FamilyCalendarSourcesViewModel
    let source: ExternalPlanningSource
    /// Calendar V1 recovery round precedent (PR #40): confirmation state
    /// for the destructive "Remove imported activities" action — owned
    /// by the View (presentation), never the ViewModel.
    @State private var isShowingRemoveConfirmation = false

    var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("calendarSourceDetail.errorMessage")
                }
            }

            Section {
                LabeledContent("Calendar", value: source.displayName)
                Toggle(CalendarPlanningStrings.enabledLabel, isOn: Binding(
                    get: { source.isEnabled },
                    set: { viewModel.setEnabled(source, isEnabled: $0) }
                ))
                .accessibilityIdentifier("calendarSourceDetail.enabledToggle")
            } header: {
                VoxtrSectionHeading("Connected calendar")
            }

            Section {
                NavigationLink {
                    CalendarImportReviewView(viewModel: viewModel.makeImportReviewViewModel(for: source))
                } label: {
                    Text(CalendarPlanningStrings.reviewEventsButtonWithCount(viewModel.reviewCounts[source.externalPlanningSourceId] ?? 0))
                }
                .accessibilityIdentifier("calendarSourceDetail.reviewLink")
            } footer: {
                Text(CalendarPlanningStrings.reviewExplanation)
            }

            // Calendar V1 metadata inspection round precedent: Alpha-
            // only, clearly diagnostic — never presented as the final
            // import-review UX. Kept in its own section.
            Section {
                NavigationLink {
                    CalendarDiagnosticEventsView(viewModel: viewModel, source: source)
                } label: {
                    Text(CalendarPlanningStrings.inspectEventsButton)
                }
                .accessibilityIdentifier("calendarSourceDetail.inspectEventsLink")
            } footer: {
                Text(CalendarPlanningStrings.inspectEventsExplanation)
            }

            if source.isEnabled {
                Section {
                    if let lastReconciledAt = source.lastReconciledAt {
                        Text("Last synced \(lastReconciledAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                            .accessibilityIdentifier("calendarSourceDetail.lastSyncedMessage")
                    }
                    if let outcome = viewModel.lastSyncOutcome[source.externalPlanningSourceId] {
                        Text(CalendarPlanningStrings.lastSynced((outcome.updated, outcome.cancelled, outcome.skipped)))
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                            .accessibilityIdentifier("calendarSourceDetail.lastSyncOutcomeMessage")
                    }
                    Button(CalendarPlanningStrings.syncNow) {
                        viewModel.syncNow(source)
                    }
                    .accessibilityIdentifier("calendarSourceDetail.syncNowButton")
                }
            }

            // Calendar V1 recovery round precedent (PR #40): deliberately
            // its OWN section, separate from "Disconnect calendar" below
            // — removing already-imported activities and disconnecting
            // the source are different actions with different
            // consequences; neither implies the other.
            Section {
                if let outcome = viewModel.lastCleanupOutcome[source.externalPlanningSourceId] {
                    Text(CalendarPlanningStrings.removeImportedActivitiesResult(
                        (outcome.removed, outcome.preservedLogged, outcome.historicalWeeksSkipped, outcome.failed, outcome.lifecycleRestoreFailed)
                    ))
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("calendarSourceDetail.cleanupResultMessage")
                }
                Button(CalendarPlanningStrings.removeImportedActivitiesButton, role: .destructive) {
                    isShowingRemoveConfirmation = true
                }
                .accessibilityIdentifier("calendarSourceDetail.removeImportedActivitiesButton")
            }

            Section {
                Button(CalendarPlanningStrings.disconnect, role: .destructive) {
                    viewModel.disconnect(source)
                }
                .accessibilityIdentifier("calendarSourceDetail.disconnectButton")
            }
        }
        .navigationTitle(source.displayName)
        .confirmationDialog(
            CalendarPlanningStrings.removeImportedActivitiesConfirmationTitle,
            isPresented: $isShowingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(CalendarPlanningStrings.removeImportedActivitiesButton, role: .destructive) {
                viewModel.removeImportedActivities(for: source)
            }
            .accessibilityIdentifier("calendarSourceDetail.confirmRemoveImportedActivitiesButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CalendarPlanningStrings.removeImportedActivitiesConfirmationMessage(sourceDisplayName: source.displayName))
        }
    }
}
