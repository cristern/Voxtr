import SwiftUI
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAthleteDomain
import VoxtrCalendarPlanningDomain

/// Calendar Import Review V1.1 (Inline Review + Ready Staging + Bulk
/// Import + Remembered Exact Choices; action fix: independent inline
/// button ownership + top-level Import shortcut) + V1.2 (Similar-Event
/// Suggestions) + V1.3 (Suggested Ignore, Needs Attention): the actual
/// working surface for classifying many upcoming events efficiently, for
/// ONE source. Section order, top to bottom, matches this feature's own
/// product contract exactly:
///   1. NEEDS ATTENTION (V1.3) — a still-pending event whose last bulk
///      import attempt failed, with the specific reason, staying fully
///      editable (reuses `NeedsReviewRow`) so the Parent can adjust and
///      retry right here;
///   2. NEEDS REVIEW — classify Athlete/Sport/Activity Type directly on
///      this screen;
///   3. READY TO IMPORT — a compact summary row for every fully staged
///      event;
///   4. SUGGESTED IGNORE (V1.3) — a still-pending event whose title
///      matches a prior EXPLICIT Ignore for this source; reversible
///      ("Review"), and deliberately ABOVE Ignored (still requires
///      Parent judgement — Ignored is a completed decision);
///   5. IGNORED — a compact, receding row for every currently-ignored
///      event still in the provider horizon, with an explicit "Review
///      again" reversal.
/// Plus a top-level Import shortcut, shown only while at least one event
/// is staged Ready, that calls the SAME canonical `bulkImportReadyItems()`
/// the Ready section's own rows feed. Classifying, editing, ignoring,
/// restoring, and reviewing a suggestion all happen right here on this
/// ONE screen; there is deliberately no per-event pushed detail screen
/// (see this project's own "prefer completing simple/related tasks
/// inline" UX rule) — notes/location, when present, expand inline via
/// `DisclosureGroup` inside the SAME row instead.
struct CalendarImportReviewView: View {
    @Bindable var viewModel: CalendarImportReviewViewModel
    @State private var itemPendingIgnore: CalendarPlanningCoordinationService.CalendarReviewItem?

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("calendarImportReview.errorMessage")
                }
            }

            // Calendar Import Review action fix: a calm, top-level
            // shortcut to the SAME `bulkImportReadyItems()` the Ready to
            // Import section's own rows feed — never a second import
            // pathway. Shown only while there is at least one Ready
            // item, so the Parent does not have to scroll past every
            // Needs Review row to reach it once several events are
            // staged. The Ready to Import section below still exists so
            // the Parent can inspect/Edit what is actually staged before
            // committing — this is a shortcut to that same action, not a
            // replacement for it.
            if viewModel.readyToImportCount > 0 {
                Section {
                    HStack {
                        Text(CalendarPlanningStrings.readyToImportSummary(count: viewModel.readyToImportCount))
                            .font(VoxtrTypography.metadata)
                            .foregroundStyle(VoxtrColor.textSecondary)
                        Spacer()
                        Button(CalendarPlanningStrings.bulkImportButton(readyCount: viewModel.readyToImportCount)) {
                            viewModel.bulkImportReadyItems()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("calendarImportReview.topImportButton")
                    }
                }
            }

            if viewModel.reviewQueue.isEmpty && viewModel.ignoredItems.isEmpty {
                Text(CalendarPlanningStrings.reviewEmpty)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            } else {
                // V1.3: Needs Attention is the FIRST event-processing
                // section — a failed bulk-import attempt is the most
                // urgent thing for the Parent to see, before any normal
                // classification work. Reuses NeedsReviewRow exactly (the
                // event is still just staged, not persisted) so the
                // failure reason banner, the SAME pickers, and the SAME
                // Ignore/Ready actions are all available right here —
                // changing a picker or re-tapping Ready is how the Parent
                // "retries."
                if !viewModel.needsAttentionItems.isEmpty {
                    Section {
                        ForEach(viewModel.needsAttentionItems, id: \.externalEventKey) { item in
                            NeedsReviewRow(item: item, viewModel: viewModel) {
                                itemPendingIgnore = item
                            }
                        }
                    } header: {
                        VoxtrSectionHeading(CalendarPlanningStrings.needsAttentionSectionTitle)
                    }
                }

                if !viewModel.needsReviewItems.isEmpty {
                    Section {
                        ForEach(viewModel.needsReviewItems, id: \.externalEventKey) { item in
                            NeedsReviewRow(item: item, viewModel: viewModel) {
                                itemPendingIgnore = item
                            }
                        }
                    } header: {
                        VoxtrSectionHeading(CalendarPlanningStrings.needsReviewSectionTitle)
                    } footer: {
                        Text(CalendarPlanningStrings.reviewExplanation)
                    }
                }

                if !viewModel.readyToImportItems.isEmpty {
                    // Calendar Import Review action fix: the section's
                    // own former bottom "Import N ready activities"
                    // button was removed as a duplicate CTA now that the
                    // top-level shortcut above exists — one obvious
                    // primary action, not two controls doing the exact
                    // same thing. This section still exists so the
                    // Parent can see what is staged and Edit an item
                    // before committing.
                    Section {
                        ForEach(viewModel.readyToImportItems, id: \.externalEventKey) { item in
                            readyToImportRow(item)
                        }
                    } header: {
                        VoxtrSectionHeading(CalendarPlanningStrings.readyToImportSectionTitle)
                    }
                }

                // V1.3: Suggested Ignore sits ABOVE actual Ignored — it
                // still requires Parent judgement (a reversible
                // suggestion), while Ignored below it is a completed,
                // explicit Parent decision. Never persists anything on
                // its own; see `CalendarImportReviewViewModel.reviewSuggestedIgnore(_:)`.
                if !viewModel.suggestedIgnoreItems.isEmpty {
                    Section {
                        ForEach(viewModel.suggestedIgnoreItems, id: \.externalEventKey) { item in
                            suggestedIgnoreRow(item)
                        }
                    } header: {
                        VoxtrSectionHeading(CalendarPlanningStrings.suggestedIgnoreSectionTitle)
                    }
                }

                if !viewModel.ignoredItems.isEmpty {
                    Section {
                        ForEach(viewModel.ignoredItems, id: \.externalEventKey) { item in
                            ignoredRow(item)
                        }
                    } header: {
                        VoxtrSectionHeading(CalendarPlanningStrings.ignoredSectionTitle)
                    }
                }
            }
        }
        .navigationTitle(CalendarPlanningStrings.reviewScreenTitle)
        .onAppear { viewModel.load() }
        .confirmationDialog(
            CalendarPlanningStrings.ignoreConfirmationTitle,
            isPresented: Binding(
                get: { itemPendingIgnore != nil },
                set: { if !$0 { itemPendingIgnore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(CalendarPlanningStrings.ignoreButton, role: .destructive) {
                if let itemPendingIgnore {
                    viewModel.ignore(itemPendingIgnore)
                }
                itemPendingIgnore = nil
            }
            .accessibilityIdentifier("calendarImportReview.confirmIgnoreButton")
            Button("Cancel", role: .cancel) { itemPendingIgnore = nil }
        } message: {
            Text(CalendarPlanningStrings.ignoreConfirmationMessage)
        }
    }

    // MARK: - READY TO IMPORT: compact summary, materially shorter than an editable row

    @ViewBuilder
    private func readyToImportRow(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) -> some View {
        let staged = viewModel.stagedClassification(for: item.externalEventKey)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.event.title?.isEmpty == false ? item.event.title! : "(no title)")
                    .font(VoxtrTypography.cardTitle)
                    .foregroundStyle(VoxtrColor.textPrimary)
                Text(item.event.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                Text(readySummary(staged))
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
            Spacer()
            Text(CalendarPlanningStrings.readyBadge)
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            Button(CalendarPlanningStrings.editButton) {
                viewModel.beginEditing(for: item.externalEventKey)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("calendarImportReview.editButton")
        }
        .accessibilityIdentifier("calendarImportReview.readyRow")
    }

    private func readySummary(_ staged: CalendarImportReviewViewModel.StagedClassification) -> String {
        var parts: [String] = []
        if let athleteId = staged.athleteId, let athlete = viewModel.athletes.first(where: { $0.athleteId == athleteId }) {
            parts.append(athlete.givenName)
        }
        if let sportId = staged.sportId, let sport = viewModel.sports.first(where: { $0.sportId == sportId }) {
            parts.append(sport.displayName)
        }
        parts.append(staged.activityType.displayName)
        return parts.joined(separator: " · ")
    }

    // MARK: - IGNORED: compact, receding row — never shown as though classified

    @ViewBuilder
    private func ignoredRow(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.event.title?.isEmpty == false ? item.event.title! : "(no title)")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                Text(item.event.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
            Spacer()
            Text(CalendarPlanningStrings.ignoredBadge)
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            Button(CalendarPlanningStrings.reviewAgainButton) {
                viewModel.restore(item)
            }
            .buttonStyle(.borderless)
            .font(VoxtrTypography.metadata)
            .accessibilityIdentifier("calendarImportReview.reviewAgainButton")
        }
        .accessibilityIdentifier("calendarImportReview.ignoredRow")
    }

    // MARK: - SUGGESTED IGNORE (V1.3): still requires Parent judgement — never shown as though already decided

    /// Title/date/time (enough to identify the event), a calm
    /// explanation of why it's here, an optional "Based on: <prior
    /// title>" attribution, and two actions: the PRIMARY "Review" (moves
    /// it back to Needs Review for this session, persists nothing) and
    /// an explicit Ignore that goes through the SAME confirmation dialog
    /// and `ignore(_:)` path every other Ignore on this screen already
    /// uses — never a second Ignore business path. Two `Button`s share
    /// this row, so `.buttonStyle(.borderless)` is applied for the SAME
    /// reason `NeedsReviewRow`'s own Ignore/Ready `HStack` needs it (see
    /// that type's own doc comment) — each button must own its own tap
    /// target, not the row's default List behavior.
    @ViewBuilder
    private func suggestedIgnoreRow(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.event.title?.isEmpty == false ? item.event.title! : "(no title)")
                    .font(VoxtrTypography.cardTitle)
                    .foregroundStyle(VoxtrColor.textPrimary)
                Text(item.event.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
            Text(CalendarPlanningStrings.suggestedIgnoreExplanation)
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
            if let matchedTitle = viewModel.suggestedIgnoreMatches[item.externalEventKey] {
                Text(CalendarPlanningStrings.suggestedIgnoreBasedOn(title: matchedTitle))
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }
            HStack {
                Button(CalendarPlanningStrings.reviewSuggestedIgnoreButton) {
                    viewModel.reviewSuggestedIgnore(item)
                }
                .accessibilityIdentifier("calendarImportReview.reviewSuggestedIgnoreButton")

                Spacer()

                Button(CalendarPlanningStrings.ignoreButton, role: .destructive) {
                    itemPendingIgnore = item
                }
                .accessibilityIdentifier("calendarImportReview.suggestedIgnoreIgnoreButton")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("calendarImportReview.suggestedIgnoreRow")
    }
}

/// Calendar Import Review runtime + action fix: ONE Needs Review row —
/// event summary, inline Athlete/Activity Type/Sport pickers, an
/// optional same-row notes/location disclosure, Ignore, and Ready. A
/// dedicated `View` (not a `@ViewBuilder` function on the parent) so its
/// own `DisclosureGroup` expansion state survives independently per row
/// without any shared/ambiguous tap target.
///
/// Two DISTINCT structural causes were found and fixed across two
/// rounds of TestFlight evidence — neither was a gesture/timing/
/// debouncing workaround:
///
/// 1. (runtime fix) A `NavigationLink` used to share this row with these
///    same `Button`s, and `List` treated the WHOLE row as the
///    `NavigationLink`'s own tap target, swallowing taps meant for the
///    buttons. Fixed by removing the `NavigationLink` entirely (replaced
///    by `DisclosureGroup`, which owns only its own header's tap
///    target).
/// 2. (action fix — the bug PROVEN to persist after (1), per TestFlight
///    evidence of Ready still opening the Ignore confirmation) Ignore
///    and Ready are two plain `Button`s inside the SAME `HStack`/`List`
///    row with no explicit button style. Without one, `List` applies its
///    own default row-level button behavior, under which more than one
///    `Button.action` sharing a row can be invoked by a single tap —
///    each button did not actually own its own isolated tap target.
///    Fixed by giving that `HStack` `.buttonStyle(.borderless)`, which
///    is Apple's own documented mechanism for opting a control OUT of a
///    `List` row's shared/automatic tap behavior and into owning
///    exactly its own frame as its tap target — see this `HStack`'s own
///    call site below for where this is applied, and this file's other
///    single-button rows (`readyToImportRow`'s Edit, `ignoredRow`'s
///    Review again) for the same, directly-related pattern corrected
///    for consistency even though a single-button row cannot exhibit
///    this exact cross-firing symptom.
private struct NeedsReviewRow: View {
    let item: CalendarPlanningCoordinationService.CalendarReviewItem
    @Bindable var viewModel: CalendarImportReviewViewModel
    let onIgnoreRequested: () -> Void
    @State private var isDetailsExpanded = false

    private var hasAdditionalMetadata: Bool {
        item.event.notes?.isEmpty == false || item.event.location?.isEmpty == false
    }

    /// V1.2 (Similar-Event Suggestions): `nil` unless THIS row's staged
    /// values were prefilled from a similar (not identical) prior event
    /// — see `StagedClassification.SuggestionKind`'s own doc comment.
    /// Exact remembered matches (`.exactRemembered`) show no special
    /// label here, matching V1.1's own unchanged, already-established
    /// UX (an exact match typically never even reaches Needs Review —
    /// it starts already Ready — so there is nothing to label inline).
    private var similarSuggestionMatchedTitle: String? {
        if case .similarPreviousEvent(let matchedTitle) = viewModel.stagedClassification(for: item.externalEventKey).suggestionKind {
            return matchedTitle
        }
        return nil
    }

    /// V1.3 (Needs Attention): the calm, specific reason THIS row's most
    /// recent bulk-import attempt failed, if any — `nil` for a normal
    /// Needs Review row. See `CalendarImportReviewViewModel.failedImportReasons`'s
    /// own doc comment for how/when this clears.
    private var failureReason: String? {
        viewModel.failedImportReasons[item.externalEventKey]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            eventSummary

            if let failureReason {
                Text(failureReason)
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("calendarImportReview.needsAttentionReason")
            }

            // Calm, compact, near the pickers it explains — never a
            // numeric confidence, percentage, or "AI" framing (see this
            // feature's own product contract). Purely informational:
            // reading it never mutates anything, and it disappears on
            // its own the moment the Parent changes any picker (see
            // `updateStaged(for:_:)`'s own doc comment).
            if let matchedTitle = similarSuggestionMatchedTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(CalendarPlanningStrings.similarSuggestionExplanation)
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                    Text(CalendarPlanningStrings.similarSuggestionBasedOn(title: matchedTitle))
                        .font(VoxtrTypography.metadata)
                        .foregroundStyle(VoxtrColor.textSecondary)
                }
                .accessibilityIdentifier("calendarImportReview.similarSuggestionExplanation")
            }

            Picker(CalendarPlanningStrings.chooseAthlete, selection: Binding(
                get: { viewModel.stagedClassification(for: item.externalEventKey).athleteId },
                set: { viewModel.setStagedAthlete($0, for: item.externalEventKey) }
            )) {
                Text(CalendarPlanningStrings.chooseAthlete).tag(AthleteId?.none)
                ForEach(viewModel.athletes, id: \.athleteId) { athlete in
                    Text(athlete.givenName).tag(AthleteId?.some(athlete.athleteId))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("calendarImportReview.athletePicker")

            Picker(CalendarPlanningStrings.chooseActivityType, selection: Binding(
                get: { viewModel.stagedClassification(for: item.externalEventKey).activityType },
                set: { viewModel.setStagedActivityType($0, for: item.externalEventKey) }
            )) {
                ForEach(ActivityType.selectableCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("calendarImportReview.activityTypePicker")

            Picker(CalendarPlanningStrings.chooseSport, selection: Binding(
                get: { viewModel.stagedClassification(for: item.externalEventKey).sportId },
                set: { viewModel.setStagedSport($0, for: item.externalEventKey) }
            )) {
                Text("None").tag(SportId?.none)
                ForEach(viewModel.sports, id: \.sportId) { sport in
                    Text(sport.displayName).tag(SportId?.some(sport.sportId))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("calendarImportReview.sportPicker")

            // Same-row progressive disclosure — never a pushed screen or
            // sheet, and purely read-only: expanding/collapsing this
            // never mutates any business truth.
            if hasAdditionalMetadata {
                DisclosureGroup(CalendarPlanningStrings.detailsDisclosureLabel, isExpanded: $isDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
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
                    .padding(.top, 2)
                }
                .font(VoxtrTypography.metadata)
                .accessibilityIdentifier("calendarImportReview.detailsDisclosure")
            }

            // Calendar Import Review action fix: `.buttonStyle(.borderless)`
            // on this HStack is the actual fix for TestFlight's "tapping
            // Ready may open the Ignore confirmation" report — see this
            // type's own doc comment (fix 2) for why. Each Button below
            // now owns exactly its own frame as its tap target instead
            // of sharing this row's default List tap behavior.
            HStack {
                Button(CalendarPlanningStrings.ignoreButton, role: .destructive) {
                    onIgnoreRequested()
                }
                .font(VoxtrTypography.metadata)
                .accessibilityIdentifier("calendarImportReview.ignoreButton")

                Spacer()

                // Lead Review follow-up: the ONE explicit action that
                // collapses this row into "Ready to Import" — selecting
                // Athlete/Sport/Activity Type above never does this on
                // its own. Disabled until Athlete is actually selected,
                // matching classifyAndImport's own canonical minimum.
                Button(CalendarPlanningStrings.markReadyButton) {
                    viewModel.markReady(for: item.externalEventKey)
                }
                .disabled(!viewModel.stagedClassification(for: item.externalEventKey).satisfiesMinimumImportRequirements)
                .accessibilityIdentifier("calendarImportReview.markReadyButton")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("calendarImportReview.needsReviewRow")
    }

    @ViewBuilder
    private var eventSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.event.title?.isEmpty == false ? item.event.title! : "(no title)")
                .font(VoxtrTypography.cardTitle)
                .foregroundStyle(VoxtrColor.textPrimary)
            Text(item.event.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)
        }
    }
}
