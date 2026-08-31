import SwiftUI
import VoxtrCalendarPlanningDomain

/// Calendar V1 metadata inspection round: an Alpha-only, clearly
/// diagnostic list of a small, bounded number of real upcoming events
/// from the connected calendar — never presented as the final import-
/// review UX (see `CalendarSourceDetailView`'s own doc comment on the
/// row that pushes this screen). Shows exactly what
/// `CalendarPlanningCoordinationService.fetchDiagnosticEvents(inCalendar:)`
/// returns: title, date/time, notes, location, URL — plain display text
/// a Product Owner can read to judge whether a real external source
/// (e.g. Spond) provides a repeatable per-group signal, never used for
/// identity or classification anywhere in this codebase. Deliberately
/// omits `eventIdentifier`/`occurrenceDate`/raw internal identifiers from
/// this normal presentation — they did not materially help this
/// investigation, so this stays the simplest useful surface rather than
/// also building a separate debug view no one asked for.
///
/// Nothing shown here is persisted: `viewModel.diagnosticEvents` is
/// fetched fresh every time this screen appears and discarded, like any
/// other in-memory view state, the moment it is dismissed.
struct CalendarDiagnosticEventsView: View {
    @Bindable var viewModel: FamilyCalendarSourcesViewModel
    let source: ExternalPlanningSource

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
        .onAppear { viewModel.loadDiagnosticEvents(for: source) }
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
