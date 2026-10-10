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
    /// ITMS-90683 fix: the real, AVFoundation-backed scanner view is
    /// supplied by `App/AthleteApp/AthleteApp.swift` (the only place that
    /// links the AthleteApp-only `VoxtrAthleteScanner` product) — see
    /// `AthleteConnectionScannerBuilder`'s own doc comment.
    let makeScannerView: AthleteConnectionScannerBuilder
    @State private var isPresentingScanner = false
    /// Athlete Connection V1 (backend device authorization): a SEPARATE
    /// sheet presentation state from `isPresentingScanner` above —
    /// additive, alongside the existing CKShare scan flow, never a
    /// replacement of it.
    @State private var isPresentingDeviceAuthorizationScanner = false
    /// Athlete hydration/activation integration slice (§5.2): launch +
    /// foreground real online-validation trigger for the backend path's
    /// own restoration flow — never the CKShare path, which has no
    /// persisted restoration mechanism at all (see `AthleteRuntimeSession`'s
    /// own doc comment) and is untouched by this round.
    @Environment(\.scenePhase) private var scenePhase

    public init(root: CompositionRoot, makeScannerView: @escaping AthleteConnectionScannerBuilder) {
        self.root = root
        self.makeScannerView = makeScannerView
    }

    public var body: some View {
        content
            .task {
                AthleteRuntimeSession.shared.configure(
                    lifecycleService: root.container.resolve(AthleteConnectionLifecycleService.self)
                )
                root.container.resolve(AthleteBackendConnectionCoordinator.self).restoreOnLaunchOrForeground()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Foreground re-entry (background/inactive -> active)
                // re-runs the SAME restoration flow as launch — §5.2's
                // own "on every launch AND foreground" requirement.
                // Never triggered by the initial launch transition
                // itself (already covered by `.task` above), avoiding a
                // redundant duplicate attempt on cold start.
                if newPhase == .active {
                    root.container.resolve(AthleteBackendConnectionCoordinator.self).restoreOnLaunchOrForeground()
                }
            }
            .sheet(isPresented: $isPresentingScanner) {
                AthleteConnectionScanView(transport: root.cloudKitTransport, makeScannerView: makeScannerView)
            }
            .sheet(isPresented: $isPresentingDeviceAuthorizationScanner) {
                AthleteDeviceAuthorizationScanView(
                    service: root.container.resolve(AthleteDeviceAuthorizationService.self),
                    connectionCoordinator: root.container.resolve(AthleteBackendConnectionCoordinator.self),
                    makeScannerView: makeScannerView
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        let legacyState = AthleteRuntimeSession.shared.state
        let backendState = root.container.resolve(AthleteBackendConnectionCoordinator.self).state
        switch AthleteShellRoute.route(legacyState: legacyState, backendState: backendState) {
        case .gate:
            AthleteConnectionGateView(
                state: legacyState,
                onScanConnectionCode: { isPresentingScanner = true },
                onStartDeviceAuthorization: { isPresentingDeviceAuthorizationScanner = true }
            )
        case .shell(let actor):
            AthleteShellView(
                actor: actor,
                athleteRepository: root.container.resolve(AthleteRepository.self)
            )
        }
    }
}
