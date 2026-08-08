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
///
/// Sprint 1.1 closeout, Item 1: `athleteDisplayName` is required from
/// every caller — each one already has the athlete's name at hand, so
/// this never duplicates athlete state or introduces a global
/// selected-athlete workaround.
public struct ReflectionFormViewLoader: View {
    let athleteId: AthleteId
    let athleteDisplayName: String
    let weekStart: LocalDate
    let authorId: ActorId
    let weeklyReflectionService: WeeklyReflectionService
    @State private var viewModel: WeeklyReflectionFormViewModel?

    public init(
        athleteId: AthleteId,
        athleteDisplayName: String,
        weekStart: LocalDate,
        authorId: ActorId,
        weeklyReflectionService: WeeklyReflectionService
    ) {
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
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
                athleteDisplayName: athleteDisplayName,
                weekStart: weekStart,
                authorId: authorId,
                existing: existing ?? nil
            )
        }
    }
}
