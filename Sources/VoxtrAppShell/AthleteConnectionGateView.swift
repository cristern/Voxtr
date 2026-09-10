import SwiftUI

/// Athlete App Shell / UX Foundation: the calm, full-screen connection
/// gate — the ENTIRE AthleteApp experience whenever
/// `AthleteShellRoute.route(for:)` resolves to `.gate` (i.e. whenever
/// `AthleteRuntimeSession.state` is not `.connected`). Replaces the
/// previous small debug-header-over-placeholder-list composition
/// (`AthleteConnectionStatusView`, removed this round) as the PRIMARY
/// unconnected experience — never a small status strip above stale
/// Sprint-0 content.
///
/// Never shows a populated athlete experience beneath it, never creates
/// local identity state, never shows raw CloudKit errors or IDs —
/// `AthleteConnectionLifecycleError.presentationSafeDescription` already
/// guarantees the last point (see that type's own doc comment). The
/// "Scan connection code" action is the SAME existing action this app
/// already had; this view only relocates/restyles its presentation, it
/// never changes what tapping it does.
struct AthleteConnectionGateView: View {
    let state: AthleteConnectionRuntimeState
    let onScanConnectionCode: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(title)
                    .font(VoxtrTypography.screenTitle)
                    .foregroundStyle(VoxtrColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(VoxtrTypography.body)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            if isConnecting {
                ProgressView()
                    .padding(.top, 4)
                    .accessibilityIdentifier("athleteConnection.progress")
            }

            if showsScanButton {
                Button("Scan connection code", action: onScanConnectionCode)
                    .buttonStyle(.borderedProminent)
                    .tint(VoxtrColor.accent)
                    .accessibilityIdentifier("athleteConnection.scanButton")
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .voxtrScreenBackground()
        .accessibilityIdentifier("athleteConnection.gate")
    }

    private var iconName: String {
        switch state {
        case .notConnected, .lifecycleServiceNotReady:
            return "personalhotspot.slash"
        case .connecting:
            return "personalhotspot"
        case .failed:
            return "exclamationmark.triangle"
        case .connected:
            // Structurally unreachable in practice — `AthleteRootView`
            // only presents this view for `AthleteShellRoute.gate`,
            // which never includes `.connected` (see that type's own
            // `route(for:)`). Handled explicitly rather than
            // force-unwrapped/crashed, matching this codebase's own
            // "never force-unwrap on display-only code" convention.
            return "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch state {
        case .notConnected, .lifecycleServiceNotReady, .connecting:
            return .secondary
        case .failed:
            return .orange
        case .connected:
            return .green
        }
    }

    private var title: String {
        switch state {
        case .notConnected, .lifecycleServiceNotReady:
            return "Connect this app"
        case .connecting:
            return "Connecting…"
        case .failed:
            return "Couldn't connect"
        case .connected:
            return "Connected"
        }
    }

    private var message: String {
        switch state {
        case .notConnected, .lifecycleServiceNotReady:
            return "Scan the connection code shown on your Vǫxtr profile to get started."
        case .connecting:
            return "Confirming your connection."
        case .failed(let error):
            return error.presentationSafeDescription
        case .connected:
            return ""
        }
    }

    private var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }

    /// PR #86 follow-up (lead review): the scan action stays available
    /// after a recoverable failure AND while `.lifecycleServiceNotReady`
    /// — never a dead end. `.lifecycleServiceNotReady` is a real
    /// startup-timing race (a CKShare acceptance callback arrived before
    /// `AthleteRootView` finished calling `configure(lifecycleService:)`
    /// — see that case's own doc comment on
    /// `AthleteConnectionRuntimeState`) and nothing here — no timer, no
    /// forced state mutation — clears it on its own. But
    /// `CompositionRoot`/`configure(lifecycleService:)` finish during
    /// the very first render pass, long before an athlete can actually
    /// see and tap this button, so re-scanning at that point runs
    /// through the EXACT SAME existing scan → metadata resolution →
    /// `AthleteRuntimeSession.handleAcceptedCloudKitShare` pipeline as
    /// `.notConnected` — no second retry mechanism, no new connection
    /// semantics — and by then the service is configured, so the scan
    /// succeeds normally. Previously this case showed the same "Connect
    /// this app" / scan instruction as `.notConnected` with NO action at
    /// all, a dead end this fixes.
    ///
    /// Not shown while `.connecting` (already in flight — no fake
    /// percentage/countdown here either, only the calm `ProgressView`
    /// above) — the one case that must never expose a duplicate/re-entry
    /// action.
    private var showsScanButton: Bool {
        Self.showsScanButton(for: state)
    }

    /// Pure/no I/O — separated out from the computed property above so
    /// this decision can be unit-tested directly (see
    /// `AthleteShellRoutingTests`'s established pattern for exactly this
    /// separation), without standing up any SwiftUI/UI-test
    /// infrastructure for a type this codebase otherwise never unit
    /// tests directly.
    static func showsScanButton(for state: AthleteConnectionRuntimeState) -> Bool {
        switch state {
        case .notConnected, .failed, .lifecycleServiceNotReady:
            return true
        case .connecting, .connected:
            return false
        }
    }
}
