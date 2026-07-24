import SwiftUI
import VoxtrParentDomain
import VoxtrAthleteDomain

/// S1.4: shown when `FamilyRestorationState` is `.existingFamily`.
/// Deliberately minimal — this is not Weekly Review, not a dashboard,
/// not any Sprint 2+ feature. Just proof that the family the parent
/// created is really there after a relaunch.
public struct FamilyHomeView: View {
    public let family: RestoredFamily

    public init(family: RestoredFamily) {
        self.family = family
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Parent") {
                    Text(family.parent.givenName)
                }
                Section("Athlete") {
                    Text(family.athlete.givenName)
                }
            }
            .navigationTitle(family.workspace.displayName)
        }
    }
}
