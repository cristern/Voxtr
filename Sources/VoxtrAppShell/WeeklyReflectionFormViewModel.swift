import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrReflectionDomain

/// Sprint 5.2: backs `WeeklyReflectionFormView`. There is no existing
/// reflection UI anywhere in the codebase to reuse (verified before
/// implementing) — this is the first, and per constraint the only,
/// `WeeklyReflection` form, used for both starting a new one and
/// editing an existing one depending on whether `existing` was passed
/// to `init`.
@MainActor
@Observable
public final class WeeklyReflectionFormViewModel {
    public var overallSatisfaction: Int?
    public var loadFelt: Int?
    public var whatWorked: String = ""
    public var whatWasDifficult: String = ""
    public var learning: String = ""
    public var nextWeekConsideration: String = ""
    public private(set) var errorMessage: String?
    public private(set) var isSubmitting = false

    /// True when editing an already-recorded reflection, false when
    /// starting a new one — the view uses this only for its title; the
    /// save path is decided by the same flag.
    public let isEditing: Bool

    /// Sprint 1.1 closeout, Item 1: passed in by the caller, which
    /// already has the athlete's name — no repository re-fetch, no
    /// global selected-athlete state.
    public let athleteDisplayName: String

    private let service: WeeklyReflectionService
    private let athleteId: AthleteId
    private let weekStart: LocalDate
    private let authorId: ActorId

    /// Called after a successful save (create or update) — the Weekly
    /// Review screen uses this to reload.
    public var onSaved: (() -> Void)?

    public init(
        service: WeeklyReflectionService,
        athleteId: AthleteId,
        athleteDisplayName: String,
        weekStart: LocalDate,
        authorId: ActorId,
        existing: WeeklyReflection? = nil
    ) {
        self.athleteDisplayName = athleteDisplayName
        self.service = service
        self.athleteId = athleteId
        self.weekStart = weekStart
        self.authorId = authorId
        self.isEditing = existing != nil
        if let existing {
            overallSatisfaction = existing.overallSatisfaction
            loadFelt = existing.loadFelt
            whatWorked = existing.whatWorked ?? ""
            whatWasDifficult = existing.whatWasDifficult ?? ""
            learning = existing.learning ?? ""
            nextWeekConsideration = existing.nextWeekConsideration ?? ""
        }
    }

    public func save() {
        guard !isSubmitting else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            if isEditing {
                _ = try service.updateWeeklyReflection(
                    forAthlete: athleteId,
                    weekStart: weekStart,
                    overallSatisfaction: overallSatisfaction,
                    loadFelt: loadFelt,
                    whatWorked: nilIfEmpty(whatWorked),
                    whatWasDifficult: nilIfEmpty(whatWasDifficult),
                    learning: nilIfEmpty(learning),
                    nextWeekConsideration: nilIfEmpty(nextWeekConsideration)
                )
            } else {
                _ = try service.recordWeeklyReflection(
                    athleteId: athleteId,
                    weekStart: weekStart,
                    authorId: authorId,
                    overallSatisfaction: overallSatisfaction,
                    loadFelt: loadFelt,
                    whatWorked: nilIfEmpty(whatWorked),
                    whatWasDifficult: nilIfEmpty(whatWasDifficult),
                    learning: nilIfEmpty(learning),
                    nextWeekConsideration: nilIfEmpty(nextWeekConsideration),
                    visibility: .privateToAthlete
                )
            }
            onSaved?()
        } catch let error as WeeklyReflectionServiceError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = WeeklyReviewStrings.genericError
        }
    }

    private func nilIfEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func message(for error: WeeklyReflectionServiceError) -> String {
        switch error {
        case .weeklyReflectionAlreadyExists, .weeklyReflectionNotFound, .invalidField:
            return WeeklyReviewStrings.genericError
        }
    }
}
