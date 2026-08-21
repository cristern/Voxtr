import SwiftData
import SwiftUI
import VoxtrCoreContracts
import VoxtrCoreReferenceData

/// Shared presentation for the canonical activity identity tuple.
/// The bindings remain the owning form/ViewModel state; the only local
/// state is the read-only canonical Sport list used to render choices.
@MainActor
struct ActivityIdentityInputView: View {
    @Environment(\.modelContext) private var modelContext

    @Binding var sportId: SportId?
    @Binding var activityType: ActivityType
    @Binding var activityName: String

    let availableActivityTypes: [ActivityType]
    let accessibilityPrefix: String

    @State private var sports: [Sport] = []

    init(
        sportId: Binding<SportId?>,
        activityType: Binding<ActivityType>,
        activityName: Binding<String>,
        availableActivityTypes: [ActivityType] = ActivityType.selectableCases,
        accessibilityPrefix: String
    ) {
        _sportId = sportId
        _activityType = activityType
        _activityName = activityName
        self.availableActivityTypes = availableActivityTypes
        self.accessibilityPrefix = accessibilityPrefix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sport (optional)")
                .font(VoxtrTypography.metadata)
                .foregroundStyle(VoxtrColor.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sports) { sport in
                        Button(sport.displayName) {
                            sportId = sport.sportId
                        }
                        .buttonStyle(.bordered)
                        .tint(sportId == sport.sportId ? VoxtrColor.accent : VoxtrColor.textSecondary)
                        .accessibilityAddTraits(sportId == sport.sportId ? .isSelected : [])
                    }

                    Menu("More…") {
                        Button("No sport") {
                            sportId = nil
                        }
                        Divider()
                        ForEach(sports) { sport in
                            Button(sport.displayName) {
                                sportId = sport.sportId
                            }
                        }
                    }
                    .accessibilityIdentifier("\(accessibilityPrefix)SportPicker")
                }
            }

            if let selectedSportName {
                Text("Selected: \(selectedSportName)")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            } else {
                Text("No sport selected")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
            }

            Picker("Activity type", selection: $activityType) {
                ForEach(availableActivityTypes, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .accessibilityIdentifier("\(accessibilityPrefix)TypePicker")

            TextField("Activity Name (optional)", text: $activityName)
                .accessibilityIdentifier("\(accessibilityPrefix)TitleField")
        }
        .onAppear(perform: loadSports)
    }

    private var selectedSportName: String? {
        guard let sportId else { return nil }
        return sports.first(where: { $0.sportId == sportId })?.displayName
    }

    private func loadSports() {
        sports = (try? SportRepository(modelContext: modelContext).fetchAllSports()) ?? []
    }
}
