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
    private let calendarEventProvider: CalendarEventProviding
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let athleteRepository: AthleteRepository
    private let dateProvider: any DateProvider

    public init(
        sourceRepository: ExternalPlanningSourceRepository,
        importDecisionRepository: CalendarImportDecisionRepository,
        legacyMappingRepository: CalendarPlanningMappingRepository,
        calendarEventProvider: CalendarEventProviding,
        planningService: PlanningService,
        trainingService: TrainingService,
        athleteRepository: AthleteRepository,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.sourceRepository = sourceRepository
        self.importDecisionRepository = importDecisionRepository
        self.legacyMappingRepository = legacyMappingRepository
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

    // MARK: - Remembered Exact Choices (V1.1 — prefill only, never auto-import)

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
    public func rememberedClassifications(for source: ExternalPlanningSource) throws -> [String: RememberedClassification] {
        let importedDecisions = try importDecisionRepository.fetchAll(forSource: source.externalPlanningSourceId)
            .filter { $0.status == .imported }
        guard !importedDecisions.isEmpty else { return [:] }

        struct Candidate: Hashable {
            let athleteId: UUID
            let sportId: UUID?
            let activityType: ActivityType
        }

        var candidatesByTitle: [String: Set<Candidate>] = [:]
        for decision in importedDecisions {
            guard let plannedActivityId = decision.plannedActivityId,
                  let activity = try planningService.fetchPlannedActivity(byId: PlannedActivityId(rawValue: plannedActivityId)),
                  let normalizedTitle = ExternalEventTitleNormalization.normalize(activity.title),
                  let decisionAthleteId = decision.athleteId,
                  let decisionActivityType = decision.activityType else {
                continue
            }
            let candidate = Candidate(athleteId: decisionAthleteId, sportId: decision.sportId, activityType: decisionActivityType)
            candidatesByTitle[normalizedTitle, default: []].insert(candidate)
        }

        var result: [String: RememberedClassification] = [:]
        for (normalizedTitle, candidates) in candidatesByTitle {
            // Ambiguity rule: more than one distinct prior classification
            // for this exact normalized title -> no prefill.
            guard candidates.count == 1, let onlyCandidate = candidates.first else { continue }
            guard let athlete = try athleteRepository.fetchAthlete(byId: AthleteId(rawValue: onlyCandidate.athleteId)),
                  !athlete.isArchived,
                  athlete.workspaceId == source.workspaceId else {
                continue
            }
            result[normalizedTitle] = RememberedClassification(
                athleteId: athlete.athleteId,
                sportId: onlyCandidate.sportId.map { SportId(rawValue: $0) },
                activityType: onlyCandidate.activityType
            )
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

    /// The explicit Parent action for "this event should never become
    /// Planning" — records a `CalendarImportDecision(status: .ignored)`
    /// with no athlete/sport/activityType/plannedActivityId, so
    /// `fetchReviewQueue(for:)` never presents this exact event again.
    /// Never creates or touches a `PlannedActivity`. Idempotent: ignoring
    /// an already-decided event is a safe no-op (returns the existing
    /// decision unchanged) rather than a duplicate row.
    @discardableResult
    public func ignore(_ item: CalendarReviewItem, for source: ExternalPlanningSource, decidedBy: ActorId) throws -> CalendarImportDecision {
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
        guard let existing = existingMatches.first(where: { $0.externalSourceId == externalSourceId }) else {
            return .notYetImported
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
