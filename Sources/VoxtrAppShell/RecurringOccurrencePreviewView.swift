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
    @Environment(\.modelContext) private var modelContext
    let suggestion: RecurringActivitySuggestion
    let athleteDisplayName: String
    let planningService: PlanningService
    let trainingService: TrainingService
    let trainingReflectionCoordinationService: TrainingReflectionCoordinationService
    let actorId: ActorId
    /// Post-mutation navigation and stale-state consistency audit: the
    /// same explicit reload signal `ActivityDetailViewLoader` now
    /// carries, threaded through here too — this screen also sits
    /// between a "Log Activity" mutation and the surface that pushed
    /// it (Family Home, Athlete Home, Daily Training, Family Schedule),
    /// and dismisses itself on successful log the same way. Defaulted
    /// to a no-op so existing call sites/tests are unaffected.
    let onActivityLogged: () -> Void

    @State private var editSheetItem: RecurringEditSheetItem?
    @State private var materializedActivity: MaterializedActivityItem?
    @State private var isPresentingCancelConfirmation = false
    @State private var errorMessage: String?
    /// TestFlight regression fix (Log Activity -> mounted Athlete Home
    /// still stale): `onLogged` below used to call this screen's own
    /// `dismiss()` directly, synchronously, from inside `LogActivityViewModel.save()`
    /// — BEFORE `save()` even returned to `LogActivityView`'s own Save
    /// button, i.e. BEFORE `LogActivityView`'s OWN `dismiss()` (its own
    /// `@Environment(\.dismiss)`, called immediately afterward once
    /// `save()` returns `true`) ever ran. That popped this screen (the
    /// sheet's OWN presenter) off the stack WHILE its sheet was still
    /// actively presented — backwards from the well-defined "dismiss the
    /// child sheet, THEN the parent" order — with no settled render pass
    /// in between for the `onActivityLogged()` mutation. See
    /// `ActivityDetailView.isDismissingAfterLog`'s own doc comment for
    /// the full diagnosis; this is the identical pattern in this
    /// screen's own `.sheet(item: $materializedActivity)`.
    @State private var isDismissingAfterLog = false
    @Environment(\.dismiss) private var dismiss

    public init(
        suggestion: RecurringActivitySuggestion,
        athleteDisplayName: String,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingReflectionCoordinationService: TrainingReflectionCoordinationService,
        actorId: ActorId,
        onActivityLogged: @escaping () -> Void = {}
    ) {
        self.suggestion = suggestion
        self.athleteDisplayName = athleteDisplayName
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingReflectionCoordinationService = trainingReflectionCoordinationService
        self.actorId = actorId
        self.onActivityLogged = onActivityLogged
    }

    public var body: some View {
        Form {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("recurringOccurrence.errorMessage")
                }
                .voxtrRowSurface()
            }

            Section {
                LabeledContent("Athlete", value: athleteDisplayName)
                LabeledContent("Activity", value: ActivityLabelResolver(modelContext: modelContext).primaryLabel(for: suggestion))
                LabeledContent("Date", value: suggestion.occurrenceDate.isoString)
                if let startTime = suggestion.startLocalTime {
                    LabeledContent("Time", value: String(format: "%02d:%02d", startTime.hour, startTime.minute))
                }
                if let location = suggestion.location, !location.isEmpty {
                    LabeledContent("Location", value: location)
                }
                LabeledContent("Status", value: "Recurring — not yet added to this week's plan")
            }
            .voxtrRowSurface()
            .accessibilityIdentifier("recurringOccurrence.summary")

            Section {
                Text("This occurrence comes from a recurring activity and hasn't been added to a specific week's plan yet.")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                Button("Log Activity") {
                    materializeAndOpen()
                }
                .accessibilityIdentifier("recurringOccurrence.logActivityButton")
                Button("Edit Recurring Definition") {
                    openEditForm()
                }
                .accessibilityIdentifier("recurringOccurrence.editRecurringButton")
                // Activity outcome consistency closeout (item A): a
                // single occurrence, cancelled — never the recurring
                // series itself ("Edit Recurring Definition" above
                // remains the only way to change the series). Only
                // offered before this occurrence has any outcome —
                // matches the normal planned-activity "Cancel Activity"
                // action's own `canCancel` gate (`!isCompleted`); a
                // materialized-but-unresolved occurrence stops being
                // presented as `.recurringOccurrence` at all (this
                // screen is only ever reached for one), so there is no
                // separate "already resolved" state to check here.
                Button("Cancel Activity", role: .destructive) {
                    isPresentingCancelConfirmation = true
                }
                .accessibilityIdentifier("recurringOccurrence.cancelActivityButton")
            }
            .voxtrRowSurface()
        }
        .voxtrScreenBackground()
        .tint(VoxtrColor.accent)
        .navigationTitle("\(athleteDisplayName) · Recurring Activity")
        .sheet(item: $editSheetItem) { item in
            RecurringActivityFormView(
                viewModel: item.viewModel,
                editingRecurringActivity: item.recurringActivity,
                athleteDisplayName: athleteDisplayName
            )
        }
        .sheet(item: $materializedActivity, onDismiss: {
            // Fires only once LogActivityView's OWN dismiss (its Save
            // button, or Cancel/swipe-to-dismiss) has fully finished —
            // see `isDismissingAfterLog`'s own doc comment above.
            if isDismissingAfterLog {
                isDismissingAfterLog = false
                dismiss()
            }
        }) { item in
            LogActivityView(
                viewModel: LogActivityViewModel(
                    plannedActivity: item.plannedActivity,
                    athleteId: suggestion.athleteId,
                    athleteDisplayName: athleteDisplayName,
                    authorId: actorId,
                    trainingReflectionCoordinationService: trainingReflectionCoordinationService,
                    onLogged: {
                        onActivityLogged()
                        isDismissingAfterLog = true
                    }
                )
            )
        }
        .confirmationDialog(
            "Cancel this activity?",
            isPresented: $isPresentingCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Activity", role: .destructive) {
                cancelOccurrence()
            }
            Button("Keep", role: .cancel) {}
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

    /// Sprint 1.2B, Priority 1 (and later, double-hop fix): "Log
    /// Activity" is the one action that touches persistence on this
    /// otherwise read-only screen — viewing never materializes
    /// anything (see this type's own doc comment above); only this
    /// explicit action does, and it does so idempotently via
    /// `PlanningService.materializeOrFetchExisting` (reused, not
    /// reimplemented). Repeated taps — even after the occurrence was
    /// already materialized by a prior tap, or by a different screen
    /// entirely — resolve to the SAME `PlannedActivity`, never a
    /// duplicate.
    ///
    /// Presents `LogActivityView` DIRECTLY as a sheet (not
    /// `ActivityDetailViewLoader` via `.navigationDestination`, the
    /// prior implementation) — fixes the confirmed TestFlight double-hop
    /// bug, where `ActivityDetailView` had its own separate "Log
    /// Activity" button, forcing a second tap before the actual logging
    /// form ever appeared. Materialization itself still happens here,
    /// exactly as before — only the redundant Activity Detail hop after
    /// it is removed. `.sheet(item:)` (a single piece of optional
    /// state) drives presentation, not a separate Bool alongside it —
    /// the same fix already applied to this screen's own edit-sheet
    /// presentation above. `onLogged` dismisses THIS screen once
    /// logging actually succeeds — the same "unwind to the originating
    /// surface" principle `checkForStaleness()` already establishes,
    /// reused here directly rather than waiting for a stale re-check on
    /// next appearance. Cancelling the sheet (never calls `onLogged`)
    /// leaves this screen exactly as it was — no lifecycle change.
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

    /// Activity outcome consistency closeout (item A): cancels this ONE
    /// occurrence — "this occurrence will not take place," never the
    /// recurring series (the `RecurringPlannedActivity` definition
    /// itself is completely untouched; only "Edit Recurring Definition"
    /// above changes it). Reuses the EXACT SAME two canonical paths
    /// already established elsewhere, not a second recurring-cancellation
    /// model:
    /// - `PlanningService.materializeOrFetchExisting` — the same
    ///   idempotent materialization `materializeAndOpen()` above already
    ///   uses, so a real `PlannedActivity` with stable identity exists
    ///   exactly once, linked back to this occurrence by the same
    ///   `externalSourceId`/`externalSourceType` pair every other
    ///   materialization already establishes.
    /// - `TrainingReflectionCoordinationService.logActivity(status: .cancelled)`
    ///   — the exact same call `ActivityDetailViewModel.cancelActivity()`
    ///   makes for a normal planned activity, linked to the newly-
    ///   materialized `PlannedActivity` by its own stable typed ID.
    ///
    /// Duplicate protection falls out of both paths' own existing
    /// guarantees, not anything new: `materializeOrFetchExisting` always
    /// resolves to the SAME `PlannedActivity` on repeat calls (never a
    /// second one for the same occurrence), and `TrainingService.logActivity`
    /// already rejects a second `LoggedActivity` link to that same
    /// `PlannedActivity` via `plannedActivityAlreadyLinked` — so a
    /// repeated cancel attempt, or a cancel after this occurrence was
    /// already logged/cancelled by another screen, is rejected the same
    /// way a duplicate normal-activity cancel already is.
    ///
    /// Dismisses on success (unlike `ActivityDetailViewModel.cancelActivity()`,
    /// which stays open and updates in place): this screen's own content
    /// is static text ("hasn't been added to a specific week's plan
    /// yet"), which becomes false the moment this occurrence is
    /// materialized and resolved — there is no dynamic state here for it
    /// to update into, the same reason `materializeAndOpen()`'s own
    /// `onLogged` already dismisses on a successful log.
    private func cancelOccurrence() {
        errorMessage = nil
        do {
            let weekStart = TrainingPlanningCoordinationService.weekStart(containing: suggestion.occurrenceDate)
            let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: suggestion.athleteId, weekStart: weekStart)
            let materialized = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
            _ = try trainingReflectionCoordinationService.logActivity(
                athleteId: suggestion.athleteId,
                plannedActivityId: materialized.plannedActivityId,
                sportId: materialized.sportId.map(SportId.init(rawValue:)),
                categoryIds: materialized.categoryIds.map(ActivityCategoryId.init(rawValue:)),
                activityType: materialized.activityType,
                title: materialized.title,
                startedAt: Self.startedAt(for: materialized),
                durationMinutes: 1,
                status: .cancelled,
                authorId: actorId,
                sessionForm: nil
            )
            onActivityLogged()
            dismiss()
        } catch TrainingServiceError.plannedActivityAlreadyLinked {
            errorMessage = "This activity has already been logged."
        } catch {
            errorMessage = "Could not cancel this activity. Please try again."
        }
    }

    /// The materialized activity's own date/time, combined into a
    /// single `Date` — same derivation `ActivityDetailViewModel.startedAt(for:)`/
    /// `LogActivityViewModel.startedAt(for:)` already establish for the
    /// exact same purpose, reused here rather than duplicated with
    /// different logic.
    private static func startedAt(for activity: PlannedActivity) -> Date {
        var components = DateComponents(
            year: activity.localDate.year,
            month: activity.localDate.month,
            day: activity.localDate.day
        )
        if let startTime = activity.startLocalTime {
            components.hour = startTime.hour
            components.minute = startTime.minute
        }
        return Calendar.current.date(from: components) ?? .now
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
/// `PlannedActivity` for `.sheet(item:)` presentation —
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
