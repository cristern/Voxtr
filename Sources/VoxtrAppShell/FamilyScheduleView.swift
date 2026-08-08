import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// Sprint 1 completion package, Part 5, extended in Sprint 1.1 P1.
/// "Family Schedule" — a forward-looking overview of upcoming planned
/// activity across every active athlete, grouped clearly by date.
/// Deliberately not a calendar grid, per this work's own constraint
/// ("Vǫxtr is a development/planning product, not Google Calendar").
///
/// Now shows both real, planned activities AND recurring occurrences
/// that have not yet been materialized into a real `PlannedActivity`
/// (see `FamilyScheduleRow`'s own doc comment). A `.planned` row opens
/// the SAME shared `ActivityDetailView` every other surface uses, via
/// `ActivityDetailViewLoader` — "tapping an occurrence uses the
/// canonical Activity Detail path where the domain model supports it."
/// A `.recurringSuggestion` row has no `PlannedActivityId` yet, so it
/// is shown but not tappable into Activity Detail — accepting it
/// remains that athlete's Weekly Plan screen's own job, not duplicated
/// here.
public struct FamilyScheduleView: View {
    @State private var viewModel: FamilyScheduleViewModel
    private let actorId: ActorId
    private let planningService: PlanningService
    private let trainingService: TrainingService

    public init(
        viewModel: FamilyScheduleViewModel,
        actorId: ActorId,
        planningService: PlanningService,
        trainingService: TrainingService
    ) {
        _viewModel = State(initialValue: viewModel)
        self.actorId = actorId
        self.planningService = planningService
        self.trainingService = trainingService
    }

    public var body: some View {
        Form {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("familySchedule.errorMessage")
                }
            }

            if viewModel.dayGroups.isEmpty {
                Section {
                    Text("No upcoming activities planned yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(viewModel.dayGroups) { group in
                    Section(group.date.isoString) {
                        ForEach(group.rows) { row in
                            scheduleRow(row)
                        }
                    }
                    .accessibilityIdentifier("familySchedule.dayGroup.\(group.id)")
                }
            }
        }
        .navigationTitle("Family Schedule")
        .onAppear {
            viewModel.loadSchedule()
        }
    }

    @ViewBuilder
    private func scheduleRow(_ row: FamilyScheduleRow) -> some View {
        switch row {
        case .planned(let familyRow):
            NavigationLink {
                ActivityDetailViewLoader(
                    plannedActivity: familyRow.plannedActivity,
                    isCompleted: familyRow.isCompleted,
                    athleteId: familyRow.athleteId,
                    athleteDisplayName: familyRow.athleteName,
                    actorId: actorId,
                    planningService: planningService,
                    trainingService: trainingService
                )
            } label: {
                rowContent(
                    athleteName: familyRow.athleteName,
                    title: familyRow.plannedActivity.title,
                    subtitle: Self.rowSubtitle(
                        startLocalTime: familyRow.plannedActivity.startLocalTime,
                        location: familyRow.plannedActivity.location,
                        isCompleted: familyRow.isCompleted
                    )
                )
            }
            .accessibilityIdentifier("familySchedule.activityRow.\(row.id)")
        case .recurringSuggestion(_, _, let athleteName, let suggestion):
            // Not a NavigationLink — no real PlannedActivity exists yet
            // to open Activity Detail for.
            HStack {
                rowContent(
                    athleteName: athleteName,
                    title: suggestion.title,
                    subtitle: Self.rowSubtitle(startLocalTime: suggestion.startLocalTime, location: nil, isCompleted: false)
                )
                Spacer()
                Text("Recurring")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("familySchedule.recurringBadge.\(row.id)")
            }
            .accessibilityIdentifier("familySchedule.recurringRow.\(row.id)")
        }
    }

    private func rowContent(athleteName: String, title: String, subtitle: String) -> some View {
        HStack {
            // Athlete name leads each row — the simplest, most direct
            // way to make multiple athletes visually distinguishable in
            // one shared list, without separate per-athlete schedules.
            Text(athleteName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func rowSubtitle(startLocalTime: LocalTime?, location: String?, isCompleted: Bool) -> String {
        var parts: [String] = []
        if let startLocalTime {
            parts.append(String(format: "%02d:%02d", startLocalTime.hour, startLocalTime.minute))
        }
        if let location, !location.isEmpty {
            parts.append(location)
        }
        if isCompleted {
            parts.append("Completed")
        }
        return parts.isEmpty ? "Ready to log" : parts.joined(separator: " · ")
    }
}
