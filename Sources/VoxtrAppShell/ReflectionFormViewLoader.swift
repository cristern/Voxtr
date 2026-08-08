import SwiftUI
import VoxtrCoreContracts
import VoxtrReflectionDomain

/// Sprint 1 (Vǫxtr Parent continuation), Part 3: the direct path from
/// an Athlete Home's "Add Reflection" to that athlete's reflection
/// workflow — reached without first going through Weekly Review.
/// Fetches whatever reflection already exists for this athlete/week (if
/// any) before constructing `WeeklyReflectionFormViewModel`, the same
/// small local-loading pattern `ActivityDetailViewLoader` already
/// established for resolving state before showing a form. If a
/// reflection already exists, the form opens pre-filled for editing —
/// "open/view/edit that reflection directly" — rather than creating a
/// second, conflicting one.
public struct ReflectionFormViewLoader: View {
    let athleteId: AthleteId
    let weekStart: LocalDate
    let authorId: ActorId
    let weeklyReflectionService: WeeklyReflectionService
    @State private var viewModel: WeeklyReflectionFormViewModel?

    public init(
        athleteId: AthleteId,
        weekStart: LocalDate,
        authorId: ActorId,
        weeklyReflectionService: WeeklyReflectionService
    ) {
        self.athleteId = athleteId
        self.weekStart = weekStart
        self.authorId = authorId
        self.weeklyReflectionService = weeklyReflectionService
    }

    public var body: some View {
        Group {
            if let viewModel {
                WeeklyReflectionFormView(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard viewModel == nil else { return }
            let existing = try? weeklyReflectionService.fetchWeeklyReflection(forAthlete: athleteId, weekStart: weekStart)
            viewModel = WeeklyReflectionFormViewModel(
                service: weeklyReflectionService,
                athleteId: athleteId,
                weekStart: weekStart,
                authorId: authorId,
                existing: existing ?? nil
            )
        }
    }
}
