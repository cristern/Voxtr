import Foundation

/// Athlete Connection V1 (backend device authorization): the ONE
/// canonical opaque transport payload a Vǫxtr DEVICE AUTHORIZATION QR
/// code carries — an explicit protocol version plus an
/// `AthleteDeviceAuthorizationInvitation.invitationId`, encoded as a
/// plain custom-scheme URL, never a second, parallel payload. This is a
/// DISTINCT type from the existing, unmodified `AthleteConnectionQRCode`
/// (which structurally validates an `icloud.com` CKShare URL for the
/// separate, still-live CloudKit pairing screen). `ADR-AthleteConnection-
/// BackendAuthorization.md` records the decision to build THIS backend-
/// authorized flow as the approved direction; it does not itself
/// address the existing CKShare screens. Keeping those screens
/// unmodified alongside this new flow for this slice is a scope
/// decision confirmed by the repository owner during review, not an ADR
/// mandate — their eventual retirement is separate follow-up work with
/// its own security/release review. The two payload shapes are
/// deliberately non-overlapping (different scheme, different host), so
/// neither validator could ever accept the other's QR even if a scanner
/// were ever shared.
///
/// PRIVACY: the QR encodes only a version number and the invitation's
/// own opaque id — no athlete name, DOB, workspace, or participant
/// identifier. Possessing this id alone never grants access by itself
/// (the Normative Security Contract's own §3): it only lets an
/// installation submit ITS OWN connection request, which still requires
/// the Parent's explicit visual comparison-code approval and the
/// installation's own signed challenge/claim proof before any backend
/// device authorization exists.
///
/// NEVER DERIVES THE BACKEND DESTINATION FROM SCANNED INPUT: `validate`
/// returns only a `UUID` — never a `URL`, host, or any other structural
/// piece of the scan — so nothing downstream can be tricked into
/// treating scanned text as a server address. The real backend base URL
/// always comes from `ParentAuthenticationConfiguration`/gateway
/// configuration, injected via `CompositionRoot`.
///
/// This type performs STRUCTURAL validation only, and never extracts,
/// decodes, or trusts any business identity beyond the invitation id
/// itself — mirrors `AthleteConnectionQRCode`'s own established
/// pure/no-I/O convention. Validation is intentionally STRICT: an
/// unsupported version, a duplicate or unrecognized query item, or any
/// userinfo/port/path/fragment the real payload never carries is
/// rejected outright rather than silently ignored, so a malformed or
/// crafted scan fails closed instead of being partially, ambiguously
/// accepted.
public enum AthleteDeviceAuthorizationQRPayload {

    static let scheme = "voxtr-connect"
    static let host = "invite"
    static let versionQueryItemName = "v"
    static let invitationIdQueryItemName = "invitation_id"
    /// The only version this build understands. Bumped only alongside a
    /// deliberate, reviewed wire-format change — never silently widened
    /// to accept an unrecognized value.
    static let currentVersion = "1"

    /// Every distinct reason a scanned payload is not a supported
    /// device-authorization invitation code — never collapsed to a
    /// generic Bool/nil, matching `AthleteConnectionQRCode.ValidationError`'s
    /// own explicit-failure convention.
    public enum ValidationError: Error, Equatable {
        case notAURL
        case unsupportedScheme
        case unsupportedHost
        /// A userinfo (user/password), port, non-empty path, or fragment
        /// was present — the real payload never carries any of these.
        case unexpectedURLStructure
        case missingQueryItems
        case unknownQueryItem
        case duplicateQueryItem
        case missingVersion
        case unsupportedVersion
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
        guard
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.path.isEmpty,
            components.fragment == nil
        else {
            return .failure(.unexpectedURLStructure)
        }
        guard let queryItems = components.queryItems, !queryItems.isEmpty else {
            return .failure(.missingQueryItems)
        }

        let knownNames: Set<String> = [versionQueryItemName, invitationIdQueryItemName]
        var seenNames: Set<String> = []
        for item in queryItems {
            guard knownNames.contains(item.name) else {
                return .failure(.unknownQueryItem)
            }
            guard !seenNames.contains(item.name) else {
                return .failure(.duplicateQueryItem)
            }
            seenNames.insert(item.name)
        }

        guard let version = queryItems.first(where: { $0.name == versionQueryItemName })?.value else {
            return .failure(.missingVersion)
        }
        guard version == currentVersion else {
            return .failure(.unsupportedVersion)
        }
        guard let rawInvitationId = queryItems.first(where: { $0.name == invitationIdQueryItemName })?.value else {
            return .failure(.missingInvitationId)
        }
        guard let invitationId = UUID(uuidString: rawInvitationId) else {
            return .failure(.malformedInvitationId)
        }
        return .success(invitationId)
    }

    /// Builds the QR payload URL for a just-created invitation, always
    /// at `currentVersion`. Construction is fully controlled (a fixed
    /// scheme/host plus two query items built from known-safe strings),
    /// so this can never fail to produce a `URL`.
    public static func encode(invitationId: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: versionQueryItemName, value: currentVersion),
            URLQueryItem(name: invitationIdQueryItemName, value: invitationId.uuidString.lowercased()),
        ]
        guard let url = components.url else {
            preconditionFailure("AthleteDeviceAuthorizationQRPayload.encode produced an unconstructible URL from fully-controlled components")
        }
        return url
    }
}
