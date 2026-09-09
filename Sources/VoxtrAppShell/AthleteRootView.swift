import SwiftUI
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAthleteDomain

/// Athlete Connection Foundation B2.5: AthleteApp's actual root content —
/// replaces `AthleteApp.swift`'s previous direct `NavigationShellView()`
/// call. Still shows the Sprint 0 `NavigationShellView` placeholder
/// content unchanged; ADDS only the minimal Internal Alpha connection
/// status needed to validate the B2.2 → B2.3 → B2.4 chain on a signed
/// TestFlight build (see this PR's own delivery report for the exact
/// validation steps). Deliberately NOT Athlete Home — no Planning/
/// Training/Reflection UI, no athlete chooser, no pairing UX.
///
/// Configures `AthleteRuntimeSession.shared` with the real,
/// `CompositionRoot`-resolved `AthleteConnectionLifecycleService` exactly
/// once `root` is available — never at `CompositionRoot.build()` itself,
/// and never triggers a connection attempt on its own; it only makes the
/// session READY to handle a callback if/when one arrives.
///
/// Athlete Connection QR-first V1: adds the "Scan connection code" entry
/// point (`AthleteConnectionStatusView`'s own button, surfaced whenever
/// there is no active connection) and presents `AthleteConnectionScanView`
/// as a sheet on tap. Resolves `CloudKitTransport` straight off `root`
/// (already a public property, exactly like `AthleteConnectionLifecycleService`
/// above) — this view invents no separate DI registration for it.
@MainActor
public struct AthleteRootView: View {
    let root: CompositionRoot
    @State private var isPresentingScanner = false

    public init(root: CompositionRoot) {
        self.root = root
    }

    public var body: some View {
        VStack(spacing: 0) {
            AthleteConnectionStatusView(
                session: AthleteRuntimeSession.shared,
                athleteRepository: root.container.resolve(AthleteRepository.self),
                onScanConnectionCode: { isPresentingScanner = true }
            )
            Divider()
            NavigationShellView()
        }
        .task {
            AthleteRuntimeSession.shared.configure(
                lifecycleService: root.container.resolve(AthleteConnectionLifecycleService.self)
            )
        }
        .sheet(isPresented: $isPresentingScanner) {
            AthleteConnectionScanView(transport: root.cloudKitTransport)
        }
    }
}

/// The minimal Internal Alpha technical surface itself — deliberately
/// small, calm, and non-visual-design-heavy (matching `NavigationShellView`'s
/// own Sprint 0 placeholder aesthetic). Reads `CurrentSessionActor` only
/// to display it; never stores a separate copy of its identity. Any
/// athlete name shown is resolved fresh, on demand, through the existing
/// canonical `AthleteRepository` — display only, never session identity
/// (see `AthleteRuntimeSession`'s own doc comment on this same point).
/// Never shows raw CloudKit ownerName/share/record IDs — only Vǫxtr's
/// own stable `participantId`/`workspaceId`, truncated, clearly labeled
/// as diagnostic detail.
struct AthleteConnectionStatusView: View {
    let session: AthleteRuntimeSession
    let athleteRepository: AthleteRepository
    /// Athlete Connection QR-first V1: the ONE initial action an
    /// unconnected AthleteApp exposes — surfaced here (never a countdown/
    /// forced-refresh) whenever there is no active connection to show
    /// instead, including after a recoverable failure (retry, not a dead
    /// end).
    let onScanConnectionCode: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch session.state {
            case .notConnected:
                Label("Not connected", systemImage: "personalhotspot.slash")
                    .foregroundStyle(.secondary)
                scanButton
            case .connecting:
                Label("Connecting…", systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            case .connected(let actor):
                Label(connectedTitle(for: actor), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(debugIdentifiers(for: actor))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .failed(let error):
                Label(error.presentationSafeDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                scanButton
            case .lifecycleServiceNotReady:
                Label("Not ready yet", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .accessibilityIdentifier("athleteConnection.status")
    }

    private var scanButton: some View {
        Button("Scan connection code", action: onScanConnectionCode)
            .accessibilityIdentifier("athleteConnection.scanButton")
    }

    /// Display-only lookup: `actor.linkedAthleteId` → `AthleteProfile`
    /// → name. If the lookup fails or the actor has no linked athlete
    /// (should not happen for an `.athlete`-role actor, but this is
    /// read-only display code, not an invariant-enforcing boundary), a
    /// generic "Connected" is shown rather than crashing or fabricating
    /// a name.
    private func connectedTitle(for actor: CurrentSessionActor) -> String {
        guard let linkedAthleteId = actor.linkedAthleteId,
              let athlete = try? athleteRepository.fetchAthlete(byId: linkedAthleteId) else {
            return "Connected"
        }
        return "Connected as \(athlete.preferredName ?? athlete.givenName)"
    }

    private func debugIdentifiers(for actor: CurrentSessionActor) -> String {
        "participant \(actor.participantId.uuidString.prefix(8))… · workspace \(actor.workspaceId.rawValue.uuidString.prefix(8))…"
    }
}
