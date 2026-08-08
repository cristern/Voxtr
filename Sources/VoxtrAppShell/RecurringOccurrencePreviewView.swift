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
public struct RecurringOccurrencePreviewView: View {
    let suggestion: RecurringActivitySuggestion
    let athleteDisplayName: String
    let planningService: PlanningService
    let actorId: ActorId

    @State private var isPresentingEditForm = false
    @State private var recurringActivity: RecurringPlannedActivity?
    @State private var recurringManagementViewModel: WeeklyPlanningViewModel?
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
        .sheet(isPresented: $isPresentingEditForm) {
            if let recurringManagementViewModel, let recurringActivity {
                RecurringActivityFormView(
                    viewModel: recurringManagementViewModel,
                    editingRecurringActivity: recurringActivity
                )
            }
        }
    }

    /// Fetches the real `RecurringPlannedActivity` definition (the
    /// suggestion is only a lightweight, derived projection of it) and
    /// presents the existing edit form for it — the one, already-
    /// established way to change a recurring definition, not a new one
    /// built for this screen.
    private func openEditForm() {
        errorMessage = nil
        do {
            guard let fetched = try planningService.fetchRecurringPlannedActivity(byId: suggestion.recurringPlannedActivityId) else {
                errorMessage = "Could not find this recurring activity's definition."
                return
            }
            recurringActivity = fetched
            recurringManagementViewModel = WeeklyPlanningViewModel(
                service: planningService,
                athleteId: suggestion.athleteId,
                committedByActorId: actorId
            )
            isPresentingEditForm = true
        } catch {
            errorMessage = "Could not load this recurring activity's definition."
        }
    }
}
