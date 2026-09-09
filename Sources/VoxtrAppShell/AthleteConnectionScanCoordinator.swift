import CloudKit
import Foundation
import VoxtrCore

/// Athlete Connection QR-first V1: the ONE orchestration seam between "a
/// QR scanner emitted this raw string" and the EXISTING, unmodified
/// acceptance pipeline (`AthleteRuntimeSession
/// .handleAcceptedCloudKitShare(_:)` — the same entry point iOS's own
/// system share-acceptance callback already uses). This coordinator
/// invents no second acceptance/identity-binding path: it only (1)
/// structurally validates the scanned text (`AthleteConnectionQRCode
/// .validate`), (2) resolves it to real `CKShare.Metadata` via
/// `CloudKitTransport.fetchShareMetadata(for:)` (Apple's own public,
/// out-of-band share-resolution API), and (3) hands that metadata to the
/// SAME production `AthleteRuntimeSession` entry point. Exact-athlete
/// binding, sibling-safety, and duplicate-identity prevention all remain
/// entirely owned by the existing B2.2 → B2.3 → B2.4 chain this
/// coordinator merely triggers — never reimplemented here.
///
/// XCTEST-SAFETY: `handleScannedText(_:transport:session:)` performs real
/// CloudKit network I/O (`fetchShareMetadata`) and, on success, the real
/// B2.2 → B2.3 → B2.4 chain — matching this codebase's established B1/B2
/// convention, it is never exercised in a unit test. What IS fully
/// unit-testable is the pure structural validation it delegates to first
/// (`AthleteConnectionQRCode.validate`), which never touches CloudKit.
@MainActor
public enum AthleteConnectionScanCoordinator {

    /// Every distinct reason THIS coordinator's own two steps (validate,
    /// resolve metadata) did not reach the acceptance pipeline at all —
    /// distinct from a later failure INSIDE that pipeline, which is
    /// already reported via `session.state == .failed(...)` and needs no
    /// separate case here.
    public enum ScanIntakeError: Equatable {
        /// The scanned text is not a supported Vǫxtr connection code —
        /// see `AthleteConnectionQRCode.ValidationError` for exactly why.
        case invalidCode
        /// `CloudKitTransport.fetchShareMetadata(for:)` failed — a
        /// network/iCloud-availability failure, or the URL, while
        /// structurally plausible, does not resolve to a real share.
        case shareMetadataFetchFailed
    }

    /// Returns `nil` when the scanned text was successfully resolved AND
    /// handed to `session.handleAcceptedCloudKitShare(_:)` — the caller
    /// then reads `session.state` (already settled to `.connected` or
    /// `.failed` by the time this returns, since that method awaits the
    /// full chain) to know the outcome. Returns a `ScanIntakeError` when
    /// this coordinator's OWN two steps never reached that pipeline at
    /// all — a clearly different failure surface from a lifecycle
    /// failure, never conflated with one.
    public static func handleScannedText(
        _ scannedText: String,
        transport: CloudKitTransport,
        session: AthleteRuntimeSession
    ) async -> ScanIntakeError? {
        switch AthleteConnectionQRCode.validate(scannedText) {
        case .failure:
            return .invalidCode
        case .success(let url):
            let metadata: CKShare.Metadata
            do {
                metadata = try await transport.fetchShareMetadata(for: url)
            } catch {
                return .shareMetadataFetchFailed
            }
            await session.handleAcceptedCloudKitShare(metadata)
            return nil
        }
    }
}
