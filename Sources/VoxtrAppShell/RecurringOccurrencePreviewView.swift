import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

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
    let trainingService: TrainingService
    let actorId: ActorId

    @State private var editSheetItem: RecurringEditSheetItem?
    @State private var materializedActivity: MaterializedActivityItem?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    public init(
        suggestion: RecurringActivitySuggestion,
        athleteDisplayName: String,
        planningService: PlanningService,
        trainingService: TrainingService,
        actorId: ActorId
    ) {
        self.suggestion = suggestion
        self.athleteDisplayName = athleteDisplayName
        self.planningService = planningService
        self.trainingService = trainingService
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
                Text("This occurrence comes from a recurring activity and hasn't been added to a specific week's plan yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Log Activity") {
                    materializeAndOpen()
                }
                .accessibilityIdentifier("recurringOccurrence.logActivityButton")
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
        .navigationDestination(item: $materializedActivity) { item in
            ActivityDetailViewLoader(
                plannedActivity: item.plannedActivity,
                isCompleted: false,
                athleteId: suggestion.athleteId,
                athleteDisplayName: athleteDisplayName,
                actorId: actorId,
                planningService: planningService,
                trainingService: trainingService
            )
        }
        .onAppear {
            checkForStaleness()
        }
    }

    /// Fixes the stale-preview bug reported after a successful
    /// recurring-occurrence log: `ActivityDetailView` already dismisses
    /// itself on successful save (its own `.onChange(of: isCompleted)`,
    /// unchanged), popping back exactly one level — to whichever screen
    /// pushed it, which for this flow is always THIS view. Without this
    /// check, this screen would then redraw with its hardcoded, static
    /// "not yet added to this week's plan" content — genuinely
    /// contradictory now that the occurrence is logged, even though
    /// persistence itself was always correct.
    ///
    /// Deliberately checks for a genuinely LOGGED activity, not merely
    /// a materialized one: materialization itself happens at the "Log
    /// Activity" button tap on THIS screen, before `ActivityDetailView`
    /// is ever shown — so a materialized-but-not-yet-logged
    /// `PlannedActivity` already exists the moment Activity Detail
    /// appears, regardless of whether the user goes on to log it or
    /// cancels/goes back. Checking only "is it materialized" would
    /// wrongly dismiss this screen even on cancel, violating this
    /// package's own explicit "cancel/back without logging retains
    /// normal navigation" requirement.
    ///
    /// `.onAppear` fires both on first display AND when this view
    /// becomes visible again after a pushed child dismisses — which is
    /// exactly the moment to check. A fresh, first-time appearance of
    /// this screen can never find a match here: `deriveSuggestions`
    /// already excludes any occurrence that's been materialized from
    /// ever being presented as a `.recurringOccurrence` in the first
    /// place, so this screen is only ever reached for a genuinely
    /// unmaterialized occurrence on first display.
    ///
    /// Not a second source of truth: reuses the exact same
    /// `fetchMaterializedPlannedActivity`/`fetchLoggedActivities(forPlannedActivity:)`
    /// relationship lookups the rest of the app already resolves
    /// completion through — never infers from title/date, never
    /// fabricates anything, never creates a WeekPlan merely by
    /// checking. When it finds a genuinely logged match, this screen
    /// dismisses itself — propagating the same "unwind" principle one
    /// level further up the stack, back to whatever surface (Athlete
    /// Home, Family Home, Family Schedule) originally pushed this
    /// screen, without ever hardcoding which one that was.
    private func checkForStaleness() {
        guard let materialized = try? planningService.fetchMaterializedPlannedActivity(for: suggestion) else {
            return
        }
        guard let loggedActivities = try? trainingService.fetchLoggedActivities(forPlannedActivity: materialized.plannedActivityId),
              !loggedActivities.isEmpty else {
            return
        }
        dismiss()
    }

    /// Sprint 1.2B, Priority 1: "Log Activity" is the one action that
    /// touches persistence on this otherwise read-only screen —
    /// viewing never materializes anything (see this type's own doc
    /// comment above); only this explicit action does, and it does so
    /// idempotently via `PlanningService.materializeOrFetchExisting`
    /// (reused, not reimplemented). Repeated taps — even after the
    /// occurrence was already materialized by a prior tap, or by a
    /// different screen entirely — resolve to the SAME `PlannedActivity`,
    /// never a duplicate. `.navigationDestination(item:)` (a single
    /// piece of optional state) drives presentation, not a separate
    /// Bool alongside it — the same fix already applied to this
    /// screen's own edit-sheet presentation above.
    private func materializeAndOpen() {
        errorMessage = nil
        do {
            let weekStart = TrainingPlanningCoordinationService.weekStart(containing: suggestion.occurrenceDate)
            let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: suggestion.athleteId, weekStart: weekStart)
            let materialized = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
            materializedActivity = MaterializedActivityItem(plannedActivity: materialized)
        } catch {
            errorMessage = "Could not open this activity. Please try again."
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

/// Sprint 1.2B, Priority 1: wraps the real, materialized
/// `PlannedActivity` for `.navigationDestination(item:)` presentation —
/// one piece of state driving both presence and content, matching this
/// file's own established fix for the exact same class of race.
private struct MaterializedActivityItem: Identifiable, Hashable {
    let id: String
    let plannedActivity: PlannedActivity

    init(plannedActivity: PlannedActivity) {
        self.id = plannedActivity.plannedActivityId.rawValue.uuidString
        self.plannedActivity = plannedActivity
    }
}
