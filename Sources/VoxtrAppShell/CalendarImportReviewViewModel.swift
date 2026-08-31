import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAthleteDomain
import VoxtrCalendarPlanningDomain

/// Family-Owned Calendar Sources V1 — Calendar Import Review: backs the
/// "Review new events" screen for ONE `ExternalPlanningSource`. This is
/// the ONE place an external event becomes a Vǫxtr `PlannedActivity` —
/// no event is ever imported except through an explicit call this
/// ViewModel makes on an explicit Parent tap. See
/// `CalendarPlanningCoordinationService`'s own doc comment for the full
/// product contract this enforces.
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
    /// Active (non-archived) athletes only — Calendar Import Review
    /// classifies events into an athlete's CURRENT plan, matching every
    /// other Planning creation surface's own athlete scoping.
    public private(set) var athletes: [AthleteProfile] = []
    public private(set) var sports: [Sport] = []
    public private(set) var errorMessage: String?

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
        do {
            reviewQueue = try calendarPlanningCoordinationService.fetchReviewQueue(for: source)
        } catch {
            reviewQueue = []
            errorMessage = CalendarPlanningStrings.genericError
        }
        athletes = ((try? athleteRepository.fetchAllAthletes()) ?? []).filter { !$0.isArchived }
        sports = (try? sportRepository.fetchAllSports()) ?? []
    }

    /// The explicit Parent action that turns one reviewed event into a
    /// canonical `PlannedActivity`, owned by `athleteId`, with the
    /// Parent's own explicit Sport/Activity Type choice — never a
    /// source-level default.
    public func classifyAndImport(
        _ item: CalendarPlanningCoordinationService.CalendarReviewItem,
        athleteId: AthleteId,
        sportId: SportId?,
        activityType: ActivityType
    ) {
        errorMessage = nil
        do {
            _ = try calendarPlanningCoordinationService.classifyAndImport(
                item, for: source, athleteId: athleteId, sportId: sportId, activityType: activityType, decidedBy: actorId
            )
            reviewQueue = try calendarPlanningCoordinationService.fetchReviewQueue(for: source)
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }

    /// The explicit Parent action for "this should never become
    /// Planning" — the View is responsible for the actual confirmation
    /// prompt before calling this.
    public func ignore(_ item: CalendarPlanningCoordinationService.CalendarReviewItem) {
        errorMessage = nil
        do {
            _ = try calendarPlanningCoordinationService.ignore(item, for: source, decidedBy: actorId)
            reviewQueue = try calendarPlanningCoordinationService.fetchReviewQueue(for: source)
        } catch {
            errorMessage = CalendarPlanningStrings.genericError
        }
    }
}
