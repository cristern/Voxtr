import Foundation

/// Athlete Connection QR-first V1: the ONE canonical opaque transport
/// payload a Vǫxtr connection QR code carries — the ALREADY-EXISTING
/// `CKShare.url` produced by `AthleteConnectionOwnerHandoffService
/// .prepareInvitation` (via `AthleteConnectionInvitationHandoff.share.url`),
/// never a new, parallel payload or business-identity envelope. QR is
/// only a nearby presentation/transport mechanism for that canonical
/// handoff — this type performs STRUCTURAL validation only (a plausible
/// CloudKit share link, opaque and unparsed) and never extracts, decodes,
/// or trusts any athlete/participant/workspace identity out of the URL
/// itself. Stable IDs are established only later, by reading them back
/// from the canonical CloudKit records during acceptance (see
/// `FamilyWorkspaceParticipantShareCoordinator`) — never inferred here.
///
/// Deliberately pure/no CloudKit I/O, so a scanned QR payload can be
/// rejected before this app ever spends a network round trip
/// (`CKContainer.fetchShareMetadata(with:)`) resolving it, and an
/// arbitrary/non-Vǫxtr QR code is rejected up front rather than being
/// handed to the real acceptance pipeline at all.
public enum AthleteConnectionQRCode {

    /// Every distinct reason a scanned payload is not a supported Vǫxtr
    /// connection code — never collapsed to a generic Bool/nil, matching
    /// this codebase's own established explicit-failure convention.
    public enum ValidationError: Error, Equatable {
        /// The scanned text does not even parse as a URL.
        case notAURL
        /// Parsed as a URL, but not `https` — a real `CKShare.url` is
        /// always `https`.
        case unsupportedScheme
        /// `https`, but not an `icloud.com` host — not a CloudKit share
        /// link, so never handed to `CKContainer.fetchShareMetadata(with:)`.
        case unsupportedHost
    }

    /// Structural validation only. Returns the scanned URL UNCHANGED
    /// (never rewritten/normalized/stripped) on success — this function
    /// has no notion of "extract an identifier from this URL" at all; the
    /// returned `URL` is opaque transport, handed to
    /// `CloudKitTransport.fetchShareMetadata(for:)` verbatim.
    public static func validate(_ scannedText: String) -> Result<URL, ValidationError> {
        let trimmed = scannedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return .failure(.notAURL)
        }
        guard scheme == "https" else {
            return .failure(.unsupportedScheme)
        }
        guard let host = url.host?.lowercased(), host == "icloud.com" || host.hasSuffix(".icloud.com") else {
            return .failure(.unsupportedHost)
        }
        return .success(url)
    }
}
