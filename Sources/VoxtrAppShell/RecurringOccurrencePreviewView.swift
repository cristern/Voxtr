import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain

/// Sprint 1.1 closeout, Item 2. Family Schedule shows unmaterialized
/// recurring occurrences (`RecurringActivitySuggestion` — a derived
/// projection with no `PlannedActivityId`, see `FamilyScheduleRow`'s
/// own doc comment) alongside real, materialized `PlannedActivity`
/// rows. Routing an unmaterialized occurrence into the canonical
/// `ActivityDetailView` would require fabricating a `PlannedActivityId`
/// it doesn't have — explicitly disallowed. This is the correct,
/// distinct destination for that case: a read-only preview of the
/// occurrence (athlete, date, time, title — everything the suggestion
/// actually represents), with a path to the ALREADY-EXISTING recurring
/// definition editor (`RecurringActivityFormView`, reused verbatim, not
/// duplicated) for anyone who wants to change the underlying recurring
/// activity. Viewing this screen never materializes anything — no
/// `PlannedActivity` is created just by looking; only actually editing
/// the recurring definition (an already-established, pre-existing
/// mutation path) touches persistence.
///
/// Sprint 1.1.1, Item 2 (white-screen fix): this view previously drove
/// its "Edit Recurring Definition" sheet from THREE separate `@State`
/// variables (`isPresentingEditForm: Bool`,
/// `recurringActivity: RecurringPlannedActivity?`,
/// `recurringManagementViewModel: WeeklyPlanningViewModel?`) — the
/// exact same race already diagnosed and fixed for `DailyTrainingView`
/// "Manage Recurring Activities": `.sheet(isPresented:)`'s content
/// closure can be evaluated before the separately-set optional state
/// has "caught up," and the `if let` (no `else`) falls through to an
/// implicit, blank `EmptyView()`. First tap: blank. Return and tap
/// again: the (never-reset) values are already populated from the
/// first attempt, so the same race no longer matters — exactly the
/// reported symptom. This view introduced the same bug independently,
/// in the same turn the first instance was fixed elsewhere, by not yet
/// applying the same lesson to new code. Fixed the same way:
/// `.sheet(item:)` — presence and content are now one piece of state.
public struct RecurringOccurrencePreviewView: View {
    let suggestion: RecurringActivitySuggestion
    let athleteDisplayName: String
    let planningService: PlanningService
    let actorId: ActorId

    @State private var editSheetItem: RecurringEditSheetItem?
    @State private var errorMessage: String?

    public init(
        suggestion: RecurringActivitySuggestion,
        athleteDisplayName: String,
        planningService: PlanningService,
        actorId: ActorId
    ) {
        self.suggestion = suggestion
        self.athleteDisplayName = athleteDisplayName
        self.planningService = planningService
        self.actorId = actorId
    }

    public var body: some View {
        Form {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("recurringOccurrence.errorMessage")
                }
            }

            Section {
                LabeledContent("Athlete", value: athleteDisplayName)
                LabeledContent("Activity", value: suggestion.title)
                LabeledContent("Date", value: suggestion.occurrenceDate.isoString)
                if let startTime = suggestion.startLocalTime {
                    LabeledContent("Time", value: String(format: "%02d:%02d", startTime.hour, startTime.minute))
                }
                if let location = suggestion.location, !location.isEmpty {
                    LabeledContent("Location", value: location)
                }
                LabeledContent("Status", value: "Recurring — not yet added to this week's plan")
            }
            .accessibilityIdentifier("recurringOccurrence.summary")

            Section {
                Text("This occurrence comes from a recurring activity and hasn't been added to a specific week's plan yet — it isn't logged or edited directly here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Edit Recurring Definition") {
                    openEditForm()
                }
                .accessibilityIdentifier("recurringOccurrence.editRecurringButton")
            }
        }
        .navigationTitle("\(athleteDisplayName) · Recurring Activity")
        .sheet(item: $editSheetItem) { item in
            RecurringActivityFormView(
                viewModel: item.viewModel,
                editingRecurringActivity: item.recurringActivity,
                athleteDisplayName: athleteDisplayName
            )
        }
    }

    /// Fetches the real `RecurringPlannedActivity` definition (the
    /// suggestion is only a lightweight, derived projection of it) and
    /// presents the existing edit form for it — the one, already-
    /// established way to change a recurring definition, not a new one
    /// built for this screen. Both pieces of data the sheet needs are
    /// fully resolved BEFORE `editSheetItem` is ever set, so there is no
    /// window where the sheet is "presented" with nothing to show.
    private func openEditForm() {
        errorMessage = nil
        do {
            guard let fetched = try planningService.fetchRecurringPlannedActivity(byId: suggestion.recurringPlannedActivityId) else {
                errorMessage = "Could not find this recurring activity's definition."
                return
            }
            let viewModel = WeeklyPlanningViewModel(
                service: planningService,
                athleteId: suggestion.athleteId,
                committedByActorId: actorId
            )
            editSheetItem = RecurringEditSheetItem(viewModel: viewModel, recurringActivity: fetched)
        } catch {
            errorMessage = "Could not load this recurring activity's definition."
        }
    }
}

/// Sprint 1.1.1, Item 2: wraps the two pieces of data
/// `RecurringActivityFormView` needs for `.sheet(item:)` presentation —
/// see `RecurringOccurrencePreviewView`'s own doc comment for the full
/// root-cause explanation this fixes.
private struct RecurringEditSheetItem: Identifiable {
    let id = UUID()
    let viewModel: WeeklyPlanningViewModel
    let recurringActivity: RecurringPlannedActivity
}
