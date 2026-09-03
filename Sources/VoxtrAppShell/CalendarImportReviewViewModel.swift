import Foundation
import VoxtrCore
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

        /// Runtime follow-up (split UX — shared Athlete/Sport): ONE child
        /// within a Parent-defined (or Suggested-Split-prefilled) split —
        /// a plain, view-layer editing shape; never itself Planning
        /// truth. A split represents several training units inside ONE
        /// external event, which — for the validated real-world use case
        /// — belongs to one Athlete and one Sport; the child units differ
        /// by Activity Type and timing only. Athlete/Sport therefore live
        /// ONCE at the split level (`splitAthleteId`/`splitSportId`
        /// below), never repeated per child — this struct deliberately
        /// carries NO athlete/sport fields of its own. A stable `id` this
        /// View's `ForEach` needs for add/remove/edit.
        public struct SplitChild: Sendable, Equatable, Identifiable {
            public let id: UUID
            public var activityType: ActivityType
            public var startOffsetMinutes: Int
            public var durationMinutes: Int
            /// Runtime follow-up (Part 3 — sequential split timing
            /// assistance): the SMALLEST transient staging metadata
            /// needed to distinguish "this child's duration is still the
            /// system's own proposal, anchored to the external event's
            /// remaining time" from "the Parent has explicitly edited
            /// this duration, so it is now Parent-owned." `false` by
            /// default — a brand-new blank/manually-added child, or one
            /// added with no usable external end time to derive from,
            /// starts Parent-owned from the moment it exists. Set `true`
            /// ONLY by `CalendarImportReviewViewModel`'s own sequential-
            /// timing helper when it derives a duration from the
            /// external event's remaining time; cleared the instant the
            /// Parent explicitly edits `durationMinutes` (see
            /// `updateSplitChild(_:for:mutate:)`). Never sent to
            /// `CalendarPlanningCoordinationService` — purely a View-
            /// layer editing signal, never a persisted or domain
            /// concept.
            public var isDurationDerivedFromEventRemainder: Bool = false

            public init(
                id: UUID = UUID(),
                activityType: ActivityType = .individualTraining,
                startOffsetMinutes: Int = 0,
                durationMinutes: Int = 30,
                isDurationDerivedFromEventRemainder: Bool = false
            ) {
                self.id = id
                self.activityType = activityType
                self.startOffsetMinutes = startOffsetMinutes
                self.durationMinutes = durationMinutes
                self.isDurationDerivedFromEventRemainder = isDurationDerivedFromEventRemainder
            }

            var isValid: Bool {
                durationMinutes > 0 && durationMinutes <= 1440 && startOffsetMinutes >= 0
            }
        }

        /// Runtime follow-up (split UX — shared Athlete/Sport): the ONE
        /// Athlete/Sport context for the WHOLE split — set once above the
        /// child list, expanded into every
        /// `CalendarPlanningCoordinationService.DecomposedChildInput` at
        /// import time (see `bulkImportReadyItems()`). `splitAthleteId`
        /// is REQUIRED before a split can become Ready (mirrors the
        /// ordinary path's own `athleteId != nil` requirement — see
        /// `satisfiesMinimumImportRequirements` below); `splitSportId`
        /// stays optional, exactly like the ordinary path's own
        /// `sportId`.
        public var splitAthleteId: AthleteId?
        public var splitSportId: SportId?
        /// VX-038: `true` once the Parent has explicitly chosen "Split
        /// activity" (or accepted/is viewing a Suggested Split) for this
        /// event — while `true`, `splitAthleteId`/`splitSportId`/
        /// `splitChildren` (not `athleteId`/`sportId`/`activityType`
        /// above) are what actually import, via `classifyAndImportSplit`.
        /// Toggling this off returns to the ordinary single-activity
        /// fields, which are left untouched underneath (so toggling back
        /// on never loses a Parent's earlier split edits — see
        /// `setSplitEnabled(_:for:)`).
        public var isSplitEnabled: Bool = false
        public var splitChildren: [SplitChild] = []
        /// VX-038: `true` ONLY for a split that is STILL exactly what
        /// `CalendarPlanningCoordinationService.suggestedSplit(for:source:)`
        /// proposed — cleared the instant the Parent edits any child
        /// (see `updateSplitChild(_:for:)`/`addSplitChild(for:)`/
        /// `removeSplitChild(_:for:)`), mirroring `suggestionKind`'s own
        /// "no longer describes what is on screen" rule. Presentation
        /// label only ("Suggested Split") — never itself a gate on
        /// import, which always requires the same explicit Ready/import
        /// action regardless of this flag.
        public var isSuggestedSplitPrefill: Bool = false

        /// Lead Review follow-up (split semantics — minimum two
        /// children): mirrors `CalendarPlanningCoordinationService`'s own
        /// `.splitRequiresAtLeastTwoChildren` guard — a split with fewer
        /// than 2 children is never Ready/importable, even though the
        /// Parent may still toggle Split on and edit a single child
        /// in-progress (see `setSplitEnabled(_:for:)`/`addSplitChild(for:)`).
        public var splitChildrenAreValid: Bool {
            splitChildren.count >= 2 && splitChildren.allSatisfy(\.isValid)
        }
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

        /// The canonical minimum requirement `classifyAndImport` (or,
        /// when `isSplitEnabled`, `classifyAndImportSplit`) actually
        /// needs: an Athlete must resolve/be selected. `activityType`
        /// always carries a valid selectable value; `sportId`/
        /// `splitSportId` are legitimately optional ("no specific
        /// Sport") — neither ever blocks readiness on its own. For a
        /// split, the Athlete requirement is the ONE shared
        /// `splitAthleteId` (runtime follow-up: shared Athlete/Sport),
        /// not a per-child value.
        public var satisfiesMinimumImportRequirements: Bool {
            isSplitEnabled ? (splitAthleteId != nil && splitChildrenAreValid) : athleteId != nil
        }

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
        logRestoreSplitDiagnostic(point: "B (after Athlete selection)", for: externalEventKey)
    }

    public func setStagedSport(_ sportId: SportId?, for externalEventKey: String) {
        updateStaged(for: externalEventKey) { $0.sportId = sportId }
        logRestoreSplitDiagnostic(point: "C (after Sport selection)", for: externalEventKey)
    }

    public func setStagedActivityType(_ activityType: ActivityType, for externalEventKey: String) {
        updateStaged(for: externalEventKey) { $0.activityType = activityType }
        logRestoreSplitDiagnostic(point: "D (after Activity Type selection)", for: externalEventKey)
    }

    // MARK: - VX-038: Split activity (inline staging only — same "no persistence" contract)

    /// The explicit "Split activity" toggle.
    ///
    /// Runtime follow-up (TestFlight — classification preservation):
    /// `splitChildren.isEmpty` is the ONE signal for "no split-editing
    /// state exists yet at all" — every activation after the FIRST
    /// always leaves at least one child behind (Split OFF never clears
    /// `splitChildren`; see below), so this same check both (a) decides
    /// whether to seed a first child at all, and (b) decides whether
    /// this is a genuinely first activation that should INHERIT the
    /// Parent's already-entered ordinary classification
    /// (`athleteId`/`sportId`/`activityType`) rather than let it appear
    /// to silently vanish. A REACTIVATION (children already present)
    /// never re-seeds from the ordinary fields — the Parent's own prior
    /// split edits win untouched, exactly as before. The ordinary
    /// `athleteId`/`sportId`/`activityType` fields themselves are never
    /// modified by this method — they remain intact underneath for a
    /// later Split OFF to fall back to.
    ///
    /// Turning split OFF preserves any already-entered
    /// `splitAthleteId`/`splitSportId`/`splitChildren` untouched — this
    /// method only ever changes `isSplitEnabled` itself once split
    /// state already exists. Never sets `isConfirmedReady`, matching
    /// every other staging mutation's own "selecting/changing something
    /// never auto-confirms Ready" rule.
    public func setSplitEnabled(_ isEnabled: Bool, for externalEventKey: String) {
        logRestoreSplitDiagnostic(point: "E (immediately before Split activation)", for: externalEventKey)
        updateStaged(for: externalEventKey) { staged in
            staged.isSplitEnabled = isEnabled
            if isEnabled && staged.splitChildren.isEmpty {
                staged.splitAthleteId = staged.athleteId
                staged.splitSportId = staged.sportId
                staged.splitChildren = [StagedClassification.SplitChild(activityType: staged.activityType)]
            }
        }
        logRestoreSplitDiagnostic(point: "F (immediately after Split activation)", for: externalEventKey)
    }

    /// Runtime follow-up (split UX — shared Athlete/Sport): sets the ONE
    /// Athlete shared by every child in this split. Clears the
    /// Suggested-Split label, matching every other split edit's own
    /// "no longer describes what is on screen" rule.
    public func setSplitAthlete(_ athleteId: AthleteId?, for externalEventKey: String) {
        updateStaged(for: externalEventKey) { staged in
            staged.splitAthleteId = athleteId
            staged.isSuggestedSplitPrefill = false
        }
    }

    /// Runtime follow-up (split UX — shared Athlete/Sport): sets the ONE
    /// Sport shared by every child in this split — optional, matching
    /// the ordinary path's own `sportId`.
    public func setSplitSport(_ sportId: SportId?, for externalEventKey: String) {
        updateStaged(for: externalEventKey) { staged in
            staged.splitSportId = sportId
            staged.isSuggestedSplitPrefill = false
        }
    }

    /// Runtime follow-up (Part 3 — sequential split timing assistance):
    /// a new child's `startOffsetMinutes` and `durationMinutes` are
    /// PROPOSED, not left blank for the Parent to calculate by hand —
    /// see `Self.nextSequentialSplitChild(afterLastOf:eventStart:eventEnd:)`'s
    /// own doc comment for the exact algorithm. Assistance only: every
    /// proposed value remains freely editable, and the Parent may
    /// create a gap or overlap by editing them — this method never
    /// rewrites any EARLIER child.
    ///
    /// Lead Review follow-up (do not auto-create a child outside the
    /// event envelope): when the external event has a known end and the
    /// previous child already reaches or exceeds it, there is no
    /// remaining known event time from which Vǫxtr can safely PROPOSE
    /// another activity — `nextSequentialSplitChild` returns `nil`, and
    /// this method appends nothing. Reads current staging first and
    /// returns early in that case, so a no-op tap never runs
    /// `updateStaged`'s own side effects (clearing `isConfirmedReady`/
    /// `suggestionKind`, etc.) for a screen that did not actually
    /// change — mirroring `markReady(for:)`'s own "guard before
    /// mutating" shape.
    public func addSplitChild(for externalEventKey: String) {
        let event = reviewItem(for: externalEventKey)?.event
        let staged = stagedClassification(for: externalEventKey)
        guard let newChild = Self.nextSequentialSplitChild(
            afterLastOf: staged.splitChildren, eventStart: event?.startDate, eventEnd: event?.endDate
        ) else { return }
        updateStaged(for: externalEventKey) { staged in
            staged.splitChildren.append(newChild)
            staged.isSuggestedSplitPrefill = false
        }
    }

    public func removeSplitChild(_ childId: UUID, for externalEventKey: String) {
        updateStaged(for: externalEventKey) { staged in
            staged.splitChildren.removeAll { $0.id == childId }
            staged.isSuggestedSplitPrefill = false
        }
    }

    /// Runtime follow-up (Part 3 — sequential split timing assistance,
    /// "DERIVED END-ANCHORED DURATION" / "HUMAN OVERRIDE"): after
    /// `mutate` runs, compares the child's OWN before/after values (the
    /// generic `mutate` closure is used for every child field — Activity
    /// Type, start offset, and duration alike — from the View's own
    /// per-control bindings, each of which changes exactly one field per
    /// call) to decide:
    ///   - `durationMinutes` itself changed → the Parent just edited
    ///     duration directly; it becomes Parent-owned from this point on
    ///     (`isDurationDerivedFromEventRemainder = false`), and no
    ///     further recalculation ever overwrites it again;
    ///   - `startOffsetMinutes` changed AND duration is STILL system-
    ///     derived (never explicitly edited) → duration is recalculated
    ///     to keep the child anchored to the external event's own end,
    ///     using the SAME remaining-time rule
    ///     `nextSequentialSplitChild` itself uses. If the new offset
    ///     would produce a non-positive remainder, the duration is left
    ///     exactly as it was — never forced to an invalid value, and
    ///     the Parent's own offset edit is never reverted (Parent
    ///     judgement wins; see this feature's own "GAPS AND OVERLAPS"
    ///     contract);
    ///   - any other change (Activity Type, or a child whose duration
    ///     is already Parent-owned) leaves the derived/owned flag
    ///     exactly as it was.
    /// This method never touches any OTHER child.
    public func updateSplitChild(_ childId: UUID, for externalEventKey: String, mutate: (inout StagedClassification.SplitChild) -> Void) {
        let event = reviewItem(for: externalEventKey)?.event
        updateStaged(for: externalEventKey) { staged in
            guard let index = staged.splitChildren.firstIndex(where: { $0.id == childId }) else { return }
            let before = staged.splitChildren[index]
            mutate(&staged.splitChildren[index])
            var after = staged.splitChildren[index]

            if after.durationMinutes != before.durationMinutes {
                after.isDurationDerivedFromEventRemainder = false
            } else if after.startOffsetMinutes != before.startOffsetMinutes, after.isDurationDerivedFromEventRemainder,
                      let eventStart = event?.startDate, let eventEnd = event?.endDate {
                let eventDurationMinutes = Int(eventEnd.timeIntervalSince(eventStart) / 60)
                let remainingMinutes = eventDurationMinutes - after.startOffsetMinutes
                if remainingMinutes > 0 {
                    after.durationMinutes = remainingMinutes
                }
            }
            staged.splitChildren[index] = after
            staged.isSuggestedSplitPrefill = false
        }
    }

    /// Runtime follow-up (Part 3 — sequential split timing assistance);
    /// Lead Review follow-up (do not auto-create a child outside the
    /// event envelope): the ONE place automatic child timing is
    /// computed, used only by `addSplitChild(for:)` (a brand-new child)
    /// — `updateSplitChild(_:for:mutate:)`'s own re-anchoring of an
    /// EXISTING still-derived child after the Parent's own explicit
    /// start-offset edit is a separate "Parent judgement wins" case
    /// (see that method's own doc comment) and is NOT guarded by this
    /// function.
    ///
    /// `afterLastOf.last == nil` (the very first child a split ever
    /// gets): the existing safe product default (`0` / `30`, via
    /// `SplitChild.init`'s own defaults) — deliberately NEVER
    /// automatically consumes the whole external event. Always returns a
    /// child in this case — a split's own first child is never withheld.
    ///
    /// Otherwise: `startOffsetMinutes = previous.startOffsetMinutes + previous.durationMinutes`
    /// (immediately after the previous child ends) — this is never
    /// negative, since both of the previous child's own values are
    /// already bounded `>= 0`/`> 0`.
    ///   - No usable external end time (`eventEnd` nil, or not after
    ///     `eventStart`): the existing safe sequential fallback —
    ///     `startOffsetMinutes` as computed above, safe default
    ///     duration, `isDurationDerivedFromEventRemainder = false`
    ///     (Parent-owned from the start, so a later start-offset edit
    ///     never tries to "fix" it).
    ///   - A usable end time exists, but the previous child already
    ///     reaches or exceeds it (`startOffsetMinutes >= eventDurationMinutes`):
    ///     returns `nil` — there is no remaining KNOWN event time from
    ///     which Vǫxtr can safely PROPOSE another activity, so no child
    ///     is generated at all. This is an automatic-PROPOSAL guard
    ///     only: it never prevents the Parent from manually creating a
    ///     gap or overlap by editing an EXISTING child's own values (see
    ///     `updateSplitChild`'s own "GAPS AND OVERLAPS" contract), and it
    ///     never rewrites any earlier child.
    ///   - A usable end time exists and remains ahead of the proposed
    ///     start: the new child's duration is proposed as exactly the
    ///     remainder (`eventDurationMinutes - startOffsetMinutes`,
    ///     always `> 0` here), marked
    ///     `isDurationDerivedFromEventRemainder = true`.
    private static func nextSequentialSplitChild(
        afterLastOf existingChildren: [StagedClassification.SplitChild],
        eventStart: Date?,
        eventEnd: Date?
    ) -> StagedClassification.SplitChild? {
        guard let previous = existingChildren.last else {
            return StagedClassification.SplitChild()
        }
        let startOffsetMinutes = previous.startOffsetMinutes + previous.durationMinutes
        guard let eventStart, let eventEnd, eventEnd > eventStart else {
            return StagedClassification.SplitChild(startOffsetMinutes: startOffsetMinutes)
        }
        let eventDurationMinutes = Int(eventEnd.timeIntervalSince(eventStart) / 60)
        guard startOffsetMinutes < eventDurationMinutes else {
            return nil
        }
        let remainingMinutes = eventDurationMinutes - startOffsetMinutes
        return StagedClassification.SplitChild(
            startOffsetMinutes: startOffsetMinutes, durationMinutes: remainingMinutes, isDurationDerivedFromEventRemainder: true
        )
    }

    /// Runtime follow-up (Part 3): the current `CalendarReviewItem` for
    /// `externalEventKey`, looked up from the live `reviewQueue` — never
    /// stored on `StagedClassification` itself (which stays a plain,
    /// `Equatable`, presentation-only value type with no reference back
    /// to the review queue).
    private func reviewItem(for externalEventKey: String) -> CalendarPlanningCoordinationService.CalendarReviewItem? {
        reviewQueue.first { $0.externalEventKey == externalEventKey }
    }

    /// Lead Review follow-up: the ONE explicit Parent action that moves a
    /// staged event into "Ready to Import" — never an automatic side
    /// effect of selecting a value. A no-op if the classification does
    /// not yet satisfy the canonical minimum import requirement (the UI
    /// should also disable this action in that case, via
    /// `stagedClassification(for:).satisfiesMinimumImportRequirements`).
    ///
    /// VX-038 unified recognition follow-up (Part 10 — Ready-time
    /// re-evaluation): a Parent-confirmed Ready classification is
    /// TRANSIENT recognition evidence for the rest of the active Review
    /// workflow (see `ReadyRecognitionShape`'s own doc comment) — so
    /// marking THIS event Ready must let any other still-untouched
    /// pending row re-evaluate against it immediately, exactly like
    /// `bulkImportReadyItems()` already re-evaluates the remaining queue
    /// after each import. `refreshQueueAndStaging()` is safe to call
    /// here: it never discards genuine Parent-owned state (protected by
    /// `hasMeaningfulStaging`), and it never creates any durable Planning
    /// or evidence truth by itself. Also sets `hasUserInteraction = true`
    /// (Part 12): tapping "Ready" is itself an explicit Parent action —
    /// this is what makes an item that arrived ALREADY Ready purely from
    /// a system prefill (Remembered Exact Choice, `hasUserInteraction ==
    /// false`) distinguishable from one the Parent genuinely confirmed,
    /// so only the latter is eligible to teach a THIRD pending event —
    /// see `readyRecognitionShape(for:)`'s own doc comment.
    public func markReady(for externalEventKey: String) {
        guard var staged = stagedClassifications[externalEventKey], staged.satisfiesMinimumImportRequirements else { return }
        staged.isConfirmedReady = true
        staged.hasUserInteraction = true
        stagedClassifications[externalEventKey] = staged
        refreshQueueAndStaging()
    }

    /// The explicit "Edit" action on a compact Ready row — restores the
    /// editable inline form WITHOUT persisting or clearing anything;
    /// every currently-staged field is left exactly as it was, but the
    /// Parent's PRIOR confirmation no longer applies — `markReady(for:)`
    /// must be called again before this event can bulk-import.
    ///
    /// Runtime follow-up (VX-038 — `hasMeaningfulStaging` no longer
    /// treats a bare `isConfirmedReady`/`suggestionKind` as sticky on its
    /// own, so an untouched system-generated prefill can be superseded
    /// by newly-learned Suggested Split evidence — see that method's own
    /// doc comment): tapping "Edit" is itself an explicit Parent action,
    /// exactly like `updateStaged(for:_:)`'s own callers — it now also
    /// sets `hasUserInteraction = true`, so a row the Parent is actively
    /// reconsidering can never be silently wiped and re-derived (e.g.
    /// snapping back to auto-Ready) by an unrelated refresh triggered
    /// elsewhere (ignoring/restoring/importing a DIFFERENT event) before
    /// the Parent re-confirms it.
    public func beginEditing(for externalEventKey: String) {
        guard var staged = stagedClassifications[externalEventKey] else { return }
        staged.isConfirmedReady = false
        staged.hasUserInteraction = true
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
            guard let staged = stagedClassifications[item.externalEventKey] else { continue }
            // VX-038: a split-enabled, Ready item imports through the
            // SEPARATE `classifyAndImportSplit` path — never a bypass of
            // the ordinary `classifyAndImport` guards, just the correct
            // canonical path for "this event is more than one training
            // unit." `staged.satisfiesMinimumImportRequirements` already
            // gates `isReady`/`readyToImportItems` above, so
            // `staged.splitAthleteId` is resolved and every child is
            // valid. Runtime follow-up (shared Athlete/Sport): the
            // service boundary still receives fully explicit, canonical
            // `DecomposedChildInput` values — this is where the ONE
            // shared `splitAthleteId`/`splitSportId` is expanded into
            // every child, never a weakening of the service's own
            // per-child domain model.
            guard staged.isSplitEnabled || staged.athleteId != nil else { continue }
            do {
                if staged.isSplitEnabled {
                    guard let sharedAthleteId = staged.splitAthleteId else { continue }
                    _ = try calendarPlanningCoordinationService.classifyAndImportSplit(
                        item, for: source,
                        children: staged.splitChildren.map { child in
                            CalendarPlanningCoordinationService.DecomposedChildInput(
                                athleteId: sharedAthleteId, sportId: staged.splitSportId, activityType: child.activityType,
                                startOffsetMinutes: child.startOffsetMinutes, durationMinutes: child.durationMinutes
                            )
                        },
                        decidedBy: actorId
                    )
                } else if let athleteId = staged.athleteId {
                    _ = try calendarPlanningCoordinationService.classifyAndImport(
                        item, for: source, athleteId: athleteId, sportId: staged.sportId, activityType: staged.activityType, decidedBy: actorId
                    )
                }
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
            logRestoreSplitDiagnostic(point: "A (immediately after Review again)", for: item.externalEventKey)
        } catch CalendarPlanningCoordinationError.sourceDisabled {
            errorMessage = CalendarPlanningStrings.sourceDisabledError
            refreshQueueAndStaging()
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    /// VX-038 unified recognition follow-up (Part 17 — Alpha diagnostic):
    /// static repository-level testing and repeated code-level tracing
    /// could not reproduce a THIRD, distinct root cause — beyond what PR
    /// #55 already fixed — specific to the Ignore → "Review again" →
    /// classify → Split lifecycle the Product Owner reported on
    /// TestFlight; the exact 11-step regression sequence (restore →
    /// Athlete/Sport/non-default Activity Type → Split) traces through
    /// this ViewModel's own logic as correct. This is the smallest
    /// useful, privacy-safe capture of that EXACT transition on a real
    /// device, so a genuine TestFlight run can show whether the failure
    /// is happening at a layer these tests cannot see (e.g. SwiftUI
    /// Picker/Toggle/row-identity timing) rather than in this staging
    /// logic itself. Alpha/Console only (OSLog, `.private` for the one
    /// identifying value) — never athlete names, event titles, notes,
    /// location, or URLs; every other field is a bare enum case or
    /// nil/non-nil boolean, never a raw value. Purely observational:
    /// never mutates anything, never gates any behavior.
    private func logRestoreSplitDiagnostic(point: String, for externalEventKey: String) {
        let staged = stagedClassifications[externalEventKey] ?? StagedClassification()
        let recognitionShapeCategory: String
        if let shape = Self.readyRecognitionShape(for: staged) {
            switch shape {
            case .single: recognitionShapeCategory = "single"
            case .split: recognitionShapeCategory = "split"
            }
        } else {
            recognitionShapeCategory = "none"
        }
        VoxtrLog.logger(.appShell).info("""
            VX-038 unified recognition restore/split diagnostic [\(point, privacy: .public)] \
            externalEventKey=\(externalEventKey, privacy: .private) \
            ordinaryAthleteSet=\(staged.athleteId != nil, privacy: .public) \
            ordinarySportSet=\(staged.sportId != nil, privacy: .public) \
            ordinaryActivityType=\(String(describing: staged.activityType), privacy: .public) \
            splitChildrenCount=\(staged.splitChildren.count, privacy: .public) \
            splitAthleteSet=\(staged.splitAthleteId != nil, privacy: .public) \
            splitSportSet=\(staged.splitSportId != nil, privacy: .public) \
            firstChildActivityType=\(staged.splitChildren.first.map { String(describing: $0.activityType) } ?? "none", privacy: .public) \
            hasUserInteraction=\(staged.hasUserInteraction, privacy: .public) \
            isSplitEnabled=\(staged.isSplitEnabled, privacy: .public) \
            isConfirmedReady=\(staged.isConfirmedReady, privacy: .public) \
            recognitionShape=\(recognitionShapeCategory, privacy: .public)
            """)
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
    ///   - the Parent has explicitly changed Athlete/Sport/Activity Type,
    ///     or explicitly toggled Split (both go through `updateStaged`,
    ///     the ONE place `hasUserInteraction` is set);
    ///   - the item ALREADY carries an applied split (`isSplitEnabled`) —
    ///     whether Parent-built or a previously-applied Suggested Split;
    ///     once correct, never re-derived merely because this method runs
    ///     again;
    ///   - the item is currently Needs Attention (a failed bulk-import
    ///     attempt recorded in `failedImportReasons`).
    ///
    /// Runtime follow-up (VX-038 — the actual missing-Suggested-Split
    /// root cause): `isConfirmedReady` and `suggestionKind != .none` were
    /// PREVIOUSLY also included here, which was the real production bug.
    /// A Remembered Exact Choice (V1.1) or Similar-Event Suggestion
    /// (V1.2) prefill — computed on some EARLIER refresh, before this
    /// event had any decomposition evidence, and never touched by the
    /// Parent (`hasUserInteraction` stays `false` for both — they are
    /// written directly in `refreshQueueAndStaging()`, bypassing
    /// `updateStaged`) — used to lock in permanently the instant it was
    /// first computed. The exact real-world sequence this broke: the
    /// Parent has previously imported ordinary (non-split) occurrences of
    /// a recurring event (so V1.1 remembered-exact history exists for its
    /// title); opening Review therefore immediately prefills EVERY still-
    /// pending occurrence — including a LATER one the Parent hasn't
    /// looked at yet — with an already-Ready exact-remembered
    /// classification. The Parent then explicitly splits an EARLIER
    /// occurrence, writing new decomposition evidence. On the very same
    /// refresh cycle that import triggers, the later occurrence's stale
    /// exact-remembered staging was preserved untouched by the OLD
    /// `isConfirmedReady`/`suggestionKind` checks — `suggestedSplit(for:source:)`
    /// (verified structurally correct — recurring-series match, then
    /// same-source exact-title fallback) was simply never CALLED for it,
    /// on that refresh or any later one, because this method had already
    /// decided the row was "meaningful" and skipped straight past the
    /// Suggested Split precedence tier entirely. This is why "the
    /// EventKit identifiers might differ" was never a sufficient
    /// explanation on its own: the title-fallback branch was correct and
    /// reachable, but never reached.
    ///
    /// Every existing call site that sets `isConfirmedReady = true` was
    /// checked: `markReady(for:)` (an explicit Parent action) can only
    /// ever run on a staging whose `athleteId`/`splitAthleteId` already
    /// came from `updateStaged` (`hasUserInteraction == true`) — never
    /// from a bare `isConfirmedReady` with `hasUserInteraction == false`.
    /// Dropping it from this OR-list therefore never discards a genuine
    /// Parent "Ready" tap: it is always already covered by
    /// `hasUserInteraction`. A not-yet-imported Remembered/Similar
    /// prefill re-deriving identically (when nothing changed) is
    /// invisible to the Parent; re-deriving to a NEW, more specific
    /// Suggested Split (when a split was just learned, or newly
    /// conflicting Ready evidence withdraws a stale one) is exactly the
    /// fix — and still requires the Parent's own explicit Ready/import
    /// action before anything is committed, same as before.
    ///
    /// Lead Review follow-up (PR #56 — Split ownership asymmetry): a bare
    /// `staged.isSplitEnabled` was PREVIOUSLY also included here, which
    /// made EVERY Split staging sticky purely because of its shape — a
    /// Split produced entirely by system recognition (session Ready
    /// evidence, or durable Suggested Split evidence — both construct
    /// `StagedClassification` directly, bypassing `updateStaged`, so
    /// `hasUserInteraction` stays `false`) became permanently immune to
    /// re-evaluation the instant it was first applied, even though the
    /// equivalent system-generated SINGLE recognition was never sticky
    /// on its own. This defeated the whole point of the recurring
    /// conflict-veto logic in `ReadyRecognitionIndex`: newer conflicting
    /// Ready evidence could correctly mark a key conflicted, but an
    /// untouched system-generated Split that had already been applied to
    /// some OTHER pending row would never be re-evaluated again to see
    /// that conflict, because `hasMeaningfulStaging` short-circuited
    /// before `sessionReadyShape` was ever consulted for it. Genuine
    /// Parent-built Split state is unaffected by removing it: every
    /// explicit Split mutation (`setSplitEnabled`/`setSplitAthlete`/
    /// `setSplitSport`/`addSplitChild`/`removeSplitChild`/
    /// `updateSplitChild`) already goes through `updateStaged`, which
    /// sets `hasUserInteraction = true` — `isSplitEnabled` was never
    /// actually protecting anything `hasUserInteraction` didn't already
    /// cover for real Parent work; it only ever mattered for the two
    /// system-generated cases this fix intentionally re-exposes to
    /// re-evaluation.
    ///
    /// Deliberately does NOT inspect `athleteId`/`sportId`/`activityType`
    /// values themselves — `sportId == nil`, the default
    /// `.individualTraining`, and `athleteId == nil` are all legitimate
    /// UNTOUCHED defaults, so inferring "meaningful" from them would
    /// misclassify a brand-new, never-interacted-with row as Parent-owned
    /// and permanently block it from ever being re-evaluated against new
    /// Suggested Ignore (or Suggested Split) evidence.
    private func hasMeaningfulStaging(_ staged: StagedClassification, externalEventKey: String) -> Bool {
        staged.hasUserInteraction
            || failedImportReasons[externalEventKey] != nil
    }

    // MARK: - VX-038 unified recognition (Ready-time transient evidence)

    /// VX-038 unified recognition follow-up: the ONE user-visible
    /// recognition contract — "classify → Ready → matching event is
    /// prefilled/suggested" — must behave identically whether the
    /// Parent-approved classification represents Shape A (single) or
    /// Shape B (split). Repository inspection (Part 1) found that the
    /// EXISTING single-activity mechanism (Remembered Exact Choices/
    /// Similar-Event Suggestions) only ever reads FROM DURABLE evidence
    /// — `CalendarImportDecision(status: .imported)` rows — meaning it
    /// already only actually taught AFTER Import, not at bare Ready,
    /// despite `StagedClassification.isConfirmedReady` existing as a
    /// distinct concept. That was an accidental implementation gap, not
    /// an intentional product rule (nothing in this feature's own
    /// contract ever said Ready alone should NOT assist), so this type
    /// generalizes recognition to also cover TRANSIENT, in-session Ready
    /// evidence for BOTH shapes — the smallest common representation,
    /// never persisted, never sent to `CalendarPlanningCoordinationService`.
    ///
    /// CONFLICT: compared via `Equatable` exactly like
    /// `CalendarPlanningCoordinationService`'s own `EvidenceChildShape`
    /// comparison for durable Split evidence — for Split this means
    /// shared Athlete, shared Sport, child count/order, and each child's
    /// Activity Type/start offset/duration ALL have to agree for two
    /// Ready rows to count as the same shape (Part 9).
    private enum ReadyRecognitionShape: Equatable {
        case single(athleteId: AthleteId, sportId: SportId?, activityType: ActivityType)
        case split(athleteId: AthleteId, sportId: SportId?, children: [SplitChildShape])

        struct SplitChildShape: Equatable {
            let activityType: ActivityType
            let startOffsetMinutes: Int
            let durationMinutes: Int
        }
    }

    /// Lead Review follow-up (PR #56 — Blocker 1, single/split Ready
    /// semantic parity): the confirmation status a matched
    /// `ReadyRecognitionShape` arrives with must be driven by EVIDENCE
    /// STRENGTH, never by shape. `isExactMatch` carries that strength
    /// explicitly rather than letting `stagedClassification(fromReadyShape:)`
    /// branch on `.single` vs `.split` — today every match this
    /// TRANSIENT session tier produces IS exact (both
    /// `ReadyRecognitionIndex` lookups below are exact-key matches —
    /// `recurringEventIdentifier` or the SAME normalized-title equality
    /// Remembered Exact Choice already uses — never fuzzy, never a
    /// `.first`-among-many pick), so `isExactMatch` is always `true` for
    /// every value this file currently constructs. It exists as an
    /// explicit field, not a hardcoded literal at the call site, so a
    /// genuinely weaker future tier (if this pipeline is ever extended)
    /// could arrive `false` without changing `stagedClassification(fromReadyShape:)`
    /// at all — that function only ever reads this field, never the
    /// shape, to decide confirmation.
    private struct MatchedReadyRecognition {
        let shape: ReadyRecognitionShape
        let isExactMatch: Bool
    }

    /// `nil` unless `staged` resolves to a complete, valid shape AND is
    /// GENUINELY Parent-approved — `isConfirmedReady` alone is not
    /// enough (Part 12: "B must not become new evidence merely because
    /// it was suggested. Only after Parent explicitly marks B Ready may
    /// B itself become... evidence"). A Remembered Exact Choice (V1.1)
    /// MAY still arrive already `isConfirmedReady == true` purely as a
    /// system prefill the Parent never touched (`hasUserInteraction ==
    /// false`) — that existing, unchanged UX still lets it sit in Ready
    /// to Import and be bulk-imported as-is, but it must NOT itself
    /// teach a THIRD, different pending event within this same session
    /// until the Parent does something explicit with it (edits a value,
    /// or taps "Ready" themselves — `setStagedAthlete`/`setStagedSport`/
    /// `setStagedActivityType`/the whole Split editing surface, and
    /// `markReady(for:)` itself, all set `hasUserInteraction = true`).
    /// A Split shape's own CONTRIBUTION to the index is unaffected in
    /// practice, even though `isConfirmedReady == true` for a split now
    /// arises from two different places (Lead Review follow-up, PR #56):
    /// genuine Parent-driven staging (`setSplitEnabled`/`addSplitChild`/
    /// `updateSplitChild`/`markReady`, which always sets
    /// `hasUserInteraction = true` by construction), OR an exact session
    /// match arriving pre-confirmed via `stagedClassification(fromReadyShape:)`
    /// (which does NOT set `hasUserInteraction`). Only the FIRST case
    /// passes this guard and contributes further — an untouched
    /// system-arrived Split, exactly like an untouched system-arrived
    /// Single, must itself be explicitly acted on before it becomes
    /// evidence for a THIRD event (Part 12, unchanged). Durable
    /// Suggested Split evidence (the tier below, read from
    /// `CalendarPlanningCoordinationService.suggestedSplit(for:source:)`)
    /// is a separate, still-unchanged case that never sets
    /// `isConfirmedReady` at all.
    private static func readyRecognitionShape(for staged: StagedClassification) -> ReadyRecognitionShape? {
        guard staged.isConfirmedReady, staged.hasUserInteraction else { return nil }
        if staged.isSplitEnabled {
            guard let splitAthleteId = staged.splitAthleteId, staged.splitChildrenAreValid else { return nil }
            return .split(
                athleteId: splitAthleteId,
                sportId: staged.splitSportId,
                children: staged.splitChildren.map {
                    ReadyRecognitionShape.SplitChildShape(
                        activityType: $0.activityType, startOffsetMinutes: $0.startOffsetMinutes, durationMinutes: $0.durationMinutes
                    )
                }
            )
        }
        guard let athleteId = staged.athleteId else { return nil }
        return .single(athleteId: athleteId, sportId: staged.sportId, activityType: staged.activityType)
    }

    /// VX-038 unified recognition follow-up: the transient, per-refresh
    /// index of every currently Ready classification's shape, keyed
    /// exactly like durable evidence (`recurringEventIdentifier` first,
    /// `normalizedTitle` fallback — Part 8, same matching direction, no
    /// fuzzy Split matching). Built fresh from the staging that existed
    /// BEFORE this refresh pass, so a row this SAME pass derives from it
    /// can never itself feed back into the index until a LATER, separate
    /// refresh — preventing the self-propagating chain Part 12 forbids
    /// ("an unconfirmed suggestion must not teach," and a row this pass
    /// only just prefilled was never itself Parent-confirmed within this
    /// same pass).
    private struct ReadyRecognitionIndex {
        private var byRecurringId: [String: ReadyRecognitionShape] = [:]
        private var conflictedRecurringIds: Set<String> = []
        private var byNormalizedTitle: [String: ReadyRecognitionShape] = [:]
        private var conflictedTitles: Set<String> = []

        mutating func add(recurringId: String?, normalizedTitle: String?, shape: ReadyRecognitionShape) {
            if let recurringId {
                Self.merge(shape, into: &byRecurringId, conflicts: &conflictedRecurringIds, key: recurringId)
            }
            if let normalizedTitle {
                Self.merge(shape, into: &byNormalizedTitle, conflicts: &conflictedTitles, key: normalizedTitle)
            }
        }

        private static func merge(_ shape: ReadyRecognitionShape, into map: inout [String: ReadyRecognitionShape], conflicts: inout Set<String>, key: String) {
            guard !conflicts.contains(key) else { return }
            if let existing = map[key] {
                guard existing == shape else {
                    map.removeValue(forKey: key)
                    conflicts.insert(key)
                    return
                }
            } else {
                map[key] = shape
            }
        }

        /// Lead Review follow-up (PR #56 — Blocker 2, recurring conflict
        /// must veto title fallback): tri-state, so a caller can tell
        /// "no Ready evidence at all" (`.none` — safe to keep looking in
        /// a WEAKER tier) apart from "Ready evidence exists here but
        /// conflicts" (`.conflict` — this key is a proven ambiguity;
        /// stop, never silently fall through to a weaker tier that might
        /// otherwise resolve). Both `byRecurringId`/`byNormalizedTitle`
        /// lookups share this same result shape for a single, consistent
        /// caller-side veto rule (Blocker 2's own required correction).
        enum LookupResult {
            case none
            case agreed(ReadyRecognitionShape)
            case conflict
        }

        func lookup(forRecurringId recurringId: String) -> LookupResult {
            if conflictedRecurringIds.contains(recurringId) { return .conflict }
            if let shape = byRecurringId[recurringId] { return .agreed(shape) }
            return .none
        }

        func lookup(forNormalizedTitle title: String) -> LookupResult {
            if conflictedTitles.contains(title) { return .conflict }
            if let shape = byNormalizedTitle[title] { return .agreed(shape) }
            return .none
        }
    }

    /// Same recurring-series-first, exact-title-fallback precedence
    /// `CalendarPlanningCoordinationService.suggestedSplit(for:source:)`
    /// already uses for durable evidence (Part 8).
    ///
    /// Lead Review follow-up (PR #56 — Blocker 2): for a RECURRING
    /// event, a recurring-tier CONFLICT is a terminal veto — stronger
    /// conflicting evidence (the same recurring series) must never be
    /// silently bypassed in favor of a weaker tier (exact title) that
    /// happens to still resolve unambiguously for unrelated reasons.
    /// Title fallback only ever runs when the recurring tier has NO
    /// evidence at all (`.none`) — never after a `.conflict`. A
    /// non-recurring event only ever consults the title tier, unchanged.
    private static func sessionReadyShape(for event: ExternalCalendarEvent, index: ReadyRecognitionIndex) -> MatchedReadyRecognition? {
        if event.isRecurring {
            switch index.lookup(forRecurringId: event.eventIdentifier) {
            case .agreed(let shape):
                return MatchedReadyRecognition(shape: shape, isExactMatch: true)
            case .conflict:
                return nil
            case .none:
                break
            }
        }
        guard let normalizedTitle = ExternalEventTitleNormalization.normalize(event.title) else { return nil }
        guard case .agreed(let shape) = index.lookup(forNormalizedTitle: normalizedTitle) else { return nil }
        return MatchedReadyRecognition(shape: shape, isExactMatch: true)
    }

    /// Translates a `MatchedReadyRecognition` into the SAME staging
    /// shapes the durable-evidence tiers already construct.
    ///
    /// Lead Review follow-up (PR #56 — Blocker 1): confirmation status
    /// (`isConfirmedReady`) is driven ENTIRELY by `matched.isExactMatch`
    /// — the evidence's own strength — never by whether `shape` is
    /// `.single` or `.split`. This is the fix for the single/split Ready
    /// semantic inconsistency the Lead Review flagged: previously
    /// `.single` always arrived confirmed and `.split` never did, purely
    /// because of shape. Every value this pipeline constructs today is
    /// `isExactMatch == true` (see `MatchedReadyRecognition`'s own doc
    /// comment), so BOTH shapes now arrive already Ready — the SAME
    /// "MAY arrive already Ready" contract Remembered Exact Choice
    /// (V1.1) already established, generalized to Split per the Product
    /// Owner's explicit decision that recognition flow must not differ
    /// merely because the activity is split. Either way this is
    /// presentation assistance only: never itself a
    /// `CalendarImportDecision`/`PlannedActivity`/`DecompositionEvidence`
    /// write, and the Parent's own explicit bulk-import action is still
    /// what actually persists anything.
    private static func stagedClassification(fromReadyShape matched: MatchedReadyRecognition) -> StagedClassification {
        switch matched.shape {
        case .single(let athleteId, let sportId, let activityType):
            return StagedClassification(
                athleteId: athleteId, sportId: sportId, activityType: activityType,
                isConfirmedReady: matched.isExactMatch, suggestionKind: .exactRemembered
            )
        case .split(let athleteId, let sportId, let children):
            return StagedClassification(
                isConfirmedReady: matched.isExactMatch,
                splitAthleteId: athleteId,
                splitSportId: sportId,
                isSplitEnabled: true,
                splitChildren: children.map {
                    StagedClassification.SplitChild(activityType: $0.activityType, startOffsetMinutes: $0.startOffsetMinutes, durationMinutes: $0.durationMinutes)
                },
                isSuggestedSplitPrefill: true
            )
        }
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

        // Lead Review follow-up (runtime diagnostics — bounded, Alpha-
        // only, NOT a claimed fix): computed ONCE per refresh so the
        // per-item Suggested Split diagnostics below stay silent for the
        // overwhelming common case (this source has no decomposition
        // evidence at all) and only fire when there is genuinely
        // something to explain.
        let hasAnyDecompositionEvidence = (try? calendarPlanningCoordinationService.hasDecompositionEvidence(for: source)) ?? false

        // VX-038 unified recognition follow-up (Part 5/6/10): the
        // TRANSIENT, in-session Ready-evidence index — built from the
        // staging that existed BEFORE this pass, over every event still
        // in `reviewQueue` (an item removed from the queue this pass,
        // e.g. just imported, contributes nothing — its own evidence is
        // durable now, read through the persisted tiers below instead).
        var readyRecognitionIndex = ReadyRecognitionIndex()
        for candidateItem in reviewQueue {
            guard let candidateStaged = stagedClassifications[candidateItem.externalEventKey],
                  let shape = Self.readyRecognitionShape(for: candidateStaged) else { continue }
            let recurringId = candidateItem.event.isRecurring ? candidateItem.event.eventIdentifier : nil
            let normalizedTitle = ExternalEventTitleNormalization.normalize(candidateItem.event.title)
            readyRecognitionIndex.add(recurringId: recurringId, normalizedTitle: normalizedTitle, shape: shape)
        }

        for item in reviewQueue {
            if let existing = stagedClassifications[item.externalEventKey],
               hasMeaningfulStaging(existing, externalEventKey: item.externalEventKey) {
                rebuiltStaging[item.externalEventKey] = existing
                if hasAnyDecompositionEvidence {
                    VoxtrLog.logger(.appShell).info("VX-038 suggestion diagnostic C (meaningful staging already present, not re-evaluated) externalEventKey=\(item.externalEventKey, privacy: .private)")
                }
                continue
            }
            // VX-038 unified recognition follow-up (Part 5/6/10):
            // TRANSIENT Ready evidence from elsewhere in THIS active
            // Review workflow wins ahead of durable evidence — it
            // reflects the Parent's own most current explicit decision.
            // Represents EITHER shape uniformly (single or split).
            // Lead Review follow-up (Blocker 1, PR #56): confirmation
            // status is driven by `MatchedReadyRecognition.isExactMatch`
            // — evidence strength, never shape — so an exact session
            // match arrives ALREADY Ready for BOTH single and split
            // alike (see `stagedClassification(fromReadyShape:)`'s own
            // doc comment). This is a DIFFERENT tier from durable
            // Suggested Split evidence just below, which still never
            // auto-confirms — that tier's own "B remains unconfirmed
            // until the Parent explicitly marks it Ready" contract is
            // unchanged. Either way this branch is read-only; never
            // itself creates or mutates Planning/evidence truth, and the
            // resulting staging is never itself "meaningful"/sticky
            // (`hasMeaningfulStaging` no longer treats `isSplitEnabled`
            // alone as Parent ownership) until the Parent genuinely acts
            // on it.
            if let sessionMatch = Self.sessionReadyShape(for: item.event, index: readyRecognitionIndex) {
                rebuiltStaging[item.externalEventKey] = Self.stagedClassification(fromReadyShape: sessionMatch)
                continue
            }
            // VX-038 (Suggested Split): checked BEFORE exact/similar
            // classification prefill and BEFORE Suggested Ignore —
            // decomposition evidence for this exact event means "this
            // event is actually more than one training unit," which the
            // single-activity classification chain below cannot
            // correctly represent. Never sets isConfirmedReady — like
            // every other suggestion, the Parent's own explicit
            // Ready/import action is still required. Read-only; never
            // creates or mutates anything by itself.
            //
            // Runtime follow-up (shared Athlete/Sport, backward
            // compatibility): `DecompositionEvidenceChild` still stores
            // athleteId/sportId PER CHILD — unchanged, no schema
            // migration — so evidence written before this round (or a
            // rare split whose children genuinely differ) may not agree.
            // A Suggested Split is only ever collapsed into the new
            // shared-context staging when EVERY child agrees on BOTH
            // fields; disagreement is handled conservatively by leaving
            // this event unsuggested (never silently picking one child's
            // values, never partially prefilling), falling through to
            // whatever the next precedence tier below provides.
            if let suggested = try? calendarPlanningCoordinationService.suggestedSplit(for: item.event, source: source),
               !suggested.children.isEmpty {
                let athleteIds = Set(suggested.children.map(\.athleteId))
                let sportIds = Set(suggested.children.map(\.sportId))
                if let sharedAthleteId = athleteIds.first, athleteIds.count == 1, sportIds.count == 1 {
                    rebuiltStaging[item.externalEventKey] = StagedClassification(
                        splitAthleteId: sharedAthleteId,
                        splitSportId: sportIds.first ?? nil,
                        isSplitEnabled: true,
                        splitChildren: suggested.children.map { child in
                            StagedClassification.SplitChild(
                                activityType: child.activityType,
                                startOffsetMinutes: child.startOffsetMinutes, durationMinutes: child.durationMinutes
                            )
                        },
                        isSuggestedSplitPrefill: true
                    )
                    if hasAnyDecompositionEvidence {
                        VoxtrLog.logger(.appShell).info("VX-038 suggestion diagnostic D (applied) externalEventKey=\(item.externalEventKey, privacy: .private) childCount=\(suggested.children.count, privacy: .public)")
                    }
                    continue
                } else if hasAnyDecompositionEvidence {
                    VoxtrLog.logger(.appShell).info("VX-038 suggestion diagnostic B (matched, but children disagree on shared athleteId/sportId) externalEventKey=\(item.externalEventKey, privacy: .private) distinctAthleteCount=\(athleteIds.count, privacy: .public) distinctSportCount=\(sportIds.count, privacy: .public)")
                }
            } else if hasAnyDecompositionEvidence {
                VoxtrLog.logger(.appShell).info("VX-038 suggestion diagnostic A (suggestedSplit returned nil/empty for this event) externalEventKey=\(item.externalEventKey, privacy: .private) isRecurring=\(item.event.isRecurring, privacy: .public)")
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
