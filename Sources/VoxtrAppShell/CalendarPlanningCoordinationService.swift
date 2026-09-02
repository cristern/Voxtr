import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrCalendarPlanningDomain

/// Family-Owned Calendar Sources V1: thrown by source-configuration and
/// review/import methods below — genuine request problems, distinct
/// from a reconciliation outcome (which never throws per-event; see
/// `reconcileAllEnabledSources`).
public enum CalendarPlanningCoordinationError: Error, Sendable, Equatable {
    case athleteNotFound
    case sourceNotFound
    /// V1 product contract: one CONNECTED source per (workspace,
    /// provider, external container) tuple. Never thrown for a
    /// `.disconnected` match — that case reconnects the existing row
    /// instead (see `createSource`'s own doc comment).
    case duplicateSource
    /// `classifyAndImport`/`ignore` guard: this exact external event
    /// already has a decision recorded (defensive — the Import Review
    /// queue should already exclude it), OR that decision's own
    /// `PlannedActivity` no longer resolves (deleted through a path
    /// other than `removeImportedActivities`) — either way, never
    /// silently create a second `PlannedActivity`.
    case alreadyDecided
    /// Lead Review follow-up (Blocker 2): `classifyAndImport` guard — the
    /// source is disabled (or disconnected); stale UI holding an older
    /// `CalendarReviewItem` from before the source was disabled cannot
    /// import through it.
    case sourceDisabled
    /// Lead Review follow-up (Blocker 4): a `PlannedActivity` already
    /// exists for this exact external event identity (a prior Calendar
    /// Planning Source V1 auto-import, or an earlier `classifyAndImport`
    /// whose decision write failed), but its athlete/sport/activityType
    /// does NOT match the Parent's current explicit selection. Never
    /// duplicated, never silently reassigned — the UI must explain that
    /// the existing import needs to be removed/recovered first (see
    /// `removeImportedActivities`) before this event can be reclassified.
    case existingActivityConflict
    /// Lead Review follow-up (family isolation): `classifyAndImport`
    /// guard — `athleteId` resolves to a real athlete, but that athlete's
    /// `workspaceId` does not match `source.workspaceId`. A source
    /// belongs to exactly ONE family (see `ExternalPlanningSource`'s own
    /// doc comment); its events must never become Planning for a
    /// DIFFERENT family's athlete, even if both happen to exist in the
    /// same local store. Deliberately a distinct case from
    /// `athleteNotFound` — the athlete DOES exist, just not in this
    /// source's workspace, which is a genuinely different failure a
    /// caller/UI may want to explain differently.
    case athleteOutsideSourceWorkspace
    /// Calendar Import Review runtime fix: `restoreIgnoredEvent` guard —
    /// a `CalendarImportDecision` exists for this (source,
    /// externalEventKey), but its status is `.imported`, not `.ignored`.
    /// Restoring is a strict reversal of an explicit Ignore only; it
    /// must never delete/undo an actual Planning import — see
    /// `removeImportedActivities(for:removedBy:)` for that separate,
    /// explicit action.
    case decisionNotIgnored
    /// Lead Review follow-up (split semantics): `classifyAndImportSplit`
    /// guard — fewer than 2 children supplied. The ordinary
    /// `classifyAndImport` path already owns one-event →
    /// one-`PlannedActivity`; a split must represent an actual
    /// decomposition into at least two training units, never a
    /// single-child no-op carrying extra provenance rows.
    case splitRequiresAtLeastTwoChildren
    /// Lead Review follow-up (Blocker 2): `classifyAndImportSplit`'s own
    /// existing-decision idempotency check found a decomposed decision
    /// (it has `DecomposedActivityLink` rows) whose link set does NOT
    /// represent a coherent completed split — fewer than 2 links, which
    /// can only mean a prior split attempt was interrupted mid-write.
    /// Never returned as though a subset of the intended children were
    /// a successful import; see `classifyAndImportSplit`'s own
    /// "IDEMPOTENCY / EXISTING-DECISION COHERENCE" doc note.
    case splitProvenanceIncomplete
    /// VX-038: `classifyAndImportSplit` guard — child at `index` has a
    /// duration outside the canonical `1...1440` minute bound Planning
    /// already enforces (`PlanningService.addPlannedActivity`'s own
    /// `plannedDurationMinutes` validation).
    case invalidSplitChildDuration(index: Int)
    /// VX-038: `classifyAndImportSplit` guard — child at `index` has a
    /// negative start offset from the external event's own start; a
    /// child may start AT the event's start (offset `0`) or later, but
    /// never before it — this is a schedule ENVELOPE, not an arbitrary
    /// timeline.
    case invalidSplitChildStartOffset(index: Int)
    /// VX-038: `classifyAndImportSplit` guard — child at `index`'s
    /// `athleteId` does not resolve to a real, active athlete.
    case splitChildAthleteNotFound(index: Int)
    /// VX-038: `classifyAndImportSplit` guard — child at `index`'s
    /// athlete does not belong to `source`'s own workspace — the same
    /// family-isolation boundary `classifyAndImport` already enforces,
    /// checked per child since children may name different athletes.
    case splitChildAthleteOutsideSourceWorkspace(index: Int)
}

/// Family-Owned Calendar Sources V1: the one place
/// `ExternalPlanningSourceRepository`/`CalendarImportDecisionRepository`
/// (Calendar Planning domain), `PlanningService`, `TrainingService`, and
/// `AthleteRepository` are used together — same placement rationale
/// `NotificationsPlanningCoordinationService` already established for
/// its own cross-domain concern. Owns source configuration (create/
/// enable/disable/disconnect), the one-time legacy-mapping migration, the
/// Calendar Import Review queue (discover/classify-and-import/ignore),
/// reconciliation of already-imported events, and safe recovery/cleanup
/// of wrongly-imported activities.
///
/// PRODUCT CONTRACT this type enforces throughout: an external
/// calendar/source PROPOSES schedule facts; Planning remains canonical.
/// A source is a trusted CONTAINER only — it never carries an athlete,
/// Sport, or Activity Type default (see `ExternalPlanningSource`'s own
/// doc comment for why: real evidence showed one calendar can carry
/// multiple children's events). Every event becomes a `PlannedActivity`
/// ONLY through an explicit Parent classification
/// (`classifyAndImport(_:for:athleteId:sportId:activityType:decidedBy:)`)
/// — reconciliation (`reconcile(_:)`) NEVER creates a `PlannedActivity`,
/// it only keeps an ALREADY-classified one's source-owned schedule
/// fields (title/start/duration) up to date. Every mutation below goes
/// through `PlanningService`'s own normal create/edit/delete methods —
/// this type never touches `PlanningRepository` or SwiftData directly,
/// so every existing lifecycle invariant/event fires exactly as it does
/// for a Parent's own manual edit.
///
/// Lead Review follow-up (Blocker 1): every method that lists or creates
/// a source takes an explicit `WorkspaceId` — the same canonical family
/// identity `AthleteRepository.fetchAthletes(forWorkspace:)` already
/// scopes by — never inferred globally. A source (and every
/// `CalendarImportDecision` reachable through it) can never be visible
/// to, or collide with, a different workspace's own source. See
/// `ExternalPlanningSourceRepository`'s own doc comment for the exact
/// scoping boundary.
///
/// Recurring calendar events / occurrence identity: unchanged from
/// Calendar Planning Source V1 — see `ExternalCalendarEventIdentity`
/// (`VoxtrCalendarPlanningDomain`, where this rule now lives) for the
/// exact `(eventIdentifier, occurrenceDate)` rule this type reuses for
/// BOTH `PlannedActivity.externalSourceId` AND
/// `CalendarImportDecision.externalEventKey` — one shared computation,
/// never two divergent copies.
@MainActor
public final class CalendarPlanningCoordinationService {
    /// The generic provenance-pair `type` half stamped on every
    /// `PlannedActivity` this coordinator creates — unchanged from
    /// Calendar Planning Source V1, see
    /// `RecurringPlannedActivity.externalSourceType`'s own doc comment
    /// for why this field is deliberately generic, not EventKit-specific.
    public static let externalSourceType = "calendarPlanningSource"

    /// V1 Alpha reconciliation/review window, in days FORWARD from today
    /// (no historical lookback). Used both by `reconcile(_:)` (updating
    /// already-imported events) and `fetchReviewQueue(for:)` (discovering
    /// new ones) — the same window, since both read the same forward-
    /// looking slice of the source's calendar.
    public static let reconciliationWindowDays = 21

    private let sourceRepository: ExternalPlanningSourceRepository
    private let importDecisionRepository: CalendarImportDecisionRepository
    /// Family-Owned Calendar Sources V1: read-only access to the legacy
    /// Calendar Planning Source V1 mapping table — used ONLY by
    /// `migrateLegacySourcesIfNeeded(forWorkspace:)`. No other method in
    /// this type reads or writes through this repository.
    private let legacyMappingRepository: CalendarPlanningMappingRepository
    /// VX-038: provenance links from a decomposed `CalendarImportDecision`
    /// to each child `PlannedActivity` it produced — see
    /// `DecomposedActivityLink`'s own doc comment. Only
    /// `classifyAndImportSplit(...)` writes through this; the ordinary
    /// one-activity `classifyAndImport(...)` path never touches it.
    private let decomposedActivityLinkRepository: DecomposedActivityLinkRepository
    /// VX-038: durable, reusable evidence of an explicit Parent-approved
    /// split — see `DecompositionEvidence`'s own doc comment. Read by
    /// `suggestedSplit(for:source:)`, written (create-only) by
    /// `classifyAndImportSplit(...)`.
    private let decompositionEvidenceRepository: DecompositionEvidenceRepository
    private let calendarEventProvider: CalendarEventProviding
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let athleteRepository: AthleteRepository
    private let dateProvider: any DateProvider

    public init(
        sourceRepository: ExternalPlanningSourceRepository,
        importDecisionRepository: CalendarImportDecisionRepository,
        legacyMappingRepository: CalendarPlanningMappingRepository,
        decomposedActivityLinkRepository: DecomposedActivityLinkRepository,
        decompositionEvidenceRepository: DecompositionEvidenceRepository,
        calendarEventProvider: CalendarEventProviding,
        planningService: PlanningService,
        trainingService: TrainingService,
        athleteRepository: AthleteRepository,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.sourceRepository = sourceRepository
        self.importDecisionRepository = importDecisionRepository
        self.legacyMappingRepository = legacyMappingRepository
        self.decomposedActivityLinkRepository = decomposedActivityLinkRepository
        self.decompositionEvidenceRepository = decompositionEvidenceRepository
        self.calendarEventProvider = calendarEventProvider
        self.planningService = planningService
        self.trainingService = trainingService
        self.athleteRepository = athleteRepository
        self.dateProvider = dateProvider
    }

    // MARK: - Permission (contextual only — never called at launch)

    public func authorizationStatus(completion: @escaping @MainActor @Sendable (CalendarAuthorizationStatus) -> Void) {
        calendarEventProvider.authorizationStatus(completion: completion)
    }

    public func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        calendarEventProvider.requestAuthorization(completion: completion)
    }

    public func fetchAvailableCalendars() throws -> [AvailableCalendar] {
        try calendarEventProvider.availableCalendars()
    }

    // MARK: - Alpha diagnostic (metadata inspection only)

    /// Calendar V1 metadata inspection: how far forward, and how many
    /// events, the Alpha-only diagnostic surface below reads — smaller
    /// and separate from `reconciliationWindowDays`/no limit, so this
    /// stays a calm, bounded, quick-to-read list rather than a second
    /// import surface. Named, explicit policy, matching this type's own
    /// established "no scattered magic numbers" convention.
    public static let diagnosticEventHorizonDays = 14
    public static let diagnosticEventLimit = 10

    /// Calendar V1 metadata inspection: a small, bounded, READ-ONLY look
    /// at real upcoming events in `calendarIdentifier` — never persisted
    /// anywhere by this method or its caller, never used for identity or
    /// classification, and never itself a Planning mutation. Unchanged
    /// in shape from Calendar Planning Source V1 — takes a plain
    /// `calendarIdentifier` string (the caller passes
    /// `source.externalContainerIdentifier`), so no signature change was
    /// needed for the source-ownership move.
    public func fetchDiagnosticEvents(inCalendar calendarIdentifier: String) throws -> [ExternalCalendarEvent] {
        let now = dateProvider.now
        guard let windowEnd = Calendar(identifier: .gregorian).date(
            byAdding: .day, value: Self.diagnosticEventHorizonDays, to: now
        ) else {
            return []
        }
        let events = try calendarEventProvider.events(inCalendar: calendarIdentifier, from: now, to: windowEnd)
        return Array(events.sorted { $0.startDate < $1.startDate }.prefix(Self.diagnosticEventLimit))
    }

    // MARK: - Source configuration

    /// Every CONNECTED source belonging to `workspaceId` — never another
    /// workspace's, and never a `.disconnected` one (see
    /// `ExternalPlanningSourceRepository.fetchAllConnected(forWorkspace:)`).
    public func fetchSources(forWorkspace workspaceId: WorkspaceId) throws -> [ExternalPlanningSource] {
        try sourceRepository.fetchAllConnected(forWorkspace: workspaceId)
    }

    /// Connects a calendar for `workspaceId`. If this EXACT (workspace,
    /// provider, externalContainerIdentifier) tuple already has a
    /// `.disconnected` row (the Parent disconnected it before, or legacy
    /// migration never created a fresh one because this exact row
    /// already existed), that row is REVIVED — `lifecycleStatus` flips
    /// back to `.connected` and `displayName` is refreshed, but its
    /// stable `ExternalPlanningSourceId` (and every `CalendarImportDecision`
    /// already referencing it) is preserved. Throws `.duplicateSource`
    /// only when a `.connected` row already exists for this tuple —
    /// never for a `.disconnected` one.
    @discardableResult
    public func createSource(
        forWorkspace workspaceId: WorkspaceId,
        providerKind: ExternalPlanningSourceProviderKind,
        externalContainerIdentifier: String,
        displayName: String
    ) throws -> ExternalPlanningSource {
        if let existing = try sourceRepository.fetch(
            forWorkspace: workspaceId, providerKind: providerKind, externalContainerIdentifier: externalContainerIdentifier
        ) {
            guard existing.lifecycleStatus == .disconnected else {
                throw CalendarPlanningCoordinationError.duplicateSource
            }
            try sourceRepository.setLifecycleStatus(existing, .connected, displayName: displayName)
            return existing
        }
        return try sourceRepository.insert(
            workspaceId: workspaceId,
            providerKind: providerKind,
            externalContainerIdentifier: externalContainerIdentifier,
            displayName: displayName
        )
    }

    public func setSourceEnabled(_ sourceId: ExternalPlanningSourceId, isEnabled: Bool) throws {
        guard let source = try sourceRepository.fetch(byId: sourceId) else {
            throw CalendarPlanningCoordinationError.sourceNotFound
        }
        try sourceRepository.setEnabled(source, isEnabled: isEnabled)
    }

    /// Lead Review follow-up (Blocker 3): disconnects the source —
    /// stops future reconciliation/review discovery and removes it from
    /// the normal connected-source list — WITHOUT deleting the row.
    /// Never touches any `PlannedActivity` or `CalendarImportDecision`
    /// already created through it; those remain normal Planning data /
    /// decision history. To also remove what it already imported, see
    /// `removeImportedActivities(for:removedBy:)` below — a deliberately
    /// separate, explicit action, never implied by disconnecting or
    /// disabling. Reconnecting the SAME (workspace, provider, container)
    /// tuple later reuses this exact row (see `createSource`'s own doc
    /// comment) — the stable ID and every decision referencing it
    /// survive the round trip.
    public func disconnectSource(_ sourceId: ExternalPlanningSourceId) throws {
        guard let source = try sourceRepository.fetch(byId: sourceId) else { return }
        try sourceRepository.setLifecycleStatus(source, .disconnected)
    }

    // MARK: - Legacy migration (Calendar Planning Source V1 -> Family-Owned Calendar Sources V1)

    /// Family-Owned Calendar Sources V1: the smallest SAFE migration
    /// from the retired, athlete-scoped `CalendarPlanningMapping` model
    /// to the new family-owned `ExternalPlanningSource` model —
    /// deliberately ordinary, testable APPLICATION code, never a
    /// SwiftData `.custom` migration stage (see `AppSchemaVersioning.swift`'s
    /// own documented history of `.custom`-migration/legacy-type
    /// crashes for why that pattern is avoided here).
    ///
    /// For every DISTINCT `calendarIdentifier` found among existing
    /// `CalendarPlanningMapping` rows WHOSE OWNING ATHLETE BELONGS TO
    /// `workspaceId` (resolved via `AthleteRepository.fetchAthlete(byId:)`
    /// — `CalendarPlanningMapping` itself carries no workspace field of
    /// its own, only `athleteId`), creates a new `ExternalPlanningSource`
    /// for THIS workspace — disabled by default, same "Parent must
    /// explicitly enable" contract every new source already has —
    /// UNLESS a source for that exact (workspace, provider, container)
    /// tuple already exists, CONNECTED or `.disconnected` (idempotent:
    /// safe to call on every launch/screen load, a no-op after the first
    /// successful run; and — Lead Review follow-up, Blocker 3 — a
    /// Parent-disconnected source is NEVER resurrected as a new row,
    /// since `ExternalPlanningSourceRepository.fetch(forWorkspace:providerKind:externalContainerIdentifier:)`
    /// deliberately matches `.disconnected` rows too, not only
    /// `.connected` ones).
    ///
    /// Lead Review follow-up (Blocker 1): a legacy mapping whose athlete
    /// belongs to a DIFFERENT workspace is simply never considered by
    /// this call — a second call with that OTHER workspace's ID creates
    /// its own, separate `ExternalPlanningSource`, even if both legacy
    /// mappings happen to share the same `calendarIdentifier` string.
    /// Two workspaces' calendars sharing an identifier by coincidence
    /// must never collapse into one cross-family source.
    ///
    /// Deliberately does NOT read `CalendarPlanningMapping.athleteId`/
    /// `.sportId`/`.activityType` for anything beyond resolving the
    /// OWNING WORKSPACE — those legacy per-mapping classification
    /// defaults are dropped, never carried forward as a classification
    /// rule, matching this round's own explicit contract: "do not
    /// silently reinterpret an old athlete mapping as a permanent
    /// event-classification rule." No `CalendarImportDecision` is ever
    /// created here, and no `PlannedActivity` is ever created or touched
    /// here — this method's ONLY effect is seeding `ExternalPlanningSource`
    /// container rows so a Parent doesn't have to remember and manually
    /// reconnect a calendar they already connected once.
    @discardableResult
    public func migrateLegacySourcesIfNeeded(forWorkspace workspaceId: WorkspaceId) throws -> [ExternalPlanningSource] {
        let legacyMappings = try legacyMappingRepository.fetchAll()
        guard !legacyMappings.isEmpty else { return [] }

        var seenCalendarIdentifiers: [String: String] = [:]
        for mapping in legacyMappings {
            guard seenCalendarIdentifiers[mapping.calendarIdentifier] == nil else { continue }
            guard let owningAthlete = try athleteRepository.fetchAthlete(byId: AthleteId(rawValue: mapping.athleteId)),
                  owningAthlete.workspaceId == workspaceId.rawValue else {
                continue
            }
            seenCalendarIdentifiers[mapping.calendarIdentifier] = mapping.calendarTitle
        }

        var created: [ExternalPlanningSource] = []
        for (calendarIdentifier, calendarTitle) in seenCalendarIdentifiers.sorted(by: { $0.key < $1.key }) {
            guard try sourceRepository.fetch(
                forWorkspace: workspaceId, providerKind: .eventKit, externalContainerIdentifier: calendarIdentifier
            ) == nil else { continue }
            let source = try sourceRepository.insert(
                workspaceId: workspaceId,
                providerKind: .eventKit,
                externalContainerIdentifier: calendarIdentifier,
                displayName: calendarTitle
            )
            created.append(source)
        }
        return created
    }

    // MARK: - Calendar Import Review (discover / classify-and-import / ignore)

    /// Family-Owned Calendar Sources V1: one candidate external event
    /// awaiting an explicit Parent decision — never persisted itself
    /// (see `CalendarImportDecisionStatus`'s own doc comment: "pending"
    /// is represented purely by the ABSENCE of a `CalendarImportDecision`
    /// row, not a stored state).
    public struct CalendarReviewItem: Sendable, Equatable {
        public let event: ExternalCalendarEvent
        /// The exact same stable identity that will become
        /// `PlannedActivity.externalSourceId` if this item is imported,
        /// and `CalendarImportDecision.externalEventKey` either way.
        public let externalEventKey: String
    }

    /// Every event in `source`'s calendar, within the reconciliation
    /// window, that has NO existing `CalendarImportDecision` yet (never
    /// imported, never ignored) — the actual Calendar Import Review
    /// queue. All-day events are excluded, same rule
    /// `reconcile(_:)` already applies (no meaningful start TIME to plan
    /// around). Sorted by start time.
    ///
    /// Lead Review follow-up (Blocker 2): a disabled (or disconnected)
    /// source can never produce a review queue — enforced HERE, at the
    /// canonical service boundary, not only by hiding the Review row in
    /// the UI. Returns `[]` immediately, before ever calling the
    /// calendar provider or reading decisions.
    ///
    /// Unchanged pending semantics (Calendar Import Review runtime fix:
    /// this method's own contract is deliberately untouched) — reuses
    /// `qualifyingEvents(for:)` below, the SAME window/all-day-exclusion/
    /// disabled-source guard `fetchIgnoredReviewItems(for:)` also shares,
    /// so there is exactly one place that logic lives, never two
    /// divergent copies.
    public func fetchReviewQueue(for source: ExternalPlanningSource) throws -> [CalendarReviewItem] {
        let qualifying = try qualifyingEvents(for: source)
        guard !qualifying.isEmpty else { return [] }

        let decided = try importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId)
        let decidedKeys = Set(decided.map(\.externalEventKey))

        let pending = qualifying.compactMap { event -> CalendarReviewItem? in
            let key = ExternalCalendarEventIdentity.externalSourceId(calendarIdentifier: source.externalContainerIdentifier, event: event)
            guard !decidedKeys.contains(key) else { return nil }
            return CalendarReviewItem(event: event, externalEventKey: key)
        }
        return pending.sorted { $0.event.startDate < $1.event.startDate }
    }

    /// Calendar Import Review runtime fix: every event STILL within the
    /// current external provider horizon (same window/all-day-exclusion/
    /// disabled-source guard as `fetchReviewQueue(for:)`) whose
    /// `CalendarImportDecision` for this source is `.ignored` — the
    /// Ignored section's own read model. Deliberately does NOT read a
    /// stale decision row whose external event has since fallen outside
    /// the current window/disappeared from the source — this is a
    /// current-horizon view, never a historical decision log, and it
    /// never infers/fabricates external event content from an old
    /// decision.
    public func fetchIgnoredReviewItems(for source: ExternalPlanningSource) throws -> [CalendarReviewItem] {
        let qualifying = try qualifyingEvents(for: source)
        guard !qualifying.isEmpty else { return [] }

        let decided = try importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId)
        let ignoredKeys = Set(decided.filter { $0.status == .ignored }.map(\.externalEventKey))
        guard !ignoredKeys.isEmpty else { return [] }

        let ignored = qualifying.compactMap { event -> CalendarReviewItem? in
            let key = ExternalCalendarEventIdentity.externalSourceId(calendarIdentifier: source.externalContainerIdentifier, event: event)
            guard ignoredKeys.contains(key) else { return nil }
            return CalendarReviewItem(event: event, externalEventKey: key)
        }
        return ignored.sorted { $0.event.startDate < $1.event.startDate }
    }

    /// PR #48 follow-up (durable Suggested Ignore evidence): every
    /// ORIGINAL (non-normalized) title the Parent has explicitly ignored
    /// for THIS `source` — ever, regardless of whether the exact ignored
    /// external event is still resolvable within the current provider
    /// reconciliation horizon. Deliberately UNBOUNDED and separate from
    /// `fetchIgnoredReviewItems(for:)` above: that method stays
    /// horizon-bound because it needs a currently-resolvable
    /// `ExternalCalendarEvent` to display/reverse in the Ignored section;
    /// this method exists purely as historical matching evidence for
    /// `ExternalEventTitleSimilarity.suggestedIgnoreMatch(forEventTitle:amongPreviouslyIgnoredTitles:)`,
    /// so a repeating event the Parent already ignored keeps being
    /// recognized as Suggested Ignore even after the original occurrence
    /// ages out of the provider's own window. These are different read
    /// purposes and must not be conflated.
    ///
    /// Scoped to THIS `source` only (never another source, never another
    /// workspace — matching never generalizes across calendars/providers/
    /// families, exactly like `historicalTitleClassifications(for:)`).
    /// Only `.ignored` decisions with a non-nil `ignoredEventTitle`
    /// contribute — `.imported` decisions carry no `ignoredEventTitle`
    /// and are never evidence here. A decision deleted via
    /// `restoreIgnoredEvent(_:for:)` ("Review again") naturally stops
    /// contributing, since its `ignoredEventTitle` lived on that same
    /// now-deleted row.
    ///
    /// Never creates, mutates, or persists anything — a pure read. The
    /// caller (`CalendarImportReviewViewModel`) only ever uses this to
    /// PROPOSE a new event as Suggested Ignore for Parent review; it is
    /// never used to automatically create a `CalendarImportDecision`.
    public func historicalIgnoredTitles(for source: ExternalPlanningSource) throws -> [String] {
        try importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId)
            .filter { $0.status == .ignored }
            .compactMap(\.ignoredEventTitle)
    }

    /// Shared by `fetchReviewQueue(for:)` and `fetchIgnoredReviewItems(for:)`:
    /// every all-day-excluded event in `source`'s calendar within the
    /// reconciliation window, or `[]` immediately (never calling the
    /// calendar provider) for a disabled/disconnected source.
    private func qualifyingEvents(for source: ExternalPlanningSource) throws -> [ExternalCalendarEvent] {
        guard source.isEnabled, source.lifecycleStatus == .connected else { return [] }

        let now = dateProvider.now
        guard let windowEnd = Calendar(identifier: .gregorian).date(
            byAdding: .day, value: Self.reconciliationWindowDays, to: now
        ) else {
            return []
        }
        let events = try calendarEventProvider.events(inCalendar: source.externalContainerIdentifier, from: now, to: windowEnd)
        return events.filter { !$0.isAllDay }
    }

    // MARK: - Remembered Exact Choices (V1.1) + Similar-Event Suggestions (V1.2) — prefill only, never auto-import

    /// Calendar Import Review V1.1: a Parent-approved classification this
    /// EXACT `source` has used before for an external event whose
    /// normalized title matches — see `rememberedClassifications(for:)`'s
    /// own doc comment for the full algorithm. Presentation assistance
    /// ONLY: a caller may use this to PREFILL a still-`Ready`, still-
    /// unpersisted staging value; it is never itself imported, and never
    /// bypasses `classifyAndImport`'s own canonical guards.
    public struct RememberedClassification: Sendable, Equatable {
        public let athleteId: AthleteId
        public let sportId: SportId?
        public let activityType: ActivityType
    }

    /// Builds the exact-title remembered-classification candidates for
    /// ONE source, from EXISTING persisted truth only — no new
    /// preference/rule entity. Source data:
    ///   - every `CalendarImportDecision(status: .imported)` already
    ///     recorded for THIS `source` (never another source — see this
    ///     type's own "SOURCE SCOPE" contract: matching does not
    ///     generalize across calendars/providers in V1.1). A decision is
    ///     immutable once created (see `CalendarImportDecisionRepository`'s
    ///     own doc comment), so its `athleteId`/`sportId`/`activityType`
    ///     is exactly the Parent's own original explicit choice, never a
    ///     value that could have silently drifted from a later manual
    ///     Planning edit;
    ///   - the linked `PlannedActivity.title` — the actual imported
    ///     event's title, normalized via `ExternalEventTitleNormalization.normalize(_:)`.
    ///
    /// AMBIGUITY RULE: if the SAME normalized title has been explicitly
    /// imported before with more than one DISTINCT (athlete, sport,
    /// activity type) combination, NO candidate is produced for that
    /// title at all — human judgement wins over guessing; a remembered
    /// prefill is only ever produced when every prior explicit import of
    /// that exact normalized title agrees.
    ///
    /// WORKSPACE/PRIVACY: a candidate is discarded (never returned) if
    /// its remembered athlete no longer resolves, is archived, or no
    /// longer belongs to THIS `source`'s own `workspaceId` — a remembered
    /// choice must never cross a workspace boundary, and an archived/
    /// missing athlete must never be silently prefilled; the caller is
    /// left with an event that still requires normal Parent review.
    ///
    /// Never creates, mutates, or persists anything — a pure read.
    /// Implemented in terms of `historicalTitleClassifications(for:)`
    /// below (V1.2), which now owns the actual candidate derivation —
    /// this method's own return type/behavior is otherwise byte-for-byte
    /// unchanged from V1.1: same source, same `.imported`-only evidence,
    /// same per-title ambiguity/archived/workspace guards, keyed the
    /// same way.
    public func rememberedClassifications(for source: ExternalPlanningSource) throws -> [String: RememberedClassification] {
        var result: [String: RememberedClassification] = [:]
        for historical in try historicalTitleClassifications(for: source) {
            result[historical.normalizedTitle] = RememberedClassification(
                athleteId: historical.athleteId, sportId: historical.sportId, activityType: historical.activityType
            )
        }
        return result
    }

    /// Calendar Import Review V1.2 (Similar-Event Suggestions): every
    /// PRIOR distinct normalized title's own unambiguous historical
    /// classification for `source` — the shared evidence BOTH exact
    /// remembering (`rememberedClassifications(for:)` above, unchanged
    /// behavior) and similar-event suggestion
    /// (`ExternalEventTitleSimilarity.suggestedMatch(forEventTitle:among:)`,
    /// a pure domain function this method's result directly feeds) are
    /// built from — one single place this candidate derivation and its
    /// source/workspace/ambiguity boundaries live, never duplicated.
    ///
    /// EVIDENCE SOURCE (identical to V1.1's own, now factored out here):
    ///   - every `CalendarImportDecision(status: .imported)` already
    ///     recorded for THIS `source` (never another source, never
    ///     another workspace — matching never generalizes across
    ///     calendars/providers/families). Ignored decisions, staged-only
    ///     Ready state, manually-created `PlannedActivity` rows with no
    ///     import decision, and failed import attempts are never
    ///     evidence — only a persisted `.imported` decision with a
    ///     STILL-RESOLVING linked `PlannedActivity` qualifies;
    ///   - that `PlannedActivity.title`, normalized via
    ///     `ExternalEventTitleNormalization.normalize(_:)`, plus the raw
    ///     (non-normalized) title, kept only for a caller's own "Based
    ///     on: <title>" display — never used for matching.
    ///
    /// AMBIGUITY RULE (unchanged from V1.1): if the SAME normalized
    /// title has been explicitly imported before with more than one
    /// DISTINCT (athlete, sport, activityType) combination, NO
    /// candidate is produced for that title at all — human judgement
    /// wins over guessing. Similar-event suggestion applies this SAME
    /// rule a second time, across the SET of similar (not identical)
    /// titles a caller matches against this result — see
    /// `ExternalEventTitleSimilarity.suggestedMatch(forEventTitle:among:)`'s
    /// own doc comment.
    ///
    /// WORKSPACE/PRIVACY (unchanged from V1.1): a candidate is discarded
    /// if its remembered athlete no longer resolves, is archived, or no
    /// longer belongs to THIS `source`'s own `workspaceId`.
    ///
    /// Lead Review follow-up (Blocker 1): a decomposed decision (one
    /// carrying `DecomposedActivityLink` rows — see
    /// `plannedActivityIds(for:)`'s own doc comment) is EXCLUDED here,
    /// even though it still carries `athleteId`/`sportId`/`activityType`/
    /// `plannedActivityId` mirroring its first child (see
    /// `classifyAndImportSplit`'s own doc comment for why that mirroring
    /// exists at all — provenance/idempotency bookkeeping, never a
    /// single-activity classification claim). Those mirrored fields must
    /// never surface as remembered/exact/similar single-activity
    /// classification evidence for the event's title: "Hockey training"
    /// having once been explicitly split into "Off-ice" + "Hockey" must
    /// never make "Off-ice" the remembered choice for a later plain
    /// "Hockey training" import. `DecompositionEvidence` (see
    /// `suggestedSplit(for:source:)`) is the ONE canonical historical
    /// record for a split event's title — this method's own single-
    /// activity evidence pool must never duplicate or contradict it.
    ///
    /// Never creates, mutates, or persists anything — a pure read.
    public func historicalTitleClassifications(for source: ExternalPlanningSource) throws -> [HistoricalTitleClassification] {
        let importedDecisions = try importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId)
            .filter { $0.status == .imported }
        guard !importedDecisions.isEmpty else { return [] }

        struct Candidate: Hashable {
            let athleteId: UUID
            let sportId: UUID?
            let activityType: ActivityType
        }

        var candidatesByTitle: [String: Set<Candidate>] = [:]
        var originalTitleByNormalizedTitle: [String: String] = [:]
        for decision in importedDecisions {
            guard try decomposedActivityLinkRepository.fetchAll(forDecision: decision.calendarImportDecisionId).isEmpty else {
                continue
            }
            guard let plannedActivityId = decision.plannedActivityId,
                  let activity = try planningService.fetchPlannedActivity(byId: PlannedActivityId(rawValue: plannedActivityId)),
                  let rawTitle = activity.title,
                  let normalizedTitle = ExternalEventTitleNormalization.normalize(rawTitle),
                  let decisionAthleteId = decision.athleteId,
                  let decisionActivityType = decision.activityType else {
                continue
            }
            let candidate = Candidate(athleteId: decisionAthleteId, sportId: decision.sportId, activityType: decisionActivityType)
            candidatesByTitle[normalizedTitle, default: []].insert(candidate)
            originalTitleByNormalizedTitle[normalizedTitle] = rawTitle
        }

        var result: [HistoricalTitleClassification] = []
        for (normalizedTitle, candidates) in candidatesByTitle {
            // Ambiguity rule: more than one distinct prior classification
            // for this exact normalized title -> no candidate at all.
            guard candidates.count == 1, let onlyCandidate = candidates.first else { continue }
            guard let athlete = try athleteRepository.fetchAthlete(byId: AthleteId(rawValue: onlyCandidate.athleteId)),
                  !athlete.isArchived,
                  athlete.workspaceId == source.workspaceId else {
                continue
            }
            result.append(HistoricalTitleClassification(
                normalizedTitle: normalizedTitle,
                originalTitle: originalTitleByNormalizedTitle[normalizedTitle] ?? normalizedTitle,
                athleteId: athlete.athleteId,
                sportId: onlyCandidate.sportId.map { SportId(rawValue: $0) },
                activityType: onlyCandidate.activityType
            ))
        }
        return result
    }

    /// The explicit Parent action Calendar Import Review exists for:
    /// creates (or safely adopts an existing, matching) canonical
    /// `PlannedActivity` for `item`, with the Parent-approved
    /// `athleteId`/`sportId`/`activityType` — never a source-level
    /// default, since `ExternalPlanningSource` carries none.
    ///
    /// Lead Review follow-up (Blocker 2): throws `.sourceDisabled` if
    /// `source` is disabled or disconnected — stale UI holding an older
    /// `CalendarReviewItem` from before the source was disabled cannot
    /// import through it.
    ///
    /// Lead Review follow-up (Blocker 4): resolved in three steps, in
    /// order, so a retry after any partial failure is always safe and
    /// never duplicates:
    ///   1. an existing `CalendarImportDecision` for this exact
    ///      `externalEventKey` — if `.imported` and its `PlannedActivity`
    ///      still resolves, returns it UNCHANGED (idempotent repeat
    ///      call); if that `PlannedActivity` no longer resolves (deleted
    ///      through some other path) or the decision is `.ignored`,
    ///      throws `.alreadyDecided` rather than silently creating a
    ///      replacement;
    ///   2. no decision yet, but a `PlannedActivity` already carries this
    ///      exact `externalSourceId` (a Calendar Planning Source V1
    ///      legacy auto-import, OR this exact call having created the
    ///      activity on a prior attempt whose decision write then
    ///      failed) — if its athlete/sport/activityType EXACTLY matches
    ///      the Parent's current explicit selection, ADOPTS it (creates
    ///      only the missing `CalendarImportDecision`, no new activity);
    ///      if it does NOT match, throws `.existingActivityConflict` —
    ///      never duplicated, never silently reassigned to a different
    ///      athlete;
    ///   3. genuinely new — creates the `PlannedActivity` and its
    ///      `CalendarImportDecision` through the normal path.
    /// This lookup never reads `CalendarPlanningMapping` — the legacy
    /// athlete/sport/activityType DEFAULTS never become a classification
    /// rule here; only the Parent's OWN current explicit selection is
    /// ever compared against.
    @discardableResult
    public func classifyAndImport(
        _ item: CalendarReviewItem,
        for source: ExternalPlanningSource,
        athleteId: AthleteId,
        sportId: SportId?,
        activityType: ActivityType,
        decidedBy: ActorId
    ) throws -> PlannedActivity {
        guard source.isEnabled, source.lifecycleStatus == .connected else {
            throw CalendarPlanningCoordinationError.sourceDisabled
        }

        // Step 1: an existing decision for this exact event.
        //
        // Lead Review follow-up (Blocker 2, bounded-audit finding —
        // documented, not fixed, deliberately out of this fix's scope):
        // this read trusts `existingDecision.plannedActivityId` directly
        // and does NOT check for `DecomposedActivityLink` rows. If this
        // method were ever called for an `externalEventKey` that
        // already has a DECOMPOSED decision, it would silently return
        // only that decision's mirrored FIRST child, never surfacing the
        // other children. This is currently UNREACHABLE in production:
        // `fetchReviewQueue(for:)` excludes any event with an existing
        // decision (of either kind) from the pending queue, and this
        // method's only call site (`CalendarImportReviewViewModel.bulkImportReadyItems()`)
        // only ever calls it for items still in that queue — so a
        // decomposed decision can never reach this branch through the
        // approved UI flow. `classifyAndImport` is intentionally
        // UNCHANGED by VX-038 (contract item 2: the ordinary path stays
        // the untouched default fast path) — closing this theoretical
        // gap would mean adding decomposition awareness to a method this
        // feature explicitly promised not to modify, so it is reported
        // here rather than fixed.
        if let existingDecision = try importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey) {
            guard existingDecision.status == .imported, let plannedActivityId = existingDecision.plannedActivityId,
                  let plannedActivity = try planningService.fetchPlannedActivity(byId: PlannedActivityId(rawValue: plannedActivityId)) else {
                throw CalendarPlanningCoordinationError.alreadyDecided
            }
            return plannedActivity
        }

        guard let athlete = try athleteRepository.fetchAthlete(byId: athleteId) else {
            throw CalendarPlanningCoordinationError.athleteNotFound
        }

        // Lead Review follow-up (family isolation): `athlete` exists, but
        // must belong to THIS source's own workspace — checked before
        // Step 2's existing-activity lookup below, so a legacy/existing
        // activity from a DIFFERENT workspace can never be adopted just
        // because its external event key happens to match, and no
        // PlannedActivity/CalendarImportDecision is created or mutated
        // for a cross-workspace request.
        guard athlete.workspaceId == source.workspaceId else {
            throw CalendarPlanningCoordinationError.athleteOutsideSourceWorkspace
        }

        // Step 2: an existing PlannedActivity with this exact external
        // identity but no decision yet (legacy V1 import, or a prior
        // partially-failed classifyAndImport).
        let existingActivities = try planningService.fetchPlannedActivities(externalSourceType: Self.externalSourceType)
        if let existingActivity = existingActivities.first(where: { $0.externalSourceId == item.externalEventKey }) {
            guard existingActivity.athleteId == athleteId.rawValue,
                  existingActivity.sportId == sportId?.rawValue,
                  existingActivity.activityType == activityType else {
                throw CalendarPlanningCoordinationError.existingActivityConflict
            }
            try importDecisionRepository.insert(
                sourceId: source.externalPlanningSourceId,
                externalEventKey: item.externalEventKey,
                status: .imported,
                athleteId: athleteId,
                sportId: sportId,
                activityType: activityType,
                plannedActivityId: existingActivity.plannedActivityId,
                decidedBy: decidedBy
            )
            return existingActivity
        }

        // Step 3: genuinely new.
        let (localDate, startLocalTime) = Self.localDateAndTime(for: item.event.startDate, in: athlete.timeZoneId)
        let durationMinutes = Self.durationMinutes(start: item.event.startDate, end: item.event.endDate)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: localDate.startOfWeek)
        let plannedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: activityType,
            title: item.event.title,
            localDate: localDate,
            timeZoneId: athlete.timeZoneId,
            sportId: sportId,
            startLocalTime: startLocalTime,
            plannedDurationMinutes: durationMinutes,
            externalSourceId: item.externalEventKey,
            externalSourceType: Self.externalSourceType,
            // Creation-time preservation only: the external event owns
            // this Vǫxtr row's schedule context at the moment of import,
            // exactly as supplied by the provider — never fabricated,
            // trimmed, or rewritten. Step 2's adoption path above and
            // `applyReconciledEvent`'s own reconciliation UPDATE
            // deliberately do NOT do this (see their own doc comments) —
            // this is the ONE place notes/location are ever seeded from
            // an `ExternalCalendarEvent`.
            notes: item.event.notes,
            location: item.event.location
        )

        try importDecisionRepository.insert(
            sourceId: source.externalPlanningSourceId,
            externalEventKey: item.externalEventKey,
            status: .imported,
            athleteId: athleteId,
            sportId: sportId,
            activityType: activityType,
            plannedActivityId: plannedActivity.plannedActivityId,
            decidedBy: decidedBy
        )
        return plannedActivity
    }

    // MARK: - VX-038: External Event Decomposition / Suggested Split

    /// Every `PlannedActivityId` a `CalendarImportDecision` produced —
    /// the ONE read helper that makes a historical, ordinary 1:1
    /// decision (no `DecomposedActivityLink` rows) and a new decomposed
    /// decision (N link rows, written by `classifyAndImportSplit`)
    /// resolve identically, so a caller never needs to know which kind
    /// of decision it is holding. `[]` for an `.ignored` decision (its
    /// `plannedActivityId` is always `nil`).
    public func plannedActivityIds(for decision: CalendarImportDecision) throws -> [PlannedActivityId] {
        let links = try decomposedActivityLinkRepository.fetchAll(forDecision: decision.calendarImportDecisionId)
        guard links.isEmpty else {
            return links.map { PlannedActivityId(rawValue: $0.plannedActivityId) }
        }
        guard let plannedActivityId = decision.plannedActivityId else { return [] }
        return [PlannedActivityId(rawValue: plannedActivityId)]
    }

    /// VX-038: ONE child's Parent-approved shape for
    /// `classifyAndImportSplit(_:for:children:decidedBy:)` — the same
    /// canonical value types (`AthleteId`/`SportId`/`ActivityType`)
    /// every other Planning write already uses; never a second,
    /// locally-invented representation.
    public struct DecomposedChildInput: Sendable, Equatable {
        public let athleteId: AthleteId
        public let sportId: SportId?
        public let activityType: ActivityType
        /// Minutes from the external event's own start — `0` means "at
        /// the event's start," matching the approved contract's own
        /// example (`offset 0 min` / `offset 70 min`).
        public let startOffsetMinutes: Int
        public let durationMinutes: Int

        public init(athleteId: AthleteId, sportId: SportId?, activityType: ActivityType, startOffsetMinutes: Int, durationMinutes: Int) {
            self.athleteId = athleteId
            self.sportId = sportId
            self.activityType = activityType
            self.startOffsetMinutes = startOffsetMinutes
            self.durationMinutes = durationMinutes
        }
    }

    /// The explicit Parent action for "this external event is actually
    /// several training units" — creates one canonical `PlannedActivity`
    /// PER `children` entry, all sharing `item`'s own
    /// `externalEventKey`/provenance, plus ONE `CalendarImportDecision`
    /// linking every child via `DecomposedActivityLink` (see that type's
    /// own doc comment). Never a bypass of `classifyAndImport`'s own
    /// guards — this is a SEPARATE, parallel creation path for the
    /// SEPARATE case of more than one training unit, reusing the exact
    /// same source-disabled/idempotency/family-isolation checks.
    ///
    /// Lead Review follow-up (split semantics — minimum two children):
    /// the ordinary `classifyAndImport` path already owns one-event →
    /// one-`PlannedActivity`; "Split activity" must represent an actual
    /// decomposition, never a one-child no-op with extra provenance
    /// rows. `children.count < 2` throws
    /// `.splitRequiresAtLeastTwoChildren` before any other validation
    /// runs.
    ///
    /// VALIDATION (all children checked BEFORE any `PlannedActivity` is
    /// created — see this method's own "CORE CONSISTENCY" note below):
    ///   - at least two children (`.splitRequiresAtLeastTwoChildren`);
    ///   - each child's `durationMinutes` in `1...1440`
    ///     (`.invalidSplitChildDuration`) — the same bound
    ///     `PlanningService.addPlannedActivity` itself enforces;
    ///   - each child's `startOffsetMinutes >= 0`
    ///     (`.invalidSplitChildStartOffset`) — a child may start AT the
    ///     external event's own start or later, never before it;
    ///   - each child's athlete resolves, is active, and belongs to
    ///     `source`'s own workspace (`.splitChildAthleteNotFound`/
    ///     `.splitChildAthleteOutsideSourceWorkspace`) — the same
    ///     family-isolation boundary `classifyAndImport` already
    ///     enforces, checked per child since children may name
    ///     different athletes.
    /// Children are never required to be contiguous or to fill the
    /// entire external event — only the bounds above are enforced,
    /// matching `PlanningService`'s own existing timing constraints
    /// rather than inventing a stricter rule here.
    ///
    /// IDEMPOTENCY / EXISTING-DECISION COHERENCE (Lead Review follow-up,
    /// Blocker 2): mirrors `classifyAndImport`'s own Step 1 — an existing
    /// decision for this exact `externalEventKey` returns its already-
    /// linked activities unchanged rather than creating a duplicate
    /// split, but ONLY after proving that decision's own link set is a
    /// COHERENT completed split, never a subset a caller could mistake
    /// for success:
    ///   - zero `DecomposedActivityLink` rows: this is an ORDINARY
    ///     (non-split) decision already occupying this exact
    ///     `externalEventKey` — falls through to the same
    ///     `.alreadyDecided` guard `classifyAndImport` itself throws for
    ///     a conflicting prior decision, never silently reinterpreted as
    ///     a 1-child split;
    ///   - `1` link row: structurally CANNOT be a valid completed split
    ///     (the minimum is 2 — see above) — this can only mean a PRIOR
    ///     `classifyAndImportSplit` call was interrupted between writing
    ///     its decision/first link and this fix's own rollback existing
    ///     (or, before this fix, having no rollback at all for that
    ///     window). Throws `.splitProvenanceIncomplete` rather than
    ///     returning that one activity as though the split succeeded —
    ///     a caller must never receive a subset as success;
    ///   - `>= 2` link rows, but fewer resolve to a still-existing
    ///     `PlannedActivity` than there are links (one was deleted
    ///     through some other path): the SAME `.alreadyDecided` guard
    ///     `classifyAndImport` uses for its own equivalent case — a
    ///     decision that no longer cleanly resolves is never silently
    ///     "fixed" by creating replacements;
    ///   - `>= 2` link rows, all resolving cleanly: genuinely idempotent
    ///     — returns every linked `PlannedActivity`, in order, unchanged.
    ///
    /// CORE CONSISTENCY (Lead Review follow-up, Blocker 2): this
    /// repository layer has no cross-write SwiftData transaction (see
    /// `ExternalPlanningSourceRepository`/`CalendarImportDecisionRepository`'s
    /// own `save()`-per-call pattern — unchanged by this feature), so
    /// the CORE durable result — every intended `PlannedActivity`, ONE
    /// `CalendarImportDecision`, and ONE `DecomposedActivityLink` per
    /// child — is made all-or-nothing from the caller's perspective by
    /// explicit, ordered rollback rather than a real transaction:
    ///   1. every child is validated BEFORE any `PlannedActivity` is
    ///      created, so the common failure mode (bad input) is caught
    ///      with zero partial state;
    ///   2. `PlannedActivity` creation, the `CalendarImportDecision`
    ///      insert, and every `DecomposedActivityLink` insert all run
    ///      inside ONE `do` block. On ANY failure in that block — a
    ///      `PlannedActivity` creation failing partway through, the
    ///      decision insert failing, or a link insert failing partway
    ///      through — the `catch` unwinds EVERYTHING already durably
    ///      written in this same call, in reverse order: any
    ///      already-inserted `DecomposedActivityLink` rows for the
    ///      (possibly-created) decision, the decision itself if it was
    ///      created, then every already-created `PlannedActivity`. A
    ///      rollback delete failing (defensive, not expected) is
    ///      swallowed for that one row rather than masking the original
    ///      failure — this is a best-effort bounded rollback, not a
    ///      database-level transaction, and is explicitly documented as
    ///      such rather than hidden.
    /// A retry after ANY failure in step 2 therefore finds NO decision
    /// at all for this `externalEventKey` (never a partial one) and
    /// proceeds as a genuinely fresh split attempt.
    ///
    /// EVIDENCE (Lead Review follow-up: Planning truth first, learning
    /// evidence is assistance): `DecompositionEvidence` persistence is
    /// explicitly OUTSIDE the core atomic scope above — it runs only
    /// AFTER every `PlannedActivity`/`CalendarImportDecision`/
    /// `DecomposedActivityLink` write has already durably succeeded, and
    /// its own failure is swallowed (`try?`) rather than propagated: the
    /// Parent's split import is already fully, correctly committed to
    /// Planning at that point, and a caller must never receive an error
    /// claiming the import failed when it did not. The cost is that a
    /// failed evidence write silently forfeits a future Suggested Split
    /// for this exact split (never a correctness problem for the
    /// import itself, and never observable as a partial import) — see
    /// `recordDecompositionEvidenceIfAbsent(...)`'s own doc comment for
    /// why the write itself is also create-only, never a silent
    /// overwrite of a previously-learned pattern.
    @discardableResult
    public func classifyAndImportSplit(
        _ item: CalendarReviewItem,
        for source: ExternalPlanningSource,
        children: [DecomposedChildInput],
        decidedBy: ActorId
    ) throws -> [PlannedActivity] {
        guard source.isEnabled, source.lifecycleStatus == .connected else {
            throw CalendarPlanningCoordinationError.sourceDisabled
        }
        guard children.count >= 2 else {
            throw CalendarPlanningCoordinationError.splitRequiresAtLeastTwoChildren
        }

        if let existingDecision = try importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey) {
            guard existingDecision.status == .imported else {
                throw CalendarPlanningCoordinationError.alreadyDecided
            }
            let existingLinks = try decomposedActivityLinkRepository.fetchAll(forDecision: existingDecision.calendarImportDecisionId)
            guard !existingLinks.isEmpty else {
                // An ORDINARY (non-split) decision already occupies this
                // key — never silently reinterpreted as a 1-child split.
                throw CalendarPlanningCoordinationError.alreadyDecided
            }
            guard existingLinks.count >= 2 else {
                // Structurally incomplete — see this method's own
                // "IDEMPOTENCY / EXISTING-DECISION COHERENCE" doc note.
                throw CalendarPlanningCoordinationError.splitProvenanceIncomplete
            }
            let existingActivities = try existingLinks.compactMap { try planningService.fetchPlannedActivity(byId: PlannedActivityId(rawValue: $0.plannedActivityId)) }
            guard existingActivities.count == existingLinks.count else {
                throw CalendarPlanningCoordinationError.alreadyDecided
            }
            return existingActivities
        }

        var resolvedAthletes: [AthleteId: AthleteProfile] = [:]
        for (index, child) in children.enumerated() {
            guard (1...1440).contains(child.durationMinutes) else {
                throw CalendarPlanningCoordinationError.invalidSplitChildDuration(index: index)
            }
            guard child.startOffsetMinutes >= 0 else {
                throw CalendarPlanningCoordinationError.invalidSplitChildStartOffset(index: index)
            }
            if resolvedAthletes[child.athleteId] == nil {
                guard let athlete = try athleteRepository.fetchAthlete(byId: child.athleteId), !athlete.isArchived else {
                    throw CalendarPlanningCoordinationError.splitChildAthleteNotFound(index: index)
                }
                guard athlete.workspaceId == source.workspaceId else {
                    throw CalendarPlanningCoordinationError.splitChildAthleteOutsideSourceWorkspace(index: index)
                }
                resolvedAthletes[child.athleteId] = athlete
            }
        }

        var created: [PlannedActivity] = []
        var decision: CalendarImportDecision?
        do {
            for child in children {
                guard let athlete = resolvedAthletes[child.athleteId] else {
                    // Unreachable — every child's athlete was resolved
                    // into `resolvedAthletes` in the validation pass
                    // above, which throws before this loop is ever
                    // reached if any lookup fails.
                    continue
                }
                let occurrenceStart = item.event.startDate.addingTimeInterval(TimeInterval(child.startOffsetMinutes * 60))
                let (localDate, startLocalTime) = Self.localDateAndTime(for: occurrenceStart, in: athlete.timeZoneId)
                let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: child.athleteId, weekStart: localDate.startOfWeek)
                let activity = try planningService.addPlannedActivity(
                    toWeekPlan: weekPlan.weekPlanId,
                    athleteId: child.athleteId,
                    activityType: child.activityType,
                    title: item.event.title,
                    localDate: localDate,
                    timeZoneId: athlete.timeZoneId,
                    sportId: child.sportId,
                    startLocalTime: startLocalTime,
                    plannedDurationMinutes: child.durationMinutes,
                    externalSourceId: item.externalEventKey,
                    externalSourceType: Self.externalSourceType,
                    notes: item.event.notes,
                    location: item.event.location
                )
                created.append(activity)
            }

            let firstChild = children[0]
            let newDecision = try importDecisionRepository.insert(
                sourceId: source.externalPlanningSourceId,
                externalEventKey: item.externalEventKey,
                status: .imported,
                athleteId: firstChild.athleteId,
                sportId: firstChild.sportId,
                activityType: firstChild.activityType,
                plannedActivityId: created[0].plannedActivityId,
                decidedBy: decidedBy
            )
            decision = newDecision
            for (index, activity) in created.enumerated() {
                try decomposedActivityLinkRepository.insert(
                    calendarImportDecisionId: newDecision.calendarImportDecisionId,
                    plannedActivityId: activity.plannedActivityId,
                    orderIndex: index
                )
            }
        } catch {
            if let decision {
                let partialLinks = (try? decomposedActivityLinkRepository.fetchAll(forDecision: decision.calendarImportDecisionId)) ?? []
                for link in partialLinks {
                    try? decomposedActivityLinkRepository.delete(link)
                }
                try? importDecisionRepository.delete(decision)
            }
            for activity in created {
                try? planningService.deletePlannedActivity(
                    activity.plannedActivityId, expectedWeekPlanId: WeekPlanId(rawValue: activity.weekPlanId), deletedBy: decidedBy
                )
            }
            throw error
        }

        // Reaching here means the `do` block above completed without
        // throwing — every `PlannedActivity`, the `CalendarImportDecision`,
        // and every `DecomposedActivityLink` are durably committed;
        // `decision` itself is no longer needed (only `created` is
        // returned to the caller).

        // EVIDENCE: post-import learning assistance only — see this
        // method's own "EVIDENCE" doc note above for why a failure here
        // is deliberately swallowed rather than propagated.
        try? recordDecompositionEvidenceIfAbsent(item: item, source: source, children: children, decidedBy: decidedBy)

        return created
    }

    /// VX-038: the reusable, historical shape of a Suggested Split — a
    /// prefill proposal only, never itself Planning truth. See
    /// `suggestedSplit(for:source:)`'s own doc comment for how it is
    /// matched.
    public struct SuggestedSplit: Sendable, Equatable {
        public struct Child: Sendable, Equatable {
            public let athleteId: AthleteId
            public let sportId: SportId?
            public let activityType: ActivityType
            public let startOffsetMinutes: Int
            public let durationMinutes: Int
        }
        public let children: [Child]
    }

    /// VX-038: looks up durable decomposition evidence for `event`
    /// within `source` ONLY — a pure read, never itself creating or
    /// mutating anything, and never applied without explicit Parent
    /// confirmation (that confirmation is `classifyAndImportSplit`
    /// itself). Precedence, per the approved contract:
    ///   1. `event.isRecurring` AND a `DecompositionEvidence` row exists
    ///      for `source` whose `recurringEventIdentifier` matches
    ///      `event.eventIdentifier` — the STRONGEST evidence (the same
    ///      recurring series, not merely similar text);
    ///   2. else, a `DecompositionEvidence` row exists for `source`
    ///      whose `normalizedTitle` matches `event.title` (via
    ///      `ExternalEventTitleNormalization.normalize(_:)`, the SAME
    ///      exact-match normalization this domain's remembered-
    ///      classification evidence already uses) — the fallback,
    ///      scoped to `source` only (never a different source, even one
    ///      with an identical title — see `DecompositionEvidence`'s own
    ///      doc comment);
    ///   3. else `nil` — no suggestion.
    public func suggestedSplit(for event: ExternalCalendarEvent, source: ExternalPlanningSource) throws -> SuggestedSplit? {
        let allEvidence = try decompositionEvidenceRepository.fetchAll(forSource: source.externalPlanningSourceId)
        guard !allEvidence.isEmpty else { return nil }

        let matched: DecompositionEvidence?
        if event.isRecurring, let recurringMatch = allEvidence.first(where: { $0.recurringEventIdentifier == event.eventIdentifier }) {
            matched = recurringMatch
        } else if let normalizedTitle = ExternalEventTitleNormalization.normalize(event.title),
                  let titleMatch = allEvidence.first(where: { $0.normalizedTitle == normalizedTitle }) {
            matched = titleMatch
        } else {
            matched = nil
        }
        guard let evidence = matched else { return nil }

        let children = try decompositionEvidenceRepository.fetchChildren(forEvidence: evidence.decompositionEvidenceId)
        guard !children.isEmpty else { return nil }
        return SuggestedSplit(children: children.map { child in
            SuggestedSplit.Child(
                athleteId: AthleteId(rawValue: child.athleteId),
                sportId: child.sportId.map { SportId(rawValue: $0) },
                activityType: child.activityType,
                startOffsetMinutes: child.startOffsetMinutes,
                durationMinutes: child.durationMinutes
            )
        })
    }

    /// VX-038: CREATE-ONLY — records durable decomposition evidence for
    /// `children` (the split just explicitly imported) UNLESS matching
    /// evidence already exists for this exact key, checked with the
    /// SAME precedence `suggestedSplit(for:source:)` itself uses. This
    /// is the ONE place a later, edited (or from-scratch) split for a
    /// DIFFERENT occurrence of the same recurring series is guaranteed
    /// to never silently rewrite the historical, already-learned
    /// pattern — the approved contract's own "editing one occurrence
    /// must not silently rewrite historical decomposition evidence for
    /// the whole recurring series" rule, enforced structurally (never
    /// called at all when evidence already exists) rather than by a
    /// caller remembering not to overwrite.
    private func recordDecompositionEvidenceIfAbsent(
        item: CalendarReviewItem,
        source: ExternalPlanningSource,
        children: [DecomposedChildInput],
        decidedBy: ActorId
    ) throws {
        if try suggestedSplit(for: item.event, source: source) != nil {
            return
        }
        let recurringEventIdentifier = item.event.isRecurring ? item.event.eventIdentifier : nil
        let normalizedTitle = ExternalEventTitleNormalization.normalize(item.event.title)
        try decompositionEvidenceRepository.insert(
            sourceId: source.externalPlanningSourceId,
            recurringEventIdentifier: recurringEventIdentifier,
            normalizedTitle: normalizedTitle,
            createdBy: decidedBy,
            children: children.map { (athleteId: $0.athleteId, sportId: $0.sportId, activityType: $0.activityType, startOffsetMinutes: $0.startOffsetMinutes, durationMinutes: $0.durationMinutes) }
        )
    }

    /// The explicit Parent action for "this event should never become
    /// Planning" — records a `CalendarImportDecision(status: .ignored)`
    /// with no athlete/sport/activityType/plannedActivityId, so
    /// `fetchReviewQueue(for:)` never presents this exact event again.
    /// Never creates or touches a `PlannedActivity`. Idempotent: ignoring
    /// an already-decided event is a safe no-op (returns the existing
    /// decision unchanged) rather than a duplicate row.
    ///
    /// PR #49 follow-up (source-disabled Ignore safety): throws
    /// `.sourceDisabled` for a disabled/disconnected source, matching
    /// every other mutating action's own boundary
    /// (`classifyAndImport`/`restoreIgnoredEvent`) — a stale review
    /// screen must never be able to persist a NEW `.ignored` decision
    /// against a source the Parent has since disabled or disconnected.
    /// This guard lives HERE, at the canonical service boundary, so
    /// every caller — a single manual Ignore tap AND
    /// `CalendarImportReviewViewModel.confirmSuggestedIgnoresAndImportReadyItems()`'s
    /// own batch loop — obeys the exact same invariant; it is
    /// deliberately not re-implemented as a View/ViewModel-side check.
    /// The idempotent "already decided" return above is checked AFTER
    /// this guard, so even a harmless idempotent re-Ignore of an
    /// already-`.ignored` event correctly fails calmly against a
    /// disabled source rather than silently succeeding.
    @discardableResult
    public func ignore(_ item: CalendarReviewItem, for source: ExternalPlanningSource, decidedBy: ActorId) throws -> CalendarImportDecision {
        guard source.isEnabled, source.lifecycleStatus == .connected else {
            throw CalendarPlanningCoordinationError.sourceDisabled
        }
        if let existing = try importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: item.externalEventKey) {
            return existing
        }
        return try importDecisionRepository.insert(
            sourceId: source.externalPlanningSourceId,
            externalEventKey: item.externalEventKey,
            status: .ignored,
            athleteId: nil,
            sportId: nil,
            activityType: nil,
            plannedActivityId: nil,
            ignoredEventTitle: item.event.title,
            decidedBy: decidedBy
        )
    }

    /// Calendar Import Review runtime fix: reverses a Parent's explicit
    /// Ignore — the ONLY way an `.ignored` `CalendarImportDecision` is
    /// ever removed. Deletes ONLY that exact decision (scoped by
    /// `source`'s own `ExternalPlanningSourceId` + `externalEventKey`,
    /// the same stable identity every other method here uses); the
    /// underlying external event is never touched, no `PlannedActivity`
    /// is ever created or deleted, and no replacement decision is ever
    /// written. Once deleted, the event naturally becomes pending again
    /// purely through the existing "absence of a decision = pending"
    /// model `fetchReviewQueue(for:)` already implements — there is no
    /// separate "restored" state to invent.
    ///
    /// A no-op (silently returns) if no decision exists at all for this
    /// key — matching `disconnectSource`'s own "nothing to act on"
    /// precedent. Throws `.decisionNotIgnored` if a decision DOES exist
    /// but is `.imported` — restoring is a strict reversal of Ignore
    /// only; it must never delete/undo an actual Planning import (see
    /// `removeImportedActivities(for:removedBy:)` for that separate,
    /// explicit action). Throws `.sourceDisabled` for a disabled/
    /// disconnected source, matching every other mutating action's own
    /// boundary — restoring must fail calmly rather than presenting a
    /// stale action as successful.
    ///
    /// Deliberately takes no actor parameter: deleting a decision record
    /// carries no attribution field of its own (a `CalendarImportDecision`
    /// is immutable once made — see `CalendarImportDecisionRepository`'s
    /// own doc comment — and its `decidedBy` records only the ORIGINAL
    /// decision, never a later reversal), matching `disconnectSource`'s
    /// own precedent for a similarly non-content-creating mutation.
    public func restoreIgnoredEvent(_ externalEventKey: String, for source: ExternalPlanningSource) throws {
        guard source.isEnabled, source.lifecycleStatus == .connected else {
            throw CalendarPlanningCoordinationError.sourceDisabled
        }
        guard let decision = try importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: externalEventKey) else {
            return
        }
        guard decision.status == .ignored else {
            throw CalendarPlanningCoordinationError.decisionNotIgnored
        }
        try importDecisionRepository.delete(decision)
    }

    // MARK: - Recovery

    /// Family-Owned Calendar Sources V1 (adapted from Calendar Planning
    /// Source V1's PR #40 recovery round): outcome of an explicit,
    /// Parent-triggered "remove everything this source imported" action
    /// — distinct from `ReconciliationOutcome`, which reports what an
    /// automatic reconciliation run did. Never a silent success: every
    /// candidate activity ends up in exactly one bucket below, so a
    /// caller can always tell partial completion from full completion.
    public struct ImportedActivityCleanupOutcome: Sendable, Equatable {
        /// Deleted through the normal `PlanningService.deletePlannedActivity`
        /// path.
        public let removed: Int
        /// Left untouched because it already has a `LoggedActivity` —
        /// proven Training truth is never erased by this action.
        public let preservedLogged: Int
        /// Left untouched because its `WeekPlan` is historical
        /// (`weekStart` before the current week), regardless of whether
        /// that historical week is `.committed` or `.draft` — this
        /// action operates only on current/future Planning; a historical
        /// `.committed` week is never reopened (see `WeekPlan.reopen`'s
        /// own `.historicalWeekNotReopenable` guard), and a historical
        /// `.draft` week is left equally untouched by policy. Reported
        /// separately from `failed` because it is an expected,
        /// permanent-for-this-action outcome, not an error.
        public let historicalWeeksSkipped: Int
        /// Left untouched because of an unexpected failure (e.g. a
        /// concurrent revision conflict) reopening or deleting.
        public let failed: Int
        /// Count of WeekPlans that WERE originally `.committed`, were
        /// reopened to allow cleanup, and had at least one activity
        /// removed — but whose committed status could NOT be restored
        /// afterward. Reported separately so this is never silently
        /// reported as full success.
        public let lifecycleRestoreFailed: Int
    }

    /// Removes every currently-linked, not-yet-logged `PlannedActivity`
    /// this ONE `source` has ever imported — across EVERY athlete, since
    /// a family-owned source is not athlete-scoped (unlike Calendar
    /// Planning Source V1's per-mapping cleanup, which scoped by one
    /// athlete + one calendar). Does not disable, disconnect, or delete
    /// the source itself — call `setSourceEnabled`/`disconnectSource`
    /// separately. Works regardless of the source's current
    /// enabled/lifecycle state — recovery must remain possible even
    /// after disconnecting.
    ///
    /// SCOPING: `PlannedActivity` has no persisted `ExternalPlanningSourceId`
    /// of its own — provenance is only ever the generic
    /// `externalSourceId`/`externalSourceType` pair. Two canonical facts
    /// are sufficient and necessary to safely scope this action, with no
    /// new persisted ID:
    ///   1. `externalSourceType == Self.externalSourceType` — excludes
    ///      every manually-created activity (`nil`) AND every Recurring-
    ///      Planned-Activity-materialized one;
    ///   2. `externalSourceId?.hasPrefix("\(source.externalContainerIdentifier)|")` —
    ///      excludes every activity imported by a DIFFERENT source (a
    ///      different `externalContainerIdentifier` never produces this
    ///      exact prefix).
    /// Together these can only ever match activities THIS exact source
    /// created — never another source's, never a manually-created row —
    /// regardless of which athlete they were classified to.
    ///
    /// For each removed activity, its `CalendarImportDecision` (if any)
    /// is also deleted, so the underlying external event becomes
    /// reviewable again in Calendar Import Review — the Parent
    /// explicitly undid a wrong import and should get a chance to
    /// re-classify it correctly, not have it permanently stuck.
    @discardableResult
    public func removeImportedActivities(for source: ExternalPlanningSource, removedBy actorId: ActorId) throws -> ImportedActivityCleanupOutcome {
        let calendarPrefix = "\(source.externalContainerIdentifier)|"
        let allLinked = try planningService.fetchPlannedActivities(externalSourceType: Self.externalSourceType)
        let candidates = allLinked.filter { activity in
            guard let sourceId = activity.externalSourceId else { return false }
            return sourceId.hasPrefix(calendarPrefix)
        }

        var preservedLogged = 0

        // Grouped by WeekPlanId BEFORE any reopen/delete happens, so a
        // committed week containing several imported activities is
        // reopened and (if eligible) recommitted exactly ONCE, never
        // per-activity.
        var eligibleByWeek: [WeekPlanId: [PlannedActivity]] = [:]
        for activity in candidates {
            // Planning proposes; Training proves. Proven training truth is
            // never erased by this action.
            let logged = try trainingService.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
            guard logged.isEmpty else {
                preservedLogged += 1
                continue
            }
            eligibleByWeek[WeekPlanId(rawValue: activity.weekPlanId), default: []].append(activity)
        }

        var removed = 0
        var historicalWeeksSkipped = 0
        var failed = 0
        var lifecycleRestoreFailed = 0

        for (weekPlanId, activities) in eligibleByWeek {
            guard let weekPlan = try planningService.fetchWeekPlan(byId: weekPlanId) else {
                failed += activities.count
                continue
            }
            // Every activity in one WeekPlan shares that WeekPlan's own
            // athlete by construction — the "current week" boundary
            // below is therefore computed for THIS week's actual owning
            // athlete, correct even when this source's candidates span
            // several athletes with different time zones.
            let weekAthleteId = AthleteId(rawValue: weekPlan.athleteId)
            let weekAthlete = try athleteRepository.fetchAthlete(byId: weekAthleteId)
            let weekTimeZoneId = weekAthlete?.timeZoneId ?? TimeZoneId(rawValue: TimeZone.current.identifier)
            let currentWeekStart = Self.localDateAndTime(for: dateProvider.now, in: weekTimeZoneId).0.startOfWeek

            // Historical Planning is never destructively cleaned up —
            // regardless of `.committed`/`.draft` — checked BEFORE any
            // status/lifecycle branching.
            guard weekPlan.weekStart >= currentWeekStart else {
                historicalWeeksSkipped += activities.count
                continue
            }

            let wasOriginallyCommitted = weekPlan.status == .committed
            if wasOriginallyCommitted {
                do {
                    try planningService.reopenWeekPlan(
                        weekPlanId, expectedRevision: weekPlan.revision, reopenedBy: actorId, currentWeekStart: currentWeekStart
                    )
                } catch {
                    failed += activities.count
                    continue
                }
            }

            var weekRemoved = 0
            for activity in activities {
                do {
                    try planningService.deletePlannedActivity(
                        activity.plannedActivityId, expectedWeekPlanId: weekPlanId, deletedBy: actorId
                    )
                    weekRemoved += 1
                    if let key = activity.externalSourceId,
                       let decision = try importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: key) {
                        try importDecisionRepository.delete(decision)
                    }
                } catch {
                    failed += 1
                }
            }
            removed += weekRemoved

            guard wasOriginallyCommitted else { continue }
            // Restore the week's original committed state — never left
            // silently in `.draft`. The revision after reopen + N
            // deletes is never assumed; canonical state is re-read
            // before recommitting.
            do {
                guard let currentWeekPlan = try planningService.fetchWeekPlan(byId: weekPlanId) else {
                    lifecycleRestoreFailed += 1
                    continue
                }
                try planningService.commitWeekPlan(
                    weekPlanId, expectedRevision: currentWeekPlan.revision, committedBy: actorId
                )
            } catch {
                lifecycleRestoreFailed += 1
            }
        }

        return ImportedActivityCleanupOutcome(
            removed: removed,
            preservedLogged: preservedLogged,
            historicalWeeksSkipped: historicalWeeksSkipped,
            failed: failed,
            lifecycleRestoreFailed: lifecycleRestoreFailed
        )
    }

    // MARK: - Reconciliation (source-owned schedule field updates ONLY — never creates)

    /// Per-source reconciliation counts — presentation/diagnostic only,
    /// never itself a stored or authoritative value. Unlike Calendar
    /// Planning Source V1's `ReconciliationOutcome`, there is no
    /// `created` count: reconciliation under the new model NEVER creates
    /// a `PlannedActivity` — only `classifyAndImport` does, through
    /// explicit Parent review. An event with no existing classification
    /// is simply left for Calendar Import Review, not counted here at
    /// all (it is not an error, a skip, or a cancellation).
    public struct ReconciliationOutcome: Sendable, Equatable {
        /// An already-imported `PlannedActivity`'s source-owned fields
        /// (title/start/duration) were refreshed from the external
        /// event.
        public let updated: Int
        /// An already-imported `PlannedActivity` was removed because its
        /// external event disappeared from the source within the
        /// reconciliation window (see `cancelDisappearedActivities`).
        public let cancelled: Int
        /// An already-imported event this run could not safely act on —
        /// e.g. its target week is no longer draft, or it moved to a
        /// different week than its already-linked `PlannedActivity`.
        /// Never a crash, never a fabricated mutation.
        public let skipped: Int
    }

    /// Reconciles every currently-enabled, CONNECTED source for
    /// `workspaceId`, in deterministic order. A disabled or disconnected
    /// source is skipped entirely; safe and idempotent to call
    /// repeatedly. A single source's failure (e.g. its calendar was
    /// removed) does not prevent the others from reconciling — same
    /// per-source isolation Calendar Planning Source V1 already
    /// established.
    @discardableResult
    public func reconcileAllEnabledSources(forWorkspace workspaceId: WorkspaceId) throws -> [ExternalPlanningSourceId: ReconciliationOutcome] {
        var results: [ExternalPlanningSourceId: ReconciliationOutcome] = [:]
        for source in try sourceRepository.fetchAllEnabled(forWorkspace: workspaceId) {
            do {
                results[source.externalPlanningSourceId] = try reconcile(source)
            } catch {
                continue
            }
        }
        return results
    }

    /// Lead Review follow-up (Blocker 2): a disabled or disconnected
    /// `source` is never reconciled — enforced HERE too (not only by
    /// `reconcileAllEnabledSources`'s own `fetchAllEnabled` filtering),
    /// so a direct call (e.g. a "Sync now" button) can never bypass the
    /// canonical boundary. Returns a zero outcome immediately, before
    /// ever calling the calendar provider.
    ///
    /// `calendarEventProvider.events(...)` below is a plain `try` — if
    /// the provider throws `CalendarEventProviderError.calendarUnavailable`
    /// (calendar removed/unresolvable), this method throws immediately
    /// and performs NO update/cancel for this source at all; nothing
    /// after this call runs, including `cancelDisappearedActivities` and
    /// `sourceRepository.recordReconciliation`. An unavailable source is
    /// therefore never interpreted as "every previously-imported event
    /// disappeared" — only a genuinely successful (possibly empty) fetch
    /// can ever reach the cancellation step below.
    @discardableResult
    public func reconcile(_ source: ExternalPlanningSource) throws -> ReconciliationOutcome {
        guard source.isEnabled, source.lifecycleStatus == .connected else {
            return ReconciliationOutcome(updated: 0, cancelled: 0, skipped: 0)
        }

        let now = dateProvider.now
        guard let windowEnd = Calendar(identifier: .gregorian).date(
            byAdding: .day, value: Self.reconciliationWindowDays, to: now
        ) else {
            return ReconciliationOutcome(updated: 0, cancelled: 0, skipped: 0)
        }
        let externalEvents = try calendarEventProvider.events(inCalendar: source.externalContainerIdentifier, from: now, to: windowEnd)
        // All-day events have no meaningful start TIME to plan around in
        // this V1 slice — excluded, not imported as a dateless activity.
        let qualifyingEvents = externalEvents.filter { !$0.isAllDay }

        var updated = 0
        var skipped = 0
        var seenExternalSourceIds: Set<String> = []

        for event in qualifyingEvents {
            let key = ExternalCalendarEventIdentity.externalSourceId(calendarIdentifier: source.externalContainerIdentifier, event: event)
            seenExternalSourceIds.insert(key)
            let outcome = try applyReconciledEvent(event, externalSourceId: key)
            switch outcome {
            case .updated: updated += 1
            case .skipped: skipped += 1
            case .notYetImported: break
            }
        }

        let cancelled = try cancelDisappearedActivities(
            source: source, windowStart: now, windowEnd: windowEnd, seenExternalSourceIds: seenExternalSourceIds
        )

        try sourceRepository.recordReconciliation(source, at: now)
        return ReconciliationOutcome(updated: updated, cancelled: cancelled, skipped: skipped)
    }

    private enum ReconciledEventOutcome { case updated, skipped, notYetImported }

    /// Reconciles ONE external event against an ALREADY-imported
    /// `PlannedActivity`, if one exists. Never creates — an event with
    /// no existing match is `.notYetImported` (left for Calendar Import
    /// Review, not an error/skip).
    private func applyReconciledEvent(_ event: ExternalCalendarEvent, externalSourceId: String) throws -> ReconciledEventOutcome {
        let existingMatches = try planningService.fetchPlannedActivities(externalSourceType: Self.externalSourceType)
            .filter { $0.externalSourceId == externalSourceId }
        guard !existingMatches.isEmpty else { return .notYetImported }
        // VX-038: more than one PlannedActivity sharing this exact
        // externalSourceId means this event was explicitly DECOMPOSED
        // (see classifyAndImportSplit) — each child's planned timing is
        // offset-based and Vǫxtr/Parent-owned, never a literal mirror of
        // the external event's own start time, so blindly updating only
        // the FIRST match here (the old single-activity assumption)
        // would silently corrupt that child's timing while leaving its
        // siblings stale. Skipped entirely, not updated — matches this
        // feature's own "do not silently overwrite Vǫxtr-edited child
        // classification/timing" reconciliation contract. An event that
        // genuinely disappears is still handled correctly:
        // `cancelDisappearedActivities` matches by the SAME
        // `externalSourceId` and removes every one of these children
        // together.
        guard existingMatches.count == 1, let existing = existingMatches.first else {
            return .skipped
        }

        let athleteId = AthleteId(rawValue: existing.athleteId)
        guard let athlete = try athleteRepository.fetchAthlete(byId: athleteId) else {
            return .skipped
        }
        let timeZoneId = athlete.timeZoneId
        let (localDate, startLocalTime) = Self.localDateAndTime(for: event.startDate, in: timeZoneId)
        let durationMinutes = Self.durationMinutes(start: event.startDate, end: event.endDate)

        // UPDATE: the external source owns schedule facts (title/start/
        // duration/time zone); every other Vǫxtr-owned field — sportId,
        // activityType, categoryIds, plannedIntensity, notes, location —
        // is read back from the EXISTING row and passed through
        // unchanged, never re-applied from anywhere else (the Parent's
        // own classification choice, or a later manual adjustment, is
        // never overwritten by reconciliation).
        let existingWeekPlanId = WeekPlanId(rawValue: existing.weekPlanId)
        let targetWeekStart = localDate.startOfWeek
        guard let currentWeekPlan = try planningService.fetchWeekPlan(byId: existingWeekPlanId),
              currentWeekPlan.weekStart == targetWeekStart else {
            // The event moved to a different Vǫxtr planning week than its
            // already-linked PlannedActivity. editPlannedActivity cannot
            // move an activity between WeekPlans — left untouched this
            // round.
            return .skipped
        }
        do {
            _ = try planningService.editPlannedActivity(
                existing.plannedActivityId,
                expectedWeekPlanId: existingWeekPlanId,
                activityType: existing.activityType,
                title: event.title,
                localDate: localDate,
                timeZoneId: timeZoneId,
                sportId: existing.sportId.map { SportId(rawValue: $0) },
                categoryIds: existing.categoryIds.map { ActivityCategoryId(rawValue: $0) },
                startLocalTime: startLocalTime,
                plannedDurationMinutes: durationMinutes,
                plannedIntensity: existing.plannedIntensity,
                notes: existing.notes,
                location: existing.location
            )
            return .updated
        } catch PlanningServiceError.weekPlanNotDraft {
            // The week has since been committed — Planning's own existing
            // "no edits to a committed plan" rule applies exactly as it
            // does for a Parent's manual edit. Skipped, not an error.
            return .skipped
        }
    }

    /// Cancels/removes every already-imported `PlannedActivity` (for
    /// this source's calendar, across every athlete) inside the
    /// reconciliation window that no longer has a matching external
    /// event THIS round — "handle an event disappearing without
    /// silently leaving misleading future schedule data forever."
    /// Scoped strictly to the SAME window just fetched. Also deletes the
    /// corresponding `CalendarImportDecision`, so a genuinely new event
    /// later reusing the same identity (unlikely, but never assumed
    /// impossible) is reviewable rather than permanently blocked.
    private func cancelDisappearedActivities(
        source: ExternalPlanningSource,
        windowStart: Date,
        windowEnd: Date,
        seenExternalSourceIds: Set<String>
    ) throws -> Int {
        let calendarPrefix = "\(source.externalContainerIdentifier)|"
        let allLinked = try planningService.fetchPlannedActivities(externalSourceType: Self.externalSourceType)
        let candidates = allLinked.filter { activity in
            guard let sourceId = activity.externalSourceId, sourceId.hasPrefix(calendarPrefix) else { return false }
            return !seenExternalSourceIds.contains(sourceId)
        }

        var cancelled = 0
        var timeZoneCache: [UUID: TimeZoneId] = [:]
        for activity in candidates {
            // Each candidate's OWN athlete's time zone resolves the
            // window bounds — a family-owned source can span athletes in
            // different time zones, unlike Calendar Planning Source V1's
            // single-athlete-per-mapping scoping.
            let athleteRawId = activity.athleteId
            let timeZoneId: TimeZoneId
            if let cached = timeZoneCache[athleteRawId] {
                timeZoneId = cached
            } else {
                let athlete = try athleteRepository.fetchAthlete(byId: AthleteId(rawValue: athleteRawId))
                timeZoneId = athlete?.timeZoneId ?? TimeZoneId(rawValue: TimeZone.current.identifier)
                timeZoneCache[athleteRawId] = timeZoneId
            }
            let windowStartLocalDate = Self.localDateAndTime(for: windowStart, in: timeZoneId).0
            let windowEndLocalDate = Self.localDateAndTime(for: windowEnd, in: timeZoneId).0
            guard activity.localDate >= windowStartLocalDate && activity.localDate <= windowEndLocalDate else { continue }

            // Planning proposes; Training proves. Proven training truth
            // is never erased by an external source disappearing.
            let logged = try trainingService.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
            guard logged.isEmpty else { continue }
            let weekPlanId = WeekPlanId(rawValue: activity.weekPlanId)
            do {
                try planningService.deletePlannedActivity(
                    activity.plannedActivityId, expectedWeekPlanId: weekPlanId, deletedBy: .system
                )
                cancelled += 1
                if let key = activity.externalSourceId,
                   let decision = try importDecisionRepository.fetch(sourceId: source.externalPlanningSourceId, externalEventKey: key) {
                    try importDecisionRepository.delete(decision)
                }
            } catch PlanningServiceError.weekPlanNotDraft {
                // Same "already-committed week" boundary as the update
                // path above — left in place, not an error.
                continue
            }
        }
        return cancelled
    }

    // MARK: - Time normalization

    /// The ONE place an `ExternalCalendarEvent`'s absolute `Date` is
    /// normalized into Vǫxtr's own `LocalDate`/`LocalTime` — never the
    /// device's current time zone, always the relevant athlete's own
    /// configured `AthleteProfile.timeZoneId`.
    private static func localDateAndTime(for date: Date, in timeZoneId: TimeZoneId) -> (LocalDate, LocalTime) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneId.timeZone ?? TimeZone(identifier: "UTC") ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let localDate = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        let localTime = LocalTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
        return (localDate, localTime)
    }

    private static func durationMinutes(start: Date, end: Date?) -> Int? {
        guard let end else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        guard (1...1440).contains(minutes) else { return nil }
        return minutes
    }
}
