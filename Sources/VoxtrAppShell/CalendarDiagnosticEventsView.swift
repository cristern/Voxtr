import SwiftUI
import VoxtrCalendarPlanningDomain

/// Calendar V1 metadata inspection round: an Alpha-only, clearly
/// diagnostic list of a small, bounded number of real upcoming events
/// from the connected calendar — never presented as the final import-
/// review UX (see `AthleteCalendarPlanningView`'s own doc comment on the
/// row that pushes this screen). Shows exactly what
/// `CalendarPlanningCoordinationService.fetchDiagnosticEvents(inCalendar:)`
/// returns: title, date/time, notes, location, URL, and — structured-
/// location diagnostic round — the plain `location` string shown
/// separately from `EKEvent.structuredLocation`'s own title and a
/// presence-only "Coordinates available" indicator, so a Product Owner
/// can tell which of the two EventKit exposes for a real event, never
/// used for identity or classification anywhere in this codebase. Deliberately
/// omits `eventIdentifier`/`occurrenceDate`/raw internal identifiers from
/// this normal presentation — they did not materially help this
/// investigation, so this stays the simplest useful surface rather than
/// also building a separate debug view no one asked for.
///
/// Nothing shown here is persisted: `viewModel.diagnosticEvents` is
/// fetched fresh every time this screen appears and discarded, like any
/// other in-memory view state, the moment it is dismissed.
struct CalendarDiagnosticEventsView: View {
    @Bindable var viewModel: AthleteCalendarPlanningViewModel

    var body: some View {
        List {
            if viewModel.diagnosticEvents.isEmpty {
                Text(CalendarPlanningStrings.inspectEventsEmpty)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            } else {
                ForEach(Array(viewModel.diagnosticEvents.enumerated()), id: \.offset) { _, event in
                    eventRow(event)
                }
            }
        }
        .navigationTitle("Calendar Events (Alpha)")
        .onAppear { viewModel.loadDiagnosticEvents() }
    }

    @ViewBuilder
    private func eventRow(_ event: ExternalCalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title?.isEmpty == false ? event.title! : "(no title)")
                .font(VoxtrTypography.cardTitle)
                .foregroundStyle(VoxtrColor.textPrimary)
            Text(event.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            if let notes = event.notes, !notes.isEmpty {
                Text("Notes: \(notes)")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
            if let location = event.location, !location.isEmpty {
                Text("Location: \(location)")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
            // Structured-location diagnostic round: shown separately from
            // `Location` above — never merged/synthesized — so a Product
            // Owner can tell exactly which of `EKEvent.location` and
            // `EKEvent.structuredLocation` a real event actually
            // populates. Coordinates themselves are never displayed, only
            // whether EventKit reports them existing.
            if let structuredLocationTitle = event.structuredLocationTitle, !structuredLocationTitle.isEmpty {
                Text("Structured location: \(structuredLocationTitle)")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
            Text("Coordinates available: \(event.hasStructuredLocationCoordinates ? "Yes" : "No")")
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            if let url = event.url {
                Text("URL: \(url.absoluteString)")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("athleteCalendarPlanning.diagnosticEventRow")
    }
}
