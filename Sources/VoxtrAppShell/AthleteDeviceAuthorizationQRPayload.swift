import Foundation

/// Athlete Connection V1 (backend device authorization): the ONE
/// canonical opaque transport payload a Vǫxtr DEVICE AUTHORIZATION QR
/// code carries — an `AthleteDeviceAuthorizationInvitation.invitationId`
/// encoded as a plain custom-scheme URL, never a second, parallel
/// payload. This is a DISTINCT type from the existing, unmodified
/// `AthleteConnectionQRCode` (which structurally validates an
/// `icloud.com` CKShare URL for the separate, still-live CloudKit
/// pairing screen) — see `ADR-AthleteConnection-BackendAuthorization.md`
/// for why this slice adds a new backend-authorized flow alongside that
/// existing one rather than modifying it. The two payload shapes are
/// deliberately non-overlapping (different scheme, different host), so
/// neither validator could ever accept the other's QR even if a scanner
/// were ever shared.
///
/// PRIVACY: the QR encodes only the invitation's own opaque id — no
/// athlete name, DOB, workspace, or participant identifier. Possessing
/// this id alone never grants access by itself (the Normative Security
/// Contract's own §3): it only lets an installation submit ITS OWN
/// connection request, which still requires the Parent's explicit visual
/// comparison-code approval and the installation's own signed
/// challenge/claim proof before any backend device authorization exists.
///
/// This type performs STRUCTURAL validation only, and never extracts,
/// decodes, or trusts any business identity beyond the invitation id
/// itself — mirrors `AthleteConnectionQRCode`'s own established
/// pure/no-I/O convention exactly.
public enum AthleteDeviceAuthorizationQRPayload {

    static let scheme = "voxtr-connect"
    static let host = "invite"
    static let invitationIdQueryItemName = "invitation_id"

    /// Every distinct reason a scanned payload is not a supported
    /// device-authorization invitation code — never collapsed to a
    /// generic Bool/nil, matching `AthleteConnectionQRCode.ValidationError`'s
    /// own explicit-failure convention.
    public enum ValidationError: Error, Equatable {
        case notAURL
        case unsupportedScheme
        case unsupportedHost
        case missingInvitationId
        case malformedInvitationId
    }

    /// Structural validation only. Returns the decoded invitation id on
    /// success — never a URL, never anything beyond that one opaque id.
    public static func validate(_ scannedText: String) -> Result<UUID, ValidationError> {
        let trimmed = scannedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else {
            return .failure(.notAURL)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == Self.scheme else {
            return .failure(.unsupportedScheme)
        }
        guard let host = components.host?.lowercased(), host == Self.host else {
            return .failure(.unsupportedHost)
        }
        guard let rawInvitationId = components.queryItems?.first(where: { $0.name == invitationIdQueryItemName })?.value else {
            return .failure(.missingInvitationId)
        }
        guard let invitationId = UUID(uuidString: rawInvitationId) else {
            return .failure(.malformedInvitationId)
        }
        return .success(invitationId)
    }

    /// Builds the QR payload URL for a just-created invitation. The
    /// interpolated value is always a `UUID.uuidString` (hex digits and
    /// hyphens only), so this construction can never produce a `nil`
    /// `URL`.
    public static func encode(invitationId: UUID) -> URL {
        URL(string: "\(scheme)://\(host)?\(invitationIdQueryItemName)=\(invitationId.uuidString.lowercased())")!
    }
}
