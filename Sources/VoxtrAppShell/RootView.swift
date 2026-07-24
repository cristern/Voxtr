import SwiftUI
import VoxtrCore
import VoxtrParentDomain
import VoxtrAthleteDomain

/// S1.4 requirement 1: `FamilyRestorationState` is the ONLY thing this
/// view switches on — there is no separate "just finished onboarding"
/// flag. After a successful `createFamily`, `refreshRestorationState()`
/// re-queries `FamilyRestorationService` (the same service
/// `CompositionRoot` used at launch) and the view transitions because
/// the source of truth changed, not because of an ad hoc signal.
@MainActor
public struct RootView: View {
    let root: CompositionRoot
    @State private var restorationState: FamilyRestorationState

    public init(root: CompositionRoot) {
        self.root = root
        _restorationState = State(initialValue: root.restorationState)
    }

    public var body: some View {
        switch restorationState {
        case .noExistingFamily:
            NavigationStack {
                CreateFamilyView(viewModel: makeOnboardingViewModel())
            }
        case .existingFamily(let family):
            FamilyHomeView(family: family)
        case .inconsistentGraph(let reason):
            InconsistentFamilyView(reason: reason)
        }
    }

    private func makeOnboardingViewModel() -> CreateFamilyViewModel {
        let coordinator = root.container.resolve(FamilyOnboardingCoordinator.self)
        let viewModel = CreateFamilyViewModel(coordinator: coordinator)
        viewModel.onFamilyCreated = {
            refreshRestorationState()
        }
        return viewModel
    }

    private func refreshRestorationState() {
        let service = root.container.resolve(FamilyRestorationService.self)
        do {
            restorationState = try service.restoreState()
        } catch {
            restorationState = .inconsistentGraph(
                reason: "\(OnboardingStrings.couldNotReloadAfterCreation) \(error.localizedDescription)"
            )
        }
    }
}

/// S1.4: shown when `FamilyRestorationState` is `.inconsistentGraph` —
/// requirement 2/6 (S1.3): never crash, never silently delete. This is
/// deliberately just a message, not a repair flow — deciding what a
/// repair flow should do is out of scope for S1.4.
private struct InconsistentFamilyView: View {
    let reason: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(OnboardingStrings.inconsistentGraphTitle)
                .font(.headline)
                .accessibilityIdentifier("onboarding.inconsistentGraph.title")
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("onboarding.inconsistentGraph.reason")
        }
        .padding()
    }
}
