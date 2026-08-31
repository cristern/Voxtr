import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAthleteDomain
import VoxtrCalendarPlanningDomain

/// Family-Owned Calendar Sources V1: backs the family-level "Calendar
/// Sources" screen, reached from Profile / Manage Athletes (see
/// `AthleteFamilyManagementView`'s own doc comment) — NOT from any
/// per-athlete screen, since a source belongs to the family, not to one
/// athlete (see `ExternalPlanningSource`'s own doc comment for the real
/// TestFlight evidence this replaces Calendar Planning Source V1's
/// per-athlete mapping for).
///
/// Calm by Default: never requests Calendar permission itself at
/// construction/`load()` — only `connectCalendar()`, fired by an
/// explicit "Connect Calendar" tap, ever calls
/// `CalendarPlanningCoordinationService.requestAuthorization`.
@MainActor
@Observable
public final class FamilyCalendarSourcesViewModel {
    private let calendarPlanningCoordinationService: CalendarPlanningCoordinationService
    /// Held only to build `CalendarImportReviewViewModel` (via
    /// `makeImportReviewViewModel(for:)`) — this screen itself never
    /// reads athlete/Sport data directly.
    private let athleteRepository: AthleteRepository
    private let sportRepository: SportRepository
    /// The real, human Parent this screen's destructive actions
    /// (removing imported activities, reopening a committed week to do
    /// so) are attributed to — never `.system`, matching this app's own
    /// established actor-attribution contract for explicit, Parent-
    /// initiated Planning mutations.
    private let actorId: ActorId

    public private(set) var authorizationStatus: CalendarAuthorizationStatus = .notDetermined
    public private(set) var availableCalendars: [AvailableCalendar] = []
    public private(set) var sources: [ExternalPlanningSource] = []
    public private(set) var errorMessage: String?
    /// Family-Owned Calendar Sources V1 recovery: set after
    /// `removeImportedActivities(for:)` completes for a given source —
    /// keyed so each source's own screen shows only its own outcome,
    /// never a stale one from a different source.
    public private(set) var lastCleanupOutcome: [ExternalPlanningSourceId: CalendarPlanningCoordinationService.ImportedActivityCleanupOutcome] = [:]
    /// Family-Owned Calendar Sources V1 metadata inspection: populated
    /// only by `loadDiagnosticEvents(for:)`, on demand — never fetched
    /// automatically, never persisted.
    public private(set) var diagnosticEvents: [ExternalCalendarEvent] = []
    /// Refreshed by `refreshSources()` (after every mutation) — how many
    /// events are currently awaiting review for a source, shown on its
    /// row so a Parent can see at a glance whether anything needs
    /// attention without opening Review.
    public private(set) var reviewCounts: [ExternalPlanningSourceId: Int] = [:]
    /// Set after `syncNow(_:)` completes for a given source — keyed so
    /// each source's own screen shows only its own outcome, never a
    /// stale one from a different source.
    public private(set) var lastSyncOutcome: [ExternalPlanningSourceId: CalendarPlanningCoordinationService.ReconciliationOutcome] = [:]

    // New-source form state — only meaningful while
    // `authorizationStatus == .authorized`.
    public var selectedCalendarId: String?

    public init(
        calendarPlanningCoordinationService: CalendarPlanningCoordinationService,
        athleteRepository: AthleteRepository,
        sportRepository: SportRepository,
        actorId: ActorId
    ) {
        self.calendarPlanningCoordinationService = calendarPlanningCoordinationService
        self.athleteRepository = athleteRepository
        self.sportRepository = sportRepository
        self.actorId = actorId
    }

    /// Builds a fresh `CalendarImportReviewViewModel` scoped to `source`
    /// — a new instance per navigation, matching this app's own
    /// established "construct the destination's ViewModel at the
    /// NavigationLink" convention (see `AthleteFamilyManagementView`'s
    /// own `sleepSettingsViewModel`/factory-closure precedent).
    public func makeImportReviewViewModel(for source: ExternalPlanningSource) -> CalendarImportReviewViewModel {
        CalendarImportReviewViewModel(
            calendarPlanningCoordinationService: calendarPlanningCoordinationService,
            athleteRepository: athleteRepository,
            sportRepository: sportRepository,
            source: source,
            actorId: actorId
        )
    }

    public func load() {
        errorMessage = nil
        calendarPlanningCoordinationService.authorizationStatus { [weak self] status in
            guard let self else { return }
            self.authorizationStatus = status
            if status == .authorized {
                self.loadAuthorizedState()
            }
        }
        // Family-Owned Calendar Sources V1: the smallest safe migration
        // from the retired per-athlete mapping model — best-effort, same
        // as this screen's own reconciliation calls elsewhere; a
        // migration failure must never block the screen from showing
        // whatever sources already exist. See
        // `CalendarPlanningCoordinationService.migrateLegacySourcesIfNeeded()`'s
        // own doc comment for exactly what this does and does not do.
        try? calendarPlanningCoordinationService.migrateLegacySourcesIfNeeded()
        refreshSources()
    }

    private func refreshSources() {
        sources = (try? calendarPlanningCoordinationService.fetchSources()) ?? []
        for source in sources {
            reviewCounts[source.externalPlanningSourceId] = (try? calendarPlanningCoordinationService.fetchReviewQueue(for: source).count) ?? 0
        }
    }

    private func loadAuthorizedState() {
        availableCalendars = (try? calendarPlanningCoordinationService.fetchAvailableCalendars()) ?? []
    }

    /// The ONE explicit, contextual trigger for the real system prompt —
    /// never called automatically.
    public func connectCalendar() {
        errorMessage = nil
        calendarPlanningCoordinationService.authorizationStatus { [weak self] status in
            guard let self else { return }
            switch status {
            case .authorized:
                self.authorizationStatus = .authorized
                self.loadAuthorizedState()
            case .denied:
                self.authorizationStatus = .denied
            case .notDetermined:
                self.calendarPlanningCoordinationService.requestAuthorization { [weak self] granted in
                    guard let self else { return }
                    self.authorizationStatus = granted ? .authorized : .denied
                    if granted { self.loadAuthorizedState() }
                }
            }
        }
    }

    /// Creates the source (disabled by default — see
    /// `ExternalPlanningSource`'s own doc comment) and immediately
    /// enables + reconciles it, matching the approved setup flow.
    public func saveSource() {
        errorMessage = nil
        guard let selectedCalendarId else { return }
        guard let calendar = availableCalendars.first(where: { $0.id == selectedCalendarId }) else { return }
        do {
            let created = try calendarPlanningCoordinationService.createSource(
                providerKind: .eventKit,
                externalContainerIdentifier: calendar.id,
                displayName: calendar.title
            )
            try calendarPlanningCoordinationService.setSourceEnabled(created.externalPlanningSourceId, isEnabled: true)
            self.selectedCalendarId = nil
            refreshSources()
        } catch CalendarPlanningCoordinationError.duplicateSource {
            errorMessage = CalendarPlanningStrings.duplicateSourceError
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    public func setEnabled(_ source: ExternalPlanningSource, isEnabled: Bool) {
        errorMessage = nil
        do {
            try calendarPlanningCoordinationService.setSourceEnabled(source.externalPlanningSourceId, isEnabled: isEnabled)
            refreshSources()
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    public func disconnect(_ source: ExternalPlanningSource) {
        errorMessage = nil
        do {
            try calendarPlanningCoordinationService.deleteSource(source.externalPlanningSourceId)
            lastCleanupOutcome[source.externalPlanningSourceId] = nil
            lastSyncOutcome[source.externalPlanningSourceId] = nil
            reviewCounts[source.externalPlanningSourceId] = nil
            refreshSources()
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    public func syncNow(_ source: ExternalPlanningSource) {
        errorMessage = nil
        do {
            lastSyncOutcome[source.externalPlanningSourceId] = try calendarPlanningCoordinationService.reconcile(source)
            refreshSources()
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    /// Family-Owned Calendar Sources V1 recovery (adapted from PR #40):
    /// the explicit, confirmation-gated "remove what this calendar
    /// already imported" action — deliberately separate from
    /// `disconnect(_:)` (which, unchanged, still never touches already-
    /// imported activities) and from `setEnabled(_:isEnabled: false)`
    /// (which only stops future reconciliation/review discovery).
    public func removeImportedActivities(for source: ExternalPlanningSource) {
        errorMessage = nil
        do {
            let outcome = try calendarPlanningCoordinationService.removeImportedActivities(for: source, removedBy: actorId)
            lastCleanupOutcome[source.externalPlanningSourceId] = outcome
            refreshSources()
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    /// Family-Owned Calendar Sources V1 metadata inspection: fetches a
    /// small, bounded, never-persisted preview of real upcoming events
    /// from `source`'s calendar — Alpha-only diagnostic. On provider
    /// failure, stale events are cleared and this screen's existing
    /// error state is surfaced, never left indistinguishable from a
    /// legitimately empty calendar.
    public func loadDiagnosticEvents(for source: ExternalPlanningSource) {
        errorMessage = nil
        do {
            diagnosticEvents = try calendarPlanningCoordinationService.fetchDiagnosticEvents(inCalendar: source.externalContainerIdentifier)
        } catch {
            diagnosticEvents = []
            errorMessage = CalendarPlanningStrings.genericError
        }
    }
}
