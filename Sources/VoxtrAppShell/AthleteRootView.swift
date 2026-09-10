import SwiftUI
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAthleteDomain

/// Athlete App Shell / UX Foundation: AthleteApp's actual root content.
/// Replaces the previous small debug-header-over-Sprint-0-placeholder
/// composition (`AthleteConnectionStatusView` + `NavigationShellView()`,
/// both removed this round) with a single routing decision —
/// `AthleteShellRoute.route(for:)` (pure, unit-tested separately in
/// `AthleteShellRoutingTests`) — that shows EITHER the full-screen
/// `AthleteConnectionGateView` (not connected / connecting / failed /
/// lifecycle-service-not-ready) OR the connected `AthleteShellView`,
/// never both at once and never a populated athlete experience while
/// unconnected.
///
/// Configures `AthleteRuntimeSession.shared` with the real,
/// `CompositionRoot`-resolved `AthleteConnectionLifecycleService` exactly
/// once `root` is available — never at `CompositionRoot.build()` itself,
/// and never triggers a connection attempt on its own; it only makes the
/// session READY to handle a callback if/when one arrives. This wiring,
/// and the "Scan connection code" sheet presentation below, are both
/// unchanged from before this round — this task does not modify
/// connection/pairing semantics, only what AthleteApp shows for each
/// state.
@MainActor
public struct AthleteRootView: View {
    let root: CompositionRoot
    @State private var isPresentingScanner = false

    public init(root: CompositionRoot) {
        self.root = root
    }

    public var body: some View {
        content
            .task {
                AthleteRuntimeSession.shared.configure(
                    lifecycleService: root.container.resolve(AthleteConnectionLifecycleService.self)
                )
            }
            .sheet(isPresented: $isPresentingScanner) {
                AthleteConnectionScanView(transport: root.cloudKitTransport)
            }
    }

    @ViewBuilder
    private var content: some View {
        let state = AthleteRuntimeSession.shared.state
        switch AthleteShellRoute.route(for: state) {
        case .gate:
            AthleteConnectionGateView(
                state: state,
                onScanConnectionCode: { isPresentingScanner = true }
            )
        case .shell(let actor):
            AthleteShellView(
                actor: actor,
                athleteRepository: root.container.resolve(AthleteRepository.self)
            )
        }
    }
}
