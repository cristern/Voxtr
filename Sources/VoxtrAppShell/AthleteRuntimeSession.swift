import UIKit
import CloudKit
import VoxtrCore

/// Athlete Connection Foundation B2.5: the lifecycle state of AthleteApp's
/// connection to its Parent-owned `FamilyWorkspace`, as observed by
/// `AthleteRuntimeSession`. Deliberately small and technical — no
/// synthetic readiness/completion scores, matching this project's
/// existing UX principles (Calm by Default; no manipulative engagement
/// signals).
///
/// Not `Equatable`/`Sendable`: `.failed` carries
/// `AthleteConnectionLifecycleError`, which wraps an existential `Error`
/// for the same reason that type itself is not `Equatable`/`Sendable` —
/// see its own doc comment. Only ever read/written on `@MainActor`
/// (`AthleteRuntimeSession`'s own isolation), so this is not a
/// limitation in practice.
public enum AthleteConnectionRuntimeState {
    /// No active actor — either never attempted, or a previous attempt
    /// was superseded by a fresh one before it resolved. This is the
    /// initial state; nothing infers an actor at launch (see
    /// `AthleteRuntimeSession`'s own doc comment).
    case notConnected
    /// A `connect` sequence is currently in flight. Does not fabricate
    /// or reuse a previous actor while pending.
    case connecting
    /// The full B2.2 → B2.3 → B2.4 chain succeeded — `CurrentSessionActor`
    /// is this app's sole active runtime actor truth.
    case connected(CurrentSessionActor)
    /// The chain failed at some stage — see `AthleteConnectionLifecycleError`
    /// for exactly which. Clears any previous `.connected` actor; never
    /// leaves a stale one in place.
    case failed(AthleteConnectionLifecycleError)
    /// A CKShare acceptance callback arrived before `CompositionRoot`
    /// finished building and `AthleteRootView` had a chance to call
    /// `configure(lifecycleService:)` — a real (if rare) startup-timing
    /// race between UIKit's app-delegate lifecycle and SwiftUI's async
    /// composition step, not a fabricated case. Reported explicitly
    /// rather than silently dropping the callback or fabricating
    /// success.
    case lifecycleServiceNotReady
}

/// Athlete Connection Foundation B2.5: the ONE authoritative AthleteApp
/// runtime holder for `CurrentSessionActor` — owns runtime PRESENCE of
/// the actor, not business identity. Holds exactly one thing beyond
/// lifecycle state: `CurrentSessionActor` itself, already carrying every
/// stable ID (`participantId`, `workspaceId`, `role`, `linkedAthleteId`)
/// a caller needs — see that type's own doc comment. Deliberately does
/// NOT duplicate `participantId`/`athleteId`/`workspaceId` as separate
/// stored properties.
///
/// `.shared`: `@UIApplicationDelegateAdaptor`-constructed delegates
/// (`AthleteCloudKitShareAppDelegate` below) have no path to receive
/// constructor-injected dependencies — SwiftUI constructs them with a
/// bare `init()` — so SOME hand-off point between UIKit's app-delegate
/// construction and SwiftUI's async `CompositionRoot` composition is
/// unavoidable. This mirrors `VoxtrOrientationPolicy.shared`'s own,
/// already-accepted solution to the identical structural problem (see
/// that type's own doc comment) rather than inventing a new pattern.
/// Holds no injected BUSINESS dependency itself — `configure(lifecycleService:)`
/// is called exactly once, by `AthleteRootView`, after `CompositionRoot`
/// finishes building.
///
/// APP LAUNCH BEHAVIOR: nothing here infers or restores an actor at
/// launch. The authoritative activation trigger is
/// `handleAcceptedCloudKitShare(_:)`, invoked only by a real CKShare
/// acceptance callback. If AthleteApp relaunches after a previously
/// successful connection, `state` starts back at `.notConnected` — no
/// canonical persisted actor-restoration mechanism exists yet for
/// AthleteApp (unlike `FamilyRestorationService` on the Parent side),
/// and this slice does not invent one (in particular, no `UserDefaults`
/// persistence of `participantId` — see this PR's own delivery report
/// for why relaunch restoration is an explicit, bounded next step
/// rather than solved here).
@MainActor
@Observable
public final class AthleteRuntimeSession {
    public static let shared = AthleteRuntimeSession()

    public private(set) var state: AthleteConnectionRuntimeState = .notConnected

    private var lifecycleService: AthleteConnectionLifecycleService?
    private let log = VoxtrLog.logger(.appShell)

    /// Not `private`: `.shared` remains the one PRODUCTION instance, but
    /// `AthleteRuntimeSessionTests` (`@testable import`) constructs
    /// separate, isolated instances of its own — testing the state
    /// machine against a shared, cross-test, cross-suite singleton would
    /// be inherently order-dependent/flaky, matching this codebase's own
    /// established test-only-seam convention (e.g. `ParentWorkspaceRepository`'s
    /// internal `saveOverride` overloads) rather than a new pattern.
    init() {}

    /// Called once, by `AthleteRootView`, after `CompositionRoot`
    /// finishes building — never at `CompositionRoot.build()` itself
    /// (see `AthleteConnectionLifecycleService`'s own registration
    /// comment in `CompositionRoot`). Idempotent: safe to call again
    /// with the same (singleton-registered) service.
    public func configure(lifecycleService: AthleteConnectionLifecycleService) {
        self.lifecycleService = lifecycleService
    }

    /// The sole PRODUCTION activation trigger for this slice — invoked
    /// only by `AthleteCloudKitShareAppDelegate` in response to a real
    /// CKShare acceptance callback, never automatically at launch. Real
    /// CloudKit I/O (via `AthleteConnectionLifecycleService.connect(from:)`),
    /// so — matching that method's own doc comment — never exercised
    /// from a unit test; `handleAcceptedShare(_:)` below is the
    /// directly-testable continuation of the same state-machine logic.
    func handleAcceptedCloudKitShare(_ metadata: CKShare.Metadata) async {
        guard let lifecycleService else {
            log.error("AthleteRuntimeSession received a CKShare acceptance callback before CompositionRoot finished configuring it.")
            state = .lifecycleServiceNotReady
            return
        }
        await run { try await lifecycleService.connect(from: metadata) }
    }

    /// The B2.3 → B2.4 continuation, taking an ALREADY-resolved B2.2
    /// result directly — no `CKShare.Metadata`/CloudKit I/O, so this is
    /// fully unit-testable (see `AthleteConnectionLifecycleService
    /// .connect(acceptedShare:)`'s own doc comment for why this split
    /// exists). Not `private` so `AthleteRuntimeSessionTests`
    /// (`@testable import`) can drive `state` transitions directly.
    func handleAcceptedShare(_ acceptedShare: AcceptedFamilyWorkspaceShare) async {
        guard let lifecycleService else {
            log.error("AthleteRuntimeSession received an accepted share before CompositionRoot finished configuring it.")
            state = .lifecycleServiceNotReady
            return
        }
        await run { try lifecycleService.connect(acceptedShare: acceptedShare) }
    }

    /// The one place `state` transitions through `.connecting` →
    /// `.connected`/`.failed` — shared by both entry points above so
    /// that state-machine logic is never duplicated between the
    /// production (CloudKit-backed) and test (pre-resolved) paths.
    private func run(_ operation: () async throws -> CurrentSessionActor) async {
        state = .connecting
        do {
            state = .connected(try await operation())
        } catch let error as AthleteConnectionLifecycleError {
            log.error("Athlete connection lifecycle failed: \(String(describing: error), privacy: .public)")
            state = .failed(error)
        } catch {
            // Both `connect(from:)` and `connect(acceptedShare:)` are
            // declared `throws` (untyped), so Swift requires this
            // catch-all for exhaustiveness even though every actual
            // throw site inside `AthleteConnectionLifecycleService`
            // wraps into `AthleteConnectionLifecycleError` above — not a
            // reachable-in-practice branch, just the language's own
            // exhaustiveness rule.
            log.error("Athlete connection lifecycle failed with an unexpected error: \(String(describing: error), privacy: .public)")
            state = .failed(.shareAcceptanceOrResolutionFailed(error))
        }
    }
}

/// Athlete Connection Foundation B2.5: the thin UIKit adapter that
/// bridges iOS's real CKShare acceptance callback into
/// `AthleteRuntimeSession`. Mirrors `VoxtrOrientationAppDelegate`'s own
/// established shape exactly (`NSObject, UIApplicationDelegate`,
/// `nonisolated` witness bridging into `@MainActor` state) — the only
/// difference is bridging into ASYNC work via a structured `Task { @MainActor
/// in ... }` rather than a synchronous `MainActor.assumeIsolated` read,
/// since this callback must await the real B2.2 → B2.3 → B2.4 chain.
/// `Task { @MainActor in }` (not `Task.detached`) is a STRUCTURED child
/// task of the current context — it does not lose ordering the way a
/// detached task or `DispatchQueue.main.async` chain could.
///
/// Deliberately contains NO business/domain logic itself — it does
/// exactly one thing: hand the metadata to `AthleteRuntimeSession.shared`.
/// `AthleteApp` never adds this adaptor to `ParentApp` — Parent-side
/// CloudKit sharing (B2.1, owner-side) has no equivalent participant-
/// acceptance callback to receive.
public final class AthleteCloudKitShareAppDelegate: NSObject, UIApplicationDelegate {
    public override init() {
        super.init()
    }

    public nonisolated func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task { @MainActor in
            await AthleteRuntimeSession.shared.handleAcceptedCloudKitShare(cloudKitShareMetadata)
        }
    }
}
