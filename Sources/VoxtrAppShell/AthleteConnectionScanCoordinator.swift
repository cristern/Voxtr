import CloudKit
import Foundation
import VoxtrCore

/// Athlete Connection QR-first V1 (PR #84 follow-up — testability seam):
/// the ONE orchestration seam between "a QR scanner emitted this raw
/// string" and the EXISTING, unmodified acceptance pipeline
/// (`AthleteRuntimeSession.handleAcceptedCloudKitShare(_:)` — the same
/// entry point iOS's own system share-acceptance callback already uses).
/// This coordinator invents no second acceptance/identity-binding path:
/// it only (1) structurally validates the scanned text
/// (`AthleteConnectionQRCode.validate`), (2) resolves it to real metadata
/// via a small injected closure — production always supplies
/// `CloudKitTransport.fetchShareMetadata(for:)`, Apple's own public,
/// out-of-band share-resolution API — and (3) hands that metadata to
/// another small injected closure — production always supplies
/// `AthleteRuntimeSession.handleAcceptedCloudKitShare(_:)`. Exact-athlete
/// binding, sibling-safety, and duplicate-identity prevention all remain
/// entirely owned by the existing B2.2 → B2.3 → B2.4 chain this
/// coordinator merely triggers — never reimplemented here.
///
/// TESTABILITY SEAM (PR #84 follow-up): `handleScannedText(_:
/// resolveShareMetadata:handleAcceptedShare:)` is generic over `Metadata`
/// PURELY so it can be exercised in a unit test — `CKShare.Metadata`
/// itself has no public initializer reachable without a real accepted
/// share (matching this codebase's own established B1/B2 XCTEST-SAFETY
/// convention), so a test substitutes any small placeholder type
/// instead, proving call-count/routing/value-identity semantics without
/// ever fabricating CloudKit business identity. Production never touches
/// this generic entry point directly — the concrete overload below
/// (`transport:session:`) is the ONE production adapter, and it always
/// resolves `Metadata == CKShare.Metadata`, inferred automatically from
/// the two closures it builds. This is not a second production
/// pipeline: both overloads run the exact same body; the concrete one
/// only supplies concrete closures.
///
/// RE-ENTRANCE GUARD: `isHandlingScan` mirrors `AthleteFamilyManagementViewModel
/// .isConnectingAthleteApp`'s own established convention exactly —
/// deliberately not left to the caller's own UI-level guard
/// (`AthleteConnectionScanView.isProcessingScan`) alone, so a second
/// overlapping call into this SAME coordinator instance (e.g. two scan
/// events reported before the first settles) still cannot invoke the
/// acceptance handler a second time. Each `AthleteConnectionScanView`
/// owns exactly one coordinator instance for its own lifetime (matching
/// how that view already owns its other per-screen `@State`) — this is
/// per-screen-session state, never a cross-screen/global singleton.
///
/// XCTEST-SAFETY: the concrete `transport:session:` overload performs
/// real CloudKit network I/O and, on success, the real B2.2 → B2.3 →
/// B2.4 chain — matching this codebase's established convention, it is
/// never exercised in a unit test. What IS fully unit-testable is (a)
/// the pure structural validation this delegates to first
/// (`AthleteConnectionQRCode.validate`), and (b), as of this seam, the
/// generic `handleScannedText` overload's own routing/call-count/re-entrance
/// semantics, using injected closures that never touch CloudKit.
@MainActor
public final class AthleteConnectionScanCoordinator {

    /// Every distinct reason THIS coordinator's own steps did not reach
    /// the acceptance pipeline at all — distinct from a later failure
    /// INSIDE that pipeline, which is already reported via
    /// `session.state == .failed(...)` and needs no separate case here.
    public enum ScanIntakeError: Equatable {
        /// The scanned text is not a supported Vǫxtr connection code —
        /// see `AthleteConnectionQRCode.ValidationError` for exactly why.
        case invalidCode
        /// Share-metadata resolution failed — a network/iCloud-availability
        /// failure, or the URL, while structurally plausible, does not
        /// resolve to a real share.
        case shareMetadataFetchFailed
        /// This coordinator instance is already handling an earlier scan
        /// that has not yet settled — the acceptance handler is NOT
        /// invoked for this call. See this type's own RE-ENTRANCE GUARD
        /// doc comment.
        case alreadyInFlight
    }

    private var isHandlingScan = false

    public init() {}

    /// Returns `nil` when the scanned text was successfully resolved AND
    /// handed to `handleAcceptedShare` — the caller then reads its own
    /// downstream state (for production, `AthleteRuntimeSession.state`,
    /// already settled to `.connected` or `.failed` by the time this
    /// returns, since `handleAcceptedShare` is awaited to completion) to
    /// know the outcome. Returns a `ScanIntakeError` when this
    /// coordinator's OWN steps never reached that handler at all — a
    /// clearly different failure surface from a lifecycle failure, never
    /// conflated with one.
    ///
    /// Non-escaping closure parameters — read and invoked synchronously
    /// within this one call, never stored — so no `Metadata: Sendable`
    /// constraint is needed; nothing here crosses an actor boundary.
    public func handleScannedText<Metadata>(
        _ scannedText: String,
        resolveShareMetadata: (URL) async throws -> Metadata,
        handleAcceptedShare: (Metadata) async -> Void
    ) async -> ScanIntakeError? {
        guard !isHandlingScan else { return .alreadyInFlight }
        isHandlingScan = true
        defer { isHandlingScan = false }

        switch AthleteConnectionQRCode.validate(scannedText) {
        case .failure:
            return .invalidCode
        case .success(let url):
            let metadata: Metadata
            do {
                metadata = try await resolveShareMetadata(url)
            } catch {
                // Observability follow-up (real two-device TestFlight
                // validation: AthleteApp showed "Couldn't confirm this
                // code with iCloud" with no way to tell which CKError
                // actually occurred): reuses the SAME canonical
                // `CloudKitErrorDiagnostics` classify/format pair already
                // established for every other CloudKit-facing failure in
                // this codebase (`FamilyWorkspaceOwnerShareCoordinator`,
                // `CloudKitTransport`, `AthleteFamilyManagementViewModel`)
                // — never a second/parallel diagnostic mechanism. `.appShell`
                // matches `AthleteFamilyManagementViewModel`'s own
                // established convention for a CloudKit-flavored
                // diagnostic reported from a `VoxtrAppShell` type (as
                // opposed to `.cloudKit`, used by types that live in
                // `VoxtrCore`'s own CloudKit layer). Runs identically for
                // both the generic test-exercised overload (an
                // NSError-bridged `error`, harmless to classify/log) and
                // the concrete production adapter (a real `CKError`) —
                // this is the ONE catch site both share, never a second
                // one added for production only. `.shareMetadataFetchFailed`
                // and the existing user-facing copy are both unchanged.
                let diagnostic = CloudKitErrorDiagnostics.classify(stage: "athlete-scan-metadata-fetch", error: error)
                VoxtrLog.logger(.appShell).error("\(CloudKitErrorDiagnostics.format(diagnostic), privacy: .public)")
                return .shareMetadataFetchFailed
            }
            await handleAcceptedShare(metadata)
            return nil
        }
    }

    /// The ONE production adapter — calls EXACTLY
    /// `CloudKitTransport.fetchShareMetadata(for:)` and
    /// `AthleteRuntimeSession.handleAcceptedCloudKitShare(_:)`, in that
    /// order, never a second pipeline. `Metadata` is inferred as
    /// `CKShare.Metadata` from `transport.fetchShareMetadata(for:)`'s own
    /// return type.
    public func handleScannedText(
        _ scannedText: String,
        transport: CloudKitTransport,
        session: AthleteRuntimeSession
    ) async -> ScanIntakeError? {
        await handleScannedText(
            scannedText,
            resolveShareMetadata: { url in try await transport.fetchShareMetadata(for: url) },
            handleAcceptedShare: { metadata in await session.handleAcceptedCloudKitShare(metadata) }
        )
    }
}
