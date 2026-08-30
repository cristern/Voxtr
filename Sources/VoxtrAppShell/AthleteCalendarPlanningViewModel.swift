import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrCalendarPlanningDomain

/// Calendar Planning Source V1: backs the "Calendar" configuration
/// screen reached from one athlete's own Athlete Settings hub. Owns the
/// contextual permission flow, calendar/Sport/Activity Type selection,
/// and enabling/disabling/removing the one mapping this athlete may
/// have.
///
/// Calm by Default: never requests Calendar permission itself at
/// construction/`load()` — only `connectCalendar()`, fired by an
/// explicit "Connect Calendar" tap, ever calls
/// `CalendarPlanningCoordinationService.requestAuthorization`.
@MainActor
@Observable
public final class AthleteCalendarPlanningViewModel {
    public let athleteId: AthleteId
    private let calendarPlanningCoordinationService: CalendarPlanningCoordinationService
    private let sportRepository: SportRepository

    public private(set) var authorizationStatus: CalendarAuthorizationStatus = .notDetermined
    public private(set) var availableCalendars: [AvailableCalendar] = []
    public private(set) var sports: [Sport] = []
    /// At most one, per the V1 product contract — see
    /// `CalendarPlanningMapping`'s own doc comment.
    public private(set) var mapping: CalendarPlanningMapping?
    public private(set) var errorMessage: String?
    public private(set) var lastReconciliationOutcome: CalendarPlanningCoordinationService.ReconciliationOutcome?

    // New-mapping form state — only meaningful while `mapping == nil`
    // and `authorizationStatus == .authorized`.
    public var selectedCalendarId: String?
    public var selectedActivityType: ActivityType = .individualTraining
    public var selectedSportId: SportId?

    public init(
        athleteId: AthleteId,
        calendarPlanningCoordinationService: CalendarPlanningCoordinationService,
        sportRepository: SportRepository
    ) {
        self.athleteId = athleteId
        self.calendarPlanningCoordinationService = calendarPlanningCoordinationService
        self.sportRepository = sportRepository
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
        mapping = (try? calendarPlanningCoordinationService.fetchMappings(forAthlete: athleteId))?.first
        sports = (try? sportRepository.fetchAllSports()) ?? []
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

    /// Creates the mapping (disabled by default — see
    /// `CalendarPlanningMapping`'s own doc comment) and immediately
    /// enables + reconciles it, matching the approved setup flow:
    /// "Connect Calendar -> permission -> choose calendar -> choose
    /// athlete -> choose required Vǫxtr context -> enable -> initial
    /// reconciliation." Athlete is already fixed (this screen's own
    /// `athleteId`), so this one action covers the remaining steps.
    public func saveMapping() {
        errorMessage = nil
        guard let selectedCalendarId else { return }
        guard let calendar = availableCalendars.first(where: { $0.id == selectedCalendarId }) else { return }
        do {
            let created = try calendarPlanningCoordinationService.createMapping(
                athleteId: athleteId,
                calendarIdentifier: calendar.id,
                calendarTitle: calendar.title,
                activityType: selectedActivityType,
                sportId: selectedSportId
            )
            try calendarPlanningCoordinationService.setMappingEnabled(created.calendarPlanningMappingId, isEnabled: true)
            mapping = try calendarPlanningCoordinationService.fetchMappings(forAthlete: athleteId).first
            reconcileNow()
        } catch CalendarPlanningCoordinationError.duplicateMapping {
            errorMessage = CalendarPlanningStrings.duplicateMappingError
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    public func setEnabled(_ isEnabled: Bool) {
        guard let mapping else { return }
        errorMessage = nil
        do {
            try calendarPlanningCoordinationService.setMappingEnabled(mapping.calendarPlanningMappingId, isEnabled: isEnabled)
            self.mapping = try calendarPlanningCoordinationService.fetchMappings(forAthlete: athleteId).first
            if isEnabled { reconcileNow() }
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    public func updateContext(activityType: ActivityType, sportId: SportId?) {
        guard let mapping else { return }
        errorMessage = nil
        do {
            _ = try calendarPlanningCoordinationService.updateMapping(mapping.calendarPlanningMappingId, activityType: activityType, sportId: sportId)
            self.mapping = try calendarPlanningCoordinationService.fetchMappings(forAthlete: athleteId).first
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    public func disconnect() {
        guard let mapping else { return }
        errorMessage = nil
        do {
            try calendarPlanningCoordinationService.deleteMapping(mapping.calendarPlanningMappingId)
            self.mapping = nil
            lastReconciliationOutcome = nil
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    public func reconcileNow() {
        guard let mapping else { return }
        errorMessage = nil
        do {
            lastReconciliationOutcome = try calendarPlanningCoordinationService.reconcile(mapping)
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }
}
