import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrCalendarPlanningDomain

/// Calendar Import Review V1.1 (Inline Review + Ready Staging + Bulk
/// Import + Remembered Exact Choices) + V1.2 (Similar-Event Suggestions,
/// see `StagedClassification.SuggestionKind`) + V1.3 (Suggested Ignore,
/// Needs Attention): backs the "Review new events" screen for ONE
/// `ExternalPlanningSource`. This is the ONE place an
/// external event becomes a Vǫxtr `PlannedActivity` — no event is ever
/// imported except through an explicit Parent "Import N ready
/// activities" tap (`bulkImportReadyItems()`), which itself only ever
/// calls `CalendarPlanningCoordinationService.classifyAndImport(...)`
/// per staged event — see that method's own doc comment for the full
/// product contract this enforces.
///
/// PRODUCT CONTRACT this type enforces: `Pending -> Ready (staged only)
/// -> Imported / Ignored`. `Ready` is NOT persisted business truth — it
/// is `stagedClassifications` below, a plain, ViewModel-owned,
/// presentation/application-layer dictionary keyed by the event's own
/// stable `externalEventKey`. Only `Imported`/`Ignored` are persisted
/// `CalendarImportDecision` outcomes; a `Ready` (fully staged, not yet
/// imported) event never creates a `PlannedActivity` and never touches
/// `CalendarImportDecision`.
@MainActor
@Observable
public final class CalendarImportReviewViewModel {
    private let calendarPlanningCoordinationService: CalendarPlanningCoordinationService
    private let athleteRepository: AthleteRepository
    private let sportRepository: SportRepository
    private let source: ExternalPlanningSource
    /// The real, human Parent every classify/ignore decision this screen
    /// produces is attributed to — never `.system`.
    private let actorId: ActorId

    public private(set) var reviewQueue: [CalendarPlanningCoordinationService.CalendarReviewItem] = []
    /// Calendar Import Review runtime fix: every event still within the
    /// current external provider horizon whose decision for `source` is
    /// `.ignored` — the Ignored section's own read model (see
    /// `CalendarPlanningCoordinationService.fetchIgnoredReviewItems(for:)`'s
    /// own doc comment). Refreshed alongside `reviewQueue` by
    /// `refreshQueueAndStaging()`, so Ignore/Restore/bulk-import all keep
    /// both lists consistent with each other.
    public private(set) var ignoredItems: [CalendarPlanningCoordinationService.CalendarReviewItem] = []
    /// Calendar Import Review V1.3 (Suggested Ignore): a still-PENDING
    /// event (no `CalendarImportDecision` of any kind) whose title
    /// exactly or conservatively matches a title the Parent has
    /// explicitly ignored before for this SAME source, current provider
    /// horizon — see `refreshQueueAndStaging()` for the full derivation
    /// and its precedence relative to a classification suggestion.
    /// Never itself in `stagedClassifications` (there is nothing being
    /// classified — the question is whether to Ignore, not who/what),
    /// and never in `needsReviewItems`. Purely presentation assistance:
    /// reversible via `reviewSuggestedIgnore(_:)`, and explicit Ignore
    /// (if the Parent taps it) goes through the SAME canonical
    /// `ignore(_:)` this whole screen already uses.
    public private(set) var suggestedIgnoreItems: [CalendarPlanningCoordinationService.CalendarReviewItem] = []
    /// V1.3: for each `suggestedIgnoreItems` entry, the ORIGINAL (non-
    /// normalized) title of the prior explicitly-ignored event it
    /// matched — for the Parent-facing "Based on: <title>" explanation
    /// only.
    public private(set) var suggestedIgnoreMatches: [String: String] = [:]
    /// Calendar Import Review V1.3 (Needs Attention): a still-PENDING
    /// event (no `CalendarImportDecision`) whose most recent
    /// `bulkImportReadyItems()` attempt failed — the Parent-facing
    /// reason text, calm and specific where the actual error is safely
    /// distinguishable (see `bulkImportReadyItems()`'s own doc comment),
    /// otherwise a generic "review and try again." TRANSIENT only —
    /// never persisted, and pruned in `refreshQueueAndStaging()` for any
    /// key no longer in `reviewQueue` (imported, ignored, or otherwise
    /// gone) so this dictionary never leaks stale entries, matching
    /// `stagedClassifications`'s own established pattern.
    public private(set) var failedImportReasons: [String: String] = [:]
    /// V1.3 (Suggested Ignore): the Parent's own explicit "let me look
    /// at this myself" reversal, per `externalEventKey` — session-
    /// scoped, transient ViewModel state ONLY (never a persisted
    /// decision, never a timing hack). See `reviewSuggestedIgnore(_:)`.
    private var liftedToReviewKeys: Set<String> = []
    /// Active (non-archived) athletes, scoped to `source`'s OWN canonical
    /// workspace only — Lead Review follow-up (family-isolation): a
    /// source belongs to exactly one family (see `ExternalPlanningSource`'s
    /// own doc comment), and Calendar Import Review must never let a
    /// Parent pick an athlete from a DIFFERENT family/workspace, even if
    /// both happen to exist in the same local store. Classifies events
    /// into an athlete's CURRENT plan, matching every other Planning
    /// creation surface's own athlete scoping.
    public private(set) var athletes: [AthleteProfile] = []
    public private(set) var sports: [Sport] = []
    public private(set) var errorMessage: String?

    /// Calendar Import Review V1.1 (Lead Review follow-up: the Ready
    /// transition is an explicit Parent action, never an automatic
    /// side effect of picking a value): the smallest presentation-layer
    /// model that supports inline classification, per this feature's own
    /// "READY STAGING MODEL" contract — deliberately NOT a persisted
    /// entity, and `PlannedActivity` is never used as temporary staging.
    /// Keyed by `CalendarReviewItem.externalEventKey` (the same stable
    /// external identity `CalendarImportDecision`/`PlannedActivity`
    /// already use) in `stagedClassifications` below.
    ///
    /// Deliberately keeps TWO separate things separate, per this round's
    /// own product correction: the classification VALUES
    /// (`athleteId`/`sportId`/`activityType`) and whether the Parent has
    /// explicitly CONFIRMED this classification is complete
    /// (`isConfirmedReady`). Selecting/changing a value alone never sets
    /// `isConfirmedReady` — only `markReady(for:)` (the inline "Ready"/
    /// "Done" action) does, and only when the classification already
    /// satisfies the canonical minimum import requirement.
    public struct StagedClassification: Sendable, Equatable {
        /// Calendar Import Review V1.2 (Similar-Event Suggestions): the
        /// smallest explicit presentation metadata the View needs to
        /// distinguish why a staged classification's values arrived
        /// already filled in — never persisted, never itself a source of
        /// business truth. `.none` for a brand-new or Parent-edited
        /// staging (see `updateStaged(for:_:)`, the ONE place this is
        /// reset back to `.none` once the Parent changes any value —
        /// once edited, the values shown are the Parent's own, not the
        /// original suggestion's, so continuing to label them as a
        /// suggestion would be a stale/misleading claim).
        public enum SuggestionKind: Sendable, Equatable {
            case none
            /// V1.1 exact remembered match — unchanged behavior; this
            /// case exists so a future caller COULD distinguish it, but
            /// today's UX intentionally shows no special label for it
            /// (see `CalendarImportReviewView`'s own doc comment).
            case exactRemembered
            /// V1.2 similar-event suggestion — weaker evidence than an
            /// exact match, so it PREFILLS but never confirms Ready (see
            /// `refreshQueueAndStaging()` below). `matchedTitle` is the
            /// ORIGINAL (non-normalized) title of the prior similar
            /// event this suggestion came from, for the Parent-facing
            /// "Based on: <title>" explanation only.
            case similarPreviousEvent(matchedTitle: String)
        }

        public var athleteId: AthleteId?
        public var sportId: SportId?
        public var activityType: ActivityType = .individualTraining
        /// The Parent's own explicit confirmation ("Ready"/"Done") that
        /// THIS shown classification — including an intentional
        /// `sportId == nil` and whatever `activityType` is currently
        /// displayed — is complete. Never set as a side effect of a
        /// picker change; see `markReady(for:)` and `beginEditing(for:)`,
        /// the only two places this is ever written.
        public var isConfirmedReady: Bool = false
        public var suggestionKind: SuggestionKind = .none
        /// Live Suggested Ignore re-evaluation follow-up: `true` the
        /// moment the Parent has explicitly changed ANY of Athlete/Sport/
        /// Activity Type for this event, via `updateStaged(for:_:)` — the
        /// ONE place this is ever set. Exists to distinguish "this row
        /// merely received DEFAULT staging on the most recent
        /// `refreshQueueAndStaging()` pass" from "this row carries actual
        /// Parent-owned state," WITHOUT inferring intent from a value
        /// that can legitimately be a genuine choice either way (e.g.
        /// `sportId == nil` is both a valid untouched default AND a
        /// valid explicit "no Sport" selection — see
        /// `refreshQueueAndStaging()`'s own doc comment for why this
        /// distinction has to be an explicit flag, not inferred from
        /// values). Never persisted — plain transient ViewModel/
        /// presentation state, exactly like every other field on this
        /// struct.
        public var hasUserInteraction: Bool = false

        /// The canonical minimum requirement `classifyAndImport` actually
        /// needs: Athlete must resolve/be selected. `activityType`
        /// always carries a valid selectable value; `sportId` is
        /// legitimately optional ("no specific Sport") — neither ever
        /// blocks readiness on its own.
        public var satisfiesMinimumImportRequirements: Bool { athleteId != nil }

        /// Shown collapsed in "Ready to Import" — requires BOTH the
        /// Parent's own explicit confirmation AND the classification
        /// still being valid (defensive: nothing should be able to
        /// invalidate a confirmed item without also un-confirming it,
        /// but this keeps the derived state honest either way).
        public var isReady: Bool { isConfirmedReady && satisfiesMinimumImportRequirements }
    }

    /// Never persisted — presentation/application state only (see this
    /// type's own doc comment). Rebuilt (preserving any Parent-in-
    /// progress edit already present) every time `reviewQueue` refreshes,
    /// via `refreshQueueAndStaging()`.
    public private(set) var stagedClassifications: [String: StagedClassification] = [:]

    public init(
        calendarPlanningCoordinationService: CalendarPlanningCoordinationService,
        athleteRepository: AthleteRepository,
        sportRepository: SportRepository,
        source: ExternalPlanningSource,
        actorId: ActorId
    ) {
        self.calendarPlanningCoordinationService = calendarPlanningCoordinationService
        self.athleteRepository = athleteRepository
        self.sportRepository = sportRepository
        self.source = source
        self.actorId = actorId
    }

    public func load() {
        errorMessage = nil
        // Lead Review follow-up (family-isolation): scoped to source's OWN
        // workspace, never every athlete in the local store.
        athletes = ((try? athleteRepository.fetchAthletes(forWorkspace: WorkspaceId(rawValue: source.workspaceId))) ?? []).filter { !$0.isArchived }
        sports = (try? sportRepository.fetchAllSports()) ?? []
        refreshQueueAndStaging()
    }

    // MARK: - Needs Review / Ready to Import (derived, never separately stored)

    /// A pending event not yet Parent-confirmed Ready — the "NEEDS
    /// REVIEW" section. Includes a brand-new event, an event the Parent
    /// is still filling in, and a Ready event the Parent tapped "Edit"
    /// on (still showing its previously-staged values, but no longer
    /// confirmed until `markReady(for:)` is called again). Excludes
    /// anything currently shown in Needs Attention or Suggested Ignore
    /// (V1.3) — each pending event appears in exactly one section.
    public var needsReviewItems: [CalendarPlanningCoordinationService.CalendarReviewItem] {
        let suggestedIgnoreKeys = Set(suggestedIgnoreItems.map(\.externalEventKey))
        return reviewQueue.filter {
            !isReadyToImport($0.externalEventKey)
                && !suggestedIgnoreKeys.contains($0.externalEventKey)
                && failedImportReasons[$0.externalEventKey] == nil
        }
    }

    /// Calendar Import Review V1.3: a still-PENDING event whose most
    /// recent bulk-import attempt failed — the FIRST event-processing
    /// section (above Needs Review), so the Parent sees exactly which
    /// events need a decision before anything else. Excludes anything
    /// currently Ready (re-confirming Ready, even without changing a
    /// value, is the Parent's own "try again" signal — see
    /// `bulkImportReadyItems()`'s own doc comment) so a retried item
    /// moves cleanly into Ready to Import instead of staying listed
    /// here twice.
    public var needsAttentionItems: [CalendarPlanningCoordinationService.CalendarReviewItem] {
        reviewQueue.filter { failedImportReasons[$0.externalEventKey] != nil && !isReadyToImport($0.externalEventKey) }
    }

    /// A Parent-CONFIRMED event, currently collapsed to its compact
    /// summary — the "READY TO IMPORT" section, and exactly the set
    /// `bulkImportReadyItems()` acts on.
    public var readyToImportItems: [CalendarPlanningCoordinationService.CalendarReviewItem] {
        reviewQueue.filter { isReadyToImport($0.externalEventKey) }
    }

    public var readyToImportCount: Int { readyToImportItems.count }

    /// PR #49 follow-up (zero-ready top action copy): what the top-level
    /// Import/Suggested-Ignore action area should show — a pure
    /// derivation from `readyToImportCount` and `suggestedIgnoreItems.count`,
    /// exposed here (rather than computed inline in the View's body) so
    /// it is directly unit-testable without any SwiftUI View-body/
    /// snapshot testing. See `CalendarImportReviewView`'s own top-level
    /// action area for where this drives visibility, copy, and the tap
    /// action.
    public enum TopActionState: Sendable, Equatable {
        /// Neither a Ready item nor a Suggested Ignore item exists — the
        /// top-level action area is hidden entirely.
        case hidden
        /// At least one Ready item exists — preserves the EXACT existing
        /// "N ready to import" / "Import N ready activities" copy and
        /// tap behavior, REGARDLESS of the current Suggested Ignore
        /// count: importing Ready activities stays the primary
        /// completion action, and the confirmation dialog itself already
        /// explains the additional Ignore decision when Suggested Ignore
        /// items also exist.
        case readyToImport(readyCount: Int)
        /// Zero Ready items, but at least one Suggested Ignore item —
        /// "Import 0" is never shown; calm, accurate, contextual copy
        /// instead. Tapping still opens the SAME Suggested Ignore
        /// confirmation dialog as `.readyToImport` — there is no second
        /// workflow.
        case suggestedIgnoreOnly(count: Int)
    }

    public var topActionState: TopActionState {
        let readyCount = readyToImportCount
        if readyCount > 0 {
            return .readyToImport(readyCount: readyCount)
        }
        let suggestedIgnoreCount = suggestedIgnoreItems.count
        if suggestedIgnoreCount > 0 {
            return .suggestedIgnoreOnly(count: suggestedIgnoreCount)
        }
        return .hidden
    }

    private func isReadyToImport(_ externalEventKey: String) -> Bool {
        stagedClassifications[externalEventKey]?.isReady ?? false
    }

    // MARK: - Inline staging (no persistence — see `StagedClassification`'s own doc comment)

    public func stagedClassification(for externalEventKey: String) -> StagedClassification {
        stagedClassifications[externalEventKey] ?? StagedClassification()
    }

    public func setStagedAthlete(_ athleteId: AthleteId?, for externalEventKey: String) {
        updateStaged(for: externalEventKey) { $0.athleteId = athleteId }
    }

    public func setStagedSport(_ sportId: SportId?, for externalEventKey: String) {
        updateStaged(for: externalEventKey) { $0.sportId = sportId }
    }

    public func setStagedActivityType(_ activityType: ActivityType, for externalEventKey: String) {
        updateStaged(for: externalEventKey) { $0.activityType = activityType }
    }

    /// Lead Review follow-up: the ONE explicit Parent action that moves a
    /// staged event into "Ready to Import" — never an automatic side
    /// effect of selecting a value. A no-op if the classification does
    /// not yet satisfy the canonical minimum import requirement (the UI
    /// should also disable this action in that case, via
    /// `stagedClassification(for:).satisfiesMinimumImportRequirements`).
    public func markReady(for externalEventKey: String) {
        guard var staged = stagedClassifications[externalEventKey], staged.satisfiesMinimumImportRequirements else { return }
        staged.isConfirmedReady = true
        stagedClassifications[externalEventKey] = staged
    }

    /// The explicit "Edit" action on a compact Ready row — restores the
    /// editable inline form WITHOUT persisting or clearing anything;
    /// every currently-staged field is left exactly as it was, but the
    /// Parent's PRIOR confirmation no longer applies — `markReady(for:)`
    /// must be called again before this event can bulk-import.
    public func beginEditing(for externalEventKey: String) {
        guard var staged = stagedClassifications[externalEventKey] else { return }
        staged.isConfirmedReady = false
        stagedClassifications[externalEventKey] = staged
    }

    /// Applies `mutate` to this event's current staging (or a fresh one).
    /// Lead Review follow-up: deliberately NEVER sets `isConfirmedReady`
    /// — selecting/changing Athlete, Sport, or Activity Type must never
    /// auto-collapse a row into Ready on its own. Conversely, any actual
    /// value change also explicitly UN-confirms an already-Ready item
    /// (mirroring `beginEditing(for:)`), so a stale confirmation can
    /// never survive a value it no longer describes — the ONE place a
    /// staged event's classification values themselves change. Also
    /// resets `suggestionKind` to `.none` (V1.2): once the Parent has
    /// changed a value, whatever is now shown is the Parent's own choice,
    /// not the original prefill, so the "Suggested from..." explanation
    /// no longer describes what is on screen and must stop showing. Also
    /// clears any Needs Attention failure marker (V1.3): changing the
    /// classification is exactly the Parent action the failure-clearing
    /// contract names — the Parent has acted on it, so the stale reason
    /// from a prior attempt with the OLD values must not keep showing.
    /// Also sets `hasUserInteraction = true` (live Suggested Ignore
    /// re-evaluation follow-up) — the ONE place this ever happens, since
    /// this is the ONE place a Parent explicitly changes a classification
    /// value.
    private func updateStaged(for externalEventKey: String, _ mutate: (inout StagedClassification) -> Void) {
        var staged = stagedClassifications[externalEventKey] ?? StagedClassification()
        mutate(&staged)
        staged.isConfirmedReady = false
        staged.suggestionKind = .none
        staged.hasUserInteraction = true
        stagedClassifications[externalEventKey] = staged
        failedImportReasons.removeValue(forKey: externalEventKey)
    }

    // MARK: - Bulk import

    /// The explicit Parent action Calendar Import Review V1.1 exists for:
    /// imports every currently Ready (explicitly Parent-confirmed) event
    /// in one action, through the SAME canonical
    /// `CalendarPlanningCoordinationService.classifyAndImport(...)` path
    /// a single-event import already used — never a bypass of its
    /// guards, never a batch-level shortcut.
    ///
    /// Per-item outcome handling (never an arbitrary success score, never
    /// a silent whole-batch report):
    ///   - success: the item's staging is cleared; `reviewQueue`'s own
    ///     refresh (via `fetchReviewQueue`, which excludes decided
    ///     events) makes it disappear on its own;
    ///   - `.existingActivityConflict`: staging is KEPT, un-confirmed
    ///     back to editable (`isConfirmedReady = false`) — the Parent's
    ///     own values are preserved so they can see the conflict and
    ///     adjust, matching the single-event form's own established
    ///     handling. V1.3: also recorded in `failedImportReasons` with a
    ///     specific, calm reason and surfaced in Needs Attention;
    ///   - `.sourceDisabled`: the source became disabled/disconnected
    ///     mid-batch (stale UI) — the loop stops immediately, no further
    ///     item in this batch is attempted, and the queue is refreshed
    ///     (which will now correctly report empty). This is a BATCH-level
    ///     abort, not a per-item Needs Attention entry — after it, the
    ///     queue is empty, so there is nothing left to attach one to;
    ///   - any other error (V1.3: `PlanningServiceError.invalidField` —
    ///     the realistic remaining failure mode for a calendar-sourced
    ///     field failing a `PlanningService` validation bound (not
    ///     necessarily length — e.g. a required field being empty
    ///     qualifies too) — mapped to a truthful, general reason since
    ///     this switch does not inspect which bound failed; anything else
    ///     mapped to a generic one): staging is kept, un-
    ///     confirmed back to editable, recorded in `failedImportReasons`,
    ///     so nothing is silently dropped and the Parent can see exactly
    ///     which event needs attention and why, in Needs Attention.
    /// A retry (calling this again after a partial failure) is safe and
    /// never duplicates — `classifyAndImport` itself already guarantees
    /// that (see its own doc comment); this method adds no additional
    /// state that could break that guarantee. Never persists failure
    /// state — `failedImportReasons` is plain ViewModel memory, pruned in
    /// `refreshQueueAndStaging()` for anything no longer in the queue.
    public func bulkImportReadyItems() {
        errorMessage = nil
        let readyItems = readyToImportItems
        guard !readyItems.isEmpty else { return }

        var importedCount = 0
        var failedCount = 0
        var sourceBecameUnavailable = false

        for item in readyItems {
            guard let staged = stagedClassifications[item.externalEventKey], let athleteId = staged.athleteId else { continue }
            do {
                _ = try calendarPlanningCoordinationService.classifyAndImport(
                    item, for: source, athleteId: athleteId, sportId: staged.sportId, activityType: staged.activityType, decidedBy: actorId
                )
                stagedClassifications.removeValue(forKey: item.externalEventKey)
                failedImportReasons.removeValue(forKey: item.externalEventKey)
                importedCount += 1
            } catch CalendarPlanningCoordinationError.sourceDisabled {
                // The source became disabled/disconnected mid-batch —
                // stop immediately; refreshQueueAndStaging() below will
                // correctly report an empty queue for a disabled source
                // (see fetchReviewQueue's own Blocker 2 guard), so no
                // further per-item bookkeeping is meaningful here.
                sourceBecameUnavailable = true
                break
            } catch CalendarPlanningCoordinationError.existingActivityConflict {
                failedCount += 1
                var kept = staged
                kept.isConfirmedReady = false
                stagedClassifications[item.externalEventKey] = kept
                failedImportReasons[item.externalEventKey] = CalendarPlanningStrings.existingActivityConflictError
            } catch let planningError as PlanningServiceError {
                failedCount += 1
                var kept = staged
                kept.isConfirmedReady = false
                stagedClassifications[item.externalEventKey] = kept
                failedImportReasons[item.externalEventKey] = Self.needsAttentionReason(forPlanningServiceError: planningError)
            } catch {
                failedCount += 1
                var kept = staged
                kept.isConfirmedReady = false
                stagedClassifications[item.externalEventKey] = kept
                failedImportReasons[item.externalEventKey] = CalendarPlanningStrings.bulkImportGenericItemError
            }
        }

        refreshQueueAndStaging()

        if sourceBecameUnavailable {
            errorMessage = CalendarPlanningStrings.sourceDisabledError
        } else if failedCount > 0 {
            errorMessage = CalendarPlanningStrings.bulkImportPartialResult(imported: importedCount, failed: failedCount)
        }
    }

    /// Import-time Suggested Ignore confirmation: the explicit, Parent-
    /// confirmed batch counterpart of a single manual Ignore tap — called
    /// ONLY after the View has shown its own "Ignore & Import"
    /// confirmation dialog (triggered by the top-level Import action when
    /// `suggestedIgnoreItems` is non-empty) and the Parent has explicitly
    /// tapped it. The View owns whether confirmation was accepted; this
    /// method never runs on its own initiative and never assumes consent
    /// — Suggested Ignore alone still persists nothing.
    ///
    /// Does exactly two things, in order, reusing existing canonical
    /// paths rather than a second implementation of either:
    ///   1. persists every event CURRENTLY in `suggestedIgnoreItems` as a
    ///      real `.ignored` `CalendarImportDecision`, through the EXACT
    ///      SAME `CalendarPlanningCoordinationService.ignore(_:for:decidedBy:)`
    ///      a single manual Ignore tap already uses — same actor
    ///      attribution, same source scoping, same `ignoredEventTitle`
    ///      snapshot, same stable `externalEventKey` identity;
    ///   2. UNLESS the source became disabled/disconnected during that
    ///      Ignore phase (see below), calls the existing, UNCHANGED
    ///      `bulkImportReadyItems()` for the Ready items — its existing
    ///      partial-failure/Needs Attention handling is entirely
    ///      untouched and un-duplicated. `bulkImportReadyItems()` itself
    ///      returns immediately, WITHOUT refreshing, when there are zero
    ///      Ready items (its own pre-existing, correct guard for its own
    ///      single responsibility) — so this method calls
    ///      `refreshQueueAndStaging()` itself, right after the Ignore
    ///      phase, to guarantee the newly-ignored truth is always picked
    ///      up even in a Suggested-Ignore-only batch with no Ready items
    ///      at all. `bulkImportReadyItems()` then does its own (possibly
    ///      redundant, always harmless) refresh when it actually has
    ///      items to import.
    ///
    /// FAILURE BEHAVIOR (V1 — no cross-item rollback; "One Truth" matters
    /// more than pretending this batch was atomic):
    ///   - PR #49 follow-up (source-disabled Ignore safety): `ignore(_:for:decidedBy:)`
    ///     now throws `.sourceDisabled` for a disabled/disconnected
    ///     source (see that method's own doc comment) — the ONE genuine
    ///     global condition this method aborts on. The Ignore-phase loop
    ///     stops IMMEDIATELY on the first `.sourceDisabled`: no further
    ///     Suggested Ignore item is attempted, `bulkImportReadyItems()`
    ///     is never called (never risking an unsafe Ready import against
    ///     the same disabled source), state is refreshed, and the SAME
    ///     `sourceDisabledError` copy every other disabled-source path
    ///     already surfaces is shown — never a silent partial-success
    ///     claim. For the common stale-screen case (the source was
    ///     ALREADY disabled before the Parent even tapped "Ignore &
    ///     Import"), the very FIRST loop iteration throws, so ZERO new
    ///     `.ignored` decisions are ever created. Any Suggested Ignore
    ///     items that DID succeed earlier in the same loop, before a
    ///     genuine mid-batch source-state change, are left persisted —
    ///     no rollback machinery;
    ///   - any OTHER per-item failure (not `.sourceDisabled`) is counted
    ///     and the loop continues to the next item — an already-succeeded
    ///     sibling Ignore is never rolled back, and nothing fabricates
    ///     success for the item that failed (it simply stays a pending
    ///     Suggested Ignore candidate, since it was never removed from
    ///     the review queue). The Ready import still runs afterward in
    ///     this case.
    public func confirmSuggestedIgnoresAndImportReadyItems() {
        errorMessage = nil
        let itemsToIgnore = suggestedIgnoreItems
        var ignoreFailureCount = 0
        var sourceBecameUnavailable = false

        for item in itemsToIgnore {
            do {
                _ = try calendarPlanningCoordinationService.ignore(item, for: source, decidedBy: actorId)
            } catch CalendarPlanningCoordinationError.sourceDisabled {
                sourceBecameUnavailable = true
                break
            } catch {
                ignoreFailureCount += 1
            }
        }

        // See this method's own doc comment: bulkImportReadyItems() below
        // returns without refreshing when there are zero Ready items, so
        // this refresh must happen here to guarantee the newly-ignored
        // (or, on sourceDisabled, still only partially-ignored) truth is
        // always picked up.
        refreshQueueAndStaging()

        if sourceBecameUnavailable {
            errorMessage = CalendarPlanningStrings.sourceDisabledError
            return
        }

        bulkImportReadyItems()

        // bulkImportReadyItems() above already set a more specific
        // message for its own outcome (a Ready-import partial failure) —
        // never clobber that. Only surface the Ignore-phase failure count
        // when it would otherwise go unreported.
        if errorMessage == nil, ignoreFailureCount > 0 {
            errorMessage = CalendarPlanningStrings.suggestedIgnoreConfirmationPartialFailure(failed: ignoreFailureCount)
        }
    }

    /// V1.3 (Needs Attention): maps a caught `PlanningServiceError` to a
    /// calm, useful, Parent-facing reason — never a raw internal error
    /// dump. `classifyAndImport`'s own genuinely-new creation path (the
    /// only `PlanningService` call this screen's bulk import can reach)
    /// only ever throws `.invalidField` in practice (e.g. calendar notes
    /// or title failing a validation bound, or a required field being
    /// empty). This switch does not inspect `.invalidField`'s own
    /// associated field-description String, so `bulkImportInvalidFieldError`
    /// must stay a truthful GENERAL reason rather than naming a specific
    /// cause (see that string's own doc comment) — every other case is
    /// handled explicitly anyway since this switch must stay exhaustive
    /// against the full `PlanningServiceError` type, falling back to the
    /// same generic reason any other unexpected failure gets.
    private static func needsAttentionReason(forPlanningServiceError error: PlanningServiceError) -> String {
        switch error {
        case .invalidField:
            return CalendarPlanningStrings.bulkImportInvalidFieldError
        case .weekPlanNotFound, .plannedActivityNotFound, .plannedActivityDoesNotBelongToWeekPlan, .weekPlanNotDraft,
             .recurringPlannedActivityNotFound, .recurringOccurrenceAlreadyAccepted, .recurringOccurrenceAthleteMismatch,
             .recurringOccurrenceOutsideWeekPlan, .recurringOccurrenceWeekdayMismatch, .recurringOccurrenceOutsideEffectiveRange,
             .recurringPlannedActivityDisabled:
            return CalendarPlanningStrings.bulkImportGenericItemError
        }
    }

    /// The explicit Parent action for "this should never become
    /// Planning" — the View is responsible for the actual confirmation
    /// prompt before calling this. Only the confirmed call reaches here;
    /// nothing mutates before that.
    ///
    /// PR #49 follow-up: the canonical `ignore(_:for:decidedBy:)` now
    /// throws `.sourceDisabled` for a disabled/disconnected source (see
    /// that method's own doc comment) — surfaced here with the SAME
    /// calm, specific `sourceDisabledError` copy `restore(_:)` already
    /// uses for the identical case, never the generic fallback.
    public func ignore(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) {
        errorMessage = nil
        do {
            _ = try calendarPlanningCoordinationService.ignore(item, for: source, decidedBy: actorId)
            refreshQueueAndStaging()
        } catch CalendarPlanningCoordinationError.sourceDisabled {
            errorMessage = CalendarPlanningStrings.sourceDisabledError
            refreshQueueAndStaging()
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    /// Calendar Import Review runtime fix ("Review again"): reverses an
    /// Ignore for one event in the Ignored section, through the
    /// canonical `restoreIgnoredEvent(_:for:)` — deletes ONLY that exact
    /// `.ignored` decision; never creates a `PlannedActivity` or any
    /// other Planning truth. The restored event then reappears in Needs
    /// Review purely because `reviewQueue`'s own refresh below now finds
    /// no decision for it — the same "absence of decision = pending"
    /// model every other pending event already uses, including a fresh
    /// Remembered Exact Choices prefill if one applies (no special
    /// hidden behavior for a restored item).
    public func restore(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) {
        errorMessage = nil
        do {
            try calendarPlanningCoordinationService.restoreIgnoredEvent(item.externalEventKey, for: source)
            refreshQueueAndStaging()
        } catch CalendarPlanningCoordinationError.sourceDisabled {
            errorMessage = CalendarPlanningStrings.sourceDisabledError
            refreshQueueAndStaging()
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    /// Calendar Import Review V1.3 (Suggested Ignore): the Parent's
    /// explicit "let me look at this myself" reversal — moves `item` out
    /// of the Suggested Ignore section and into normal Needs Review,
    /// WITHOUT persisting anything: no `CalendarImportDecision` of any
    /// kind, no `PlannedActivity`, and no fake/placeholder decision
    /// created to "suppress" the suggestion. The event itself is left
    /// completely untouched. Suppression is transient, session-scoped
    /// ViewModel state only (`liftedToReviewKeys`, keyed by the event's
    /// own stable `externalEventKey`) — never a timing hack — so the
    /// SAME suggestion does not immediately reapply on the very next
    /// refresh this call triggers, but leaving and reopening this screen
    /// (a fresh ViewModel) starts fresh, matching this feature's own
    /// "reversible, non-permanent suggestion" contract exactly.
    public func reviewSuggestedIgnore(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) {
        liftedToReviewKeys.insert(item.externalEventKey)
        refreshQueueAndStaging()
    }

    /// Live Suggested Ignore re-evaluation follow-up: the smallest clean
    /// distinction between (A) a row that merely received DEFAULT staging
    /// on the most recent `refreshQueueAndStaging()` pass, and (B) a row
    /// containing Parent-owned or suggestion-owned state that must never
    /// be silently discarded. `true` (meaningful — preserve as-is,
    /// never re-derive) when ANY of:
    ///   - the Parent has explicitly changed Athlete/Sport/Activity Type
    ///     (`hasUserInteraction`);
    ///   - the item is Ready (`isConfirmedReady`) — covers Remembered
    ///     Exact Choices' own already-Ready prefill too, since that path
    ///     also sets this;
    ///   - the item carries a PR #47 exact/similar classification
    ///     suggestion (`suggestionKind != .none`);
    ///   - the item is currently Needs Attention (a failed bulk-import
    ///     attempt recorded in `failedImportReasons`).
    /// Deliberately does NOT inspect `athleteId`/`sportId`/`activityType`
    /// values themselves — `sportId == nil`, the default
    /// `.individualTraining`, and `athleteId == nil` are all legitimate
    /// UNTOUCHED defaults, so inferring "meaningful" from them would
    /// misclassify a brand-new, never-interacted-with row as Parent-owned
    /// and permanently block it from ever being re-evaluated against new
    /// Suggested Ignore evidence.
    private func hasMeaningfulStaging(_ staged: StagedClassification, externalEventKey: String) -> Bool {
        staged.hasUserInteraction
            || staged.isConfirmedReady
            || staged.suggestionKind != .none
            || failedImportReasons[externalEventKey] != nil
    }

    // MARK: - Queue + staging refresh (shared by load(), ignore(), restore(), reviewSuggestedIgnore(_:), and bulkImportReadyItems())

    /// Re-fetches the review queue (and the Ignored section's own
    /// current-horizon list) and rebuilds `stagedClassifications` to
    /// match `reviewQueue`: an event carrying MEANINGFUL existing staging
    /// (see `hasMeaningfulStaging(_:externalEventKey:)`) keeps its EXACT
    /// existing staging untouched — a Parent's in-progress edit, a still-
    /// Ready item from an earlier partial bulk import, an already-
    /// resolved classification suggestion, or a Needs Attention failure
    /// marker must never be silently discarded just because this method
    /// runs again. A genuinely new event, OR one that only ever received
    /// UNTOUCHED default staging on an earlier pass (never a Parent
    /// action, never a suggestion, never a failure) — including one just
    /// restored from Ignored — is (re-)seeded fresh: from Remembered
    /// Exact Choices (V1.1) if one applies, else from a Similar-Event
    /// Suggestion (V1.2) if one applies, else — V1.3, and only when the
    /// Parent has not already lifted this exact event back into review
    /// this session — becomes a Suggested Ignore candidate if its title
    /// matches a prior explicit Ignore for this source, or is otherwise
    /// left blank/editable. This is what makes Suggested Ignore work
    /// LIVE, in the SAME open ViewModel session, immediately after a new
    /// explicit Ignore decision: a sibling event's default staging from
    /// before that Ignore is never treated as "already decided," so the
    /// very next refresh (which every mutating action already triggers)
    /// re-derives it against the now-updated Ignore evidence. An event no
    /// longer in the queue (imported, ignored, or disappeared from the
    /// source) is dropped so `stagedClassifications` never leaks stale
    /// entries — `failedImportReasons` (V1.3) is pruned the same way.
    ///
    /// PRECEDENCE: meaningful existing staging wins outright and is never
    /// re-derived; for everything else, exact remembered match is checked
    /// FIRST and wins outright; a similar-event classification suggestion
    /// is only ever considered when no exact match exists; Suggested
    /// Ignore is only ever considered when NEITHER classification signal
    /// applies — this is the "do not guess when evidence conflicts" rule
    /// in concrete form: an event this source has classified/imported
    /// before (exact or similar) is never simultaneously proposed for
    /// Ignore. All three paths call into pure/read-only helpers only
    /// (`ExternalEventTitleNormalization`, `ExternalEventTitleSimilarity`,
    /// and `calendarPlanningCoordinationService`'s own read methods) — no
    /// matching RULE is implemented inline here; this method only
    /// orchestrates which prefill or section, if any, applies to each
    /// item.
    private func refreshQueueAndStaging() {
        do {
            reviewQueue = try calendarPlanningCoordinationService.fetchReviewQueue(for: source)
        } catch {
            reviewQueue = []
            errorMessage = errorMessage ?? CalendarPlanningStrings.genericError
        }
        ignoredItems = (try? calendarPlanningCoordinationService.fetchIgnoredReviewItems(for: source)) ?? []
        // PR #48 follow-up (durable Suggested Ignore evidence): deliberately
        // NOT derived from `ignoredItems` above — that list is horizon-bound
        // (only events still resolvable from the current provider fetch),
        // so a repeating event's OWN prior ignored occurrence ages out of it
        // long before the Parent stops wanting it ignored. This reads the
        // durable `.ignored` decision history instead (see
        // `CalendarPlanningCoordinationService.historicalIgnoredTitles(for:)`'s
        // own doc comment) so Suggested Ignore keeps working after that.
        let previouslyIgnoredTitles = (try? calendarPlanningCoordinationService.historicalIgnoredTitles(for: source)) ?? []

        let remembered = (try? calendarPlanningCoordinationService.rememberedClassifications(for: source)) ?? [:]
        let historicalTitles = (try? calendarPlanningCoordinationService.historicalTitleClassifications(for: source)) ?? []
        var rebuiltStaging: [String: StagedClassification] = [:]
        var rebuiltSuggestedIgnore: [CalendarPlanningCoordinationService.CalendarReviewItem] = []
        var rebuiltSuggestedIgnoreMatches: [String: String] = [:]

        for item in reviewQueue {
            if let existing = stagedClassifications[item.externalEventKey],
               hasMeaningfulStaging(existing, externalEventKey: item.externalEventKey) {
                rebuiltStaging[item.externalEventKey] = existing
                continue
            }
            // Remembered Exact Choices (V1.1): PREFILL only — a safe
            // exact-title match MAY arrive already Parent-confirmed
            // Ready (unlike a brand-new event, which always starts
            // requiring an explicit markReady(for:) — see this type's
            // own doc comment on why that distinction is intentional).
            // Either way this never creates a CalendarImportDecision or
            // PlannedActivity by itself; the Parent must still tap Edit
            // to override, or explicitly bulk-import as-is.
            if let normalizedTitle = ExternalEventTitleNormalization.normalize(item.event.title),
               let match = remembered[normalizedTitle] {
                rebuiltStaging[item.externalEventKey] = StagedClassification(
                    athleteId: match.athleteId, sportId: match.sportId, activityType: match.activityType,
                    isConfirmedReady: true, suggestionKind: .exactRemembered
                )
                continue
            }
            if let suggestion = ExternalEventTitleSimilarity.suggestedMatch(forEventTitle: item.event.title, among: historicalTitles) {
                // Similar-Event Suggestion (V1.2): weaker evidence than
                // an exact match — PREFILLS the classification values,
                // but deliberately does NOT set isConfirmedReady. The
                // event stays in Needs Review with the suggestion shown
                // and the Parent's explicit markReady(for:) still
                // required, exactly like a brand-new event's own
                // baseline requirement — see this type's own doc
                // comment ("IMPORTANT READY BEHAVIOR" in this feature's
                // product contract).
                rebuiltStaging[item.externalEventKey] = StagedClassification(
                    athleteId: suggestion.athleteId, sportId: suggestion.sportId, activityType: suggestion.activityType,
                    isConfirmedReady: false, suggestionKind: .similarPreviousEvent(matchedTitle: suggestion.matchedOriginalTitle)
                )
                continue
            }
            // Suggested Ignore (V1.3): no classification evidence applies
            // — check whether the Parent has explicitly Ignored a
            // matching (exact or similar) title for THIS source before,
            // unless they already lifted this exact event back into
            // review this session (`liftedToReviewKeys`). Deliberately
            // NOT given a `stagedClassifications` entry — nothing is
            // being classified; the open question is whether to Ignore,
            // not who/what.
            if !liftedToReviewKeys.contains(item.externalEventKey),
               let matchedIgnoredTitle = ExternalEventTitleSimilarity.suggestedIgnoreMatch(
                   forEventTitle: item.event.title, amongPreviouslyIgnoredTitles: previouslyIgnoredTitles
               ) {
                rebuiltSuggestedIgnore.append(item)
                rebuiltSuggestedIgnoreMatches[item.externalEventKey] = matchedIgnoredTitle
                continue
            }
            rebuiltStaging[item.externalEventKey] = StagedClassification()
        }
        stagedClassifications = rebuiltStaging
        suggestedIgnoreItems = rebuiltSuggestedIgnore
        suggestedIgnoreMatches = rebuiltSuggestedIgnoreMatches

        let reviewQueueKeys = Set(reviewQueue.map(\.externalEventKey))
        failedImportReasons = failedImportReasons.filter { reviewQueueKeys.contains($0.key) }
    }
}
