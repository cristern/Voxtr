import SwiftUI
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// Sprint 1 completion package, Part 5. "Family Schedule" — a
/// forward-looking overview of upcoming planned activity across every
/// active athlete, grouped clearly by date. Deliberately not a
/// calendar grid, per this work's own constraint ("Vǫxtr is a
/// development/planning product, not Google Calendar"). Tapping a row
/// opens the SAME shared `ActivityDetailView` every other surface
/// uses, via `ActivityDetailViewLoader`.
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
                            NavigationLink {
                                ActivityDetailViewLoader(
                                    plannedActivity: row.plannedActivity,
                                    isCompleted: row.isCompleted,
                                    athleteId: row.athleteId,
                                    actorId: actorId,
                                    planningService: planningService,
                                    trainingService: trainingService
                                )
                            } label: {
                                HStack {
                                    // Athlete name leads each row — the
                                    // simplest, most direct way to make
                                    // multiple athletes visually
                                    // distinguishable in one shared list,
                                    // without separate per-athlete
                                    // schedules.
                                    Text(row.athleteName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .leading)
                                    VStack(alignment: .leading) {
                                        Text(row.plannedActivity.title)
                                        Text(Self.rowSubtitle(for: row))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityIdentifier("familySchedule.activityRow.\(row.id)")
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

    private static func rowSubtitle(for row: FamilyHomeRow) -> String {
        var parts: [String] = []
        if let startTime = row.plannedActivity.startLocalTime {
            parts.append(String(format: "%02d:%02d", startTime.hour, startTime.minute))
        }
        if let location = row.plannedActivity.location, !location.isEmpty {
            parts.append(location)
        }
        if row.isCompleted {
            parts.append("Completed")
        }
        return parts.isEmpty ? "Ready to log" : parts.joined(separator: " · ")
    }
}
