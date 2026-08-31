import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAthleteDomain
import VoxtrCalendarPlanningDomain

/// Calendar Import Review V1.1 (Inline Review + Ready Staging + Bulk
/// Import + Remembered Exact Choices): backs the "Review new events"
/// screen for ONE `ExternalPlanningSource`. This is the ONE place an
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
    /// confirmed until `markReady(for:)` is called again).
    public var needsReviewItems: [CalendarPlanningCoordinationService.CalendarReviewItem] {
        reviewQueue.filter { !isReadyToImport($0.externalEventKey) }
    }

    /// A Parent-CONFIRMED event, currently collapsed to its compact
    /// summary — the "READY TO IMPORT" section, and exactly the set
    /// `bulkImportReadyItems()` acts on.
    public var readyToImportItems: [CalendarPlanningCoordinationService.CalendarReviewItem] {
        reviewQueue.filter { isReadyToImport($0.externalEventKey) }
    }

    public var readyToImportCount: Int { readyToImportItems.count }

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
    /// staged event's classification values themselves change.
    private func updateStaged(for externalEventKey: String, _ mutate: (inout StagedClassification) -> Void) {
        var staged = stagedClassifications[externalEventKey] ?? StagedClassification()
        mutate(&staged)
        staged.isConfirmedReady = false
        stagedClassifications[externalEventKey] = staged
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
    ///     handling;
    ///   - `.sourceDisabled`: the source became disabled/disconnected
    ///     mid-batch (stale UI) — the loop stops immediately, no further
    ///     item in this batch is attempted, and the queue is refreshed
    ///     (which will now correctly report empty);
    ///   - any other error: staging is kept, un-confirmed back to
    ///     editable, so nothing is silently dropped.
    /// A retry (calling this again after a partial failure) is safe and
    /// never duplicates — `classifyAndImport` itself already guarantees
    /// that (see its own doc comment); this method adds no additional
    /// state that could break that guarantee.
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
                importedCount += 1
            } catch CalendarPlanningCoordinationError.sourceDisabled {
                // The source became disabled/disconnected mid-batch —
                // stop immediately; refreshQueueAndStaging() below will
                // correctly report an empty queue for a disabled source
                // (see fetchReviewQueue's own Blocker 2 guard), so no
                // further per-item bookkeeping is meaningful here.
                sourceBecameUnavailable = true
                break
            } catch {
                failedCount += 1
                var kept = staged
                kept.isConfirmedReady = false
                stagedClassifications[item.externalEventKey] = kept
            }
        }

        refreshQueueAndStaging()

        if sourceBecameUnavailable {
            errorMessage = CalendarPlanningStrings.sourceDisabledError
        } else if failedCount > 0 {
            errorMessage = CalendarPlanningStrings.bulkImportPartialResult(imported: importedCount, failed: failedCount)
        }
    }

    /// The explicit Parent action for "this should never become
    /// Planning" — the View is responsible for the actual confirmation
    /// prompt before calling this. Only the confirmed call reaches here;
    /// nothing mutates before that.
    public func ignore(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) {
        errorMessage = nil
        do {
            _ = try calendarPlanningCoordinationService.ignore(item, for: source, decidedBy: actorId)
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

    // MARK: - Queue + staging refresh (shared by load(), ignore(), restore(), and bulkImportReadyItems())

    /// Re-fetches the review queue (and the Ignored section's own
    /// current-horizon list) and rebuilds `stagedClassifications` to
    /// match `reviewQueue`: an event already staged (a Parent's in-
    /// progress edit, or a still-Ready item from an earlier partial bulk
    /// import) keeps its EXACT existing staging untouched; a genuinely
    /// new event (including one just restored from Ignored) is seeded
    /// from Remembered Exact Choices (V1.1) if one applies, or left
    /// blank/editable otherwise; an event no longer in the queue
    /// (imported, ignored, or disappeared from the source) is dropped so
    /// this dictionary never leaks stale entries.
    private func refreshQueueAndStaging() {
        do {
            reviewQueue = try calendarPlanningCoordinationService.fetchReviewQueue(for: source)
        } catch {
            reviewQueue = []
            errorMessage = errorMessage ?? CalendarPlanningStrings.genericError
        }
        ignoredItems = (try? calendarPlanningCoordinationService.fetchIgnoredReviewItems(for: source)) ?? []

        let remembered = (try? calendarPlanningCoordinationService.rememberedClassifications(for: source)) ?? [:]
        var rebuilt: [String: StagedClassification] = [:]
        for item in reviewQueue {
            if let existing = stagedClassifications[item.externalEventKey] {
                rebuilt[item.externalEventKey] = existing
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
                rebuilt[item.externalEventKey] = StagedClassification(
                    athleteId: match.athleteId, sportId: match.sportId, activityType: match.activityType, isConfirmedReady: true
                )
            } else {
                rebuilt[item.externalEventKey] = StagedClassification()
            }
        }
        stagedClassifications = rebuilt
    }
}
