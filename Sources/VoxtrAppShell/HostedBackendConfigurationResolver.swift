import Foundation

/// T1 (issue #122): the ONE place both real `@main` app targets resolve
/// the hosted backend's public base URL and gateway key from, before
/// `ParentAuthenticationConfiguration`/`AthleteDeviceAuthorizationGatewayConfiguration`
/// are constructed — see `CompositionRootLoaderView`'s own doc comment
/// for exactly where this is called from and why only in Release.
///
/// This does not invent a third parallel configuration type or a new
/// network stack: it only resolves and validates the two raw strings
/// that already feed the two EXISTING config structs above, fail-closed,
/// before either is ever constructed with an unreviewed value. Debug/
/// Simulator builds never call this at all (see `CompositionRootLoaderView`) —
/// this file's only real caller is the Release build path.
///
/// Deliberately returns a `Result` rather than `throw`ing directly: both
/// call sites (the Release branch of `CompositionRootLoaderView`, and
/// this file's own tests) want to inspect a value without `try`/`catch`
/// noise, and `HostedBackendConfigurationError` is a plain, `Sendable`,
/// `Equatable` closed set — never a place to attach the raw input string,
/// which must never reach `StartupDiagnostics.describe(_:)`'s eventual
/// on-screen output.
enum HostedBackendConfigurationResolver {

    /// The exact Info.plist keys both `App/ParentApp/Info.plist` and
    /// `App/AthleteApp/Info.plist` declare, each using Xcode's own
    /// `$(BUILD_SETTING)` substitution — see
    /// `App/Voxtr.xcodeproj/project.pbxproj`'s `VOXTR_HOSTED_BACKEND_BASE_URL`/
    /// `VOXTR_HOSTED_SUPABASE_ANON_KEY` User-Defined build settings for
    /// where the Debug-only local-development defaults and the
    /// Release-only empty (Codemagic-provisioned) values live. Never a
    /// secret of any kind by themselves — these are plist KEY names.
    static let infoPlistBaseURLKey = "VoxtrHostedBackendBaseURL"
    static let infoPlistAnonKeyKey = "VoxtrHostedSupabaseAnonKey"

    /// The same obviously-non-functional placeholder
    /// `CompositionRoot.build`'s own default parameter already uses —
    /// repeated here as the ONE literal both files must agree on, rather
    /// than inventing a second placeholder string that could silently
    /// drift from the first.
    static let placeholderAnonKey = "REPLACE_WITH_SUPABASE_ANON_KEY"

    /// Supabase's own loopback hosts — any of these as the resolved
    /// base URL's host means a Release build is about to talk to a
    /// local-development backend, which §4 of issue #122 explicitly
    /// forbids on a physical build.
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// The one fixed path suffix every reviewed hosted base URL must
    /// end with — matches `ParentAuthenticationConfiguration`'s own doc
    /// comment (`https://<project>.supabase.co/functions/v1`, NO
    /// trailing slash) and `AthleteDeviceAuthorizationService`'s
    /// `baseURL.appendingPathComponent(path)` call sites, which assume
    /// exactly this shape.
    private static let requiredBasePathSuffix = "/functions/v1"

    /// Reads the two real Info.plist keys above from the actual running
    /// app's own bundle — the only call site this task adds in
    /// production code (`CompositionRootLoaderView`'s Release branch).
    /// Tests call `resolve(rawBaseURL:rawAnonKey:)` directly instead,
    /// with deliberately injected fake strings — never `Bundle.main` —
    /// matching issue #122's own "Simulator/CI tests must still run
    /// without live credentials" requirement.
    static func resolveFromMainBundle() -> Result<HostedBackendConfigurationValues, HostedBackendConfigurationError> {
        resolve(
            rawBaseURL: Bundle.main.object(forInfoDictionaryKey: infoPlistBaseURLKey) as? String,
            rawAnonKey: Bundle.main.object(forInfoDictionaryKey: infoPlistAnonKeyKey) as? String
        )
    }

    /// Pure, deterministic, `Bundle`-free validation — see each
    /// `HostedBackendConfigurationError` case's own doc comment for
    /// exactly what it means. Never logs or otherwise surfaces either
    /// raw input string; a caller that wants a legible failure message
    /// uses `HostedBackendConfigurationError.errorDescription` only.
    static func resolve(
        rawBaseURL: String?,
        rawAnonKey: String?
    ) -> Result<HostedBackendConfigurationValues, HostedBackendConfigurationError> {
        switch validateBaseURL(rawBaseURL) {
        case .failure(let error):
            return .failure(error)
        case .success(let baseURL):
            switch validateAnonKey(rawAnonKey) {
            case .failure(let error):
                return .failure(error)
            case .success(let anonKey):
                return .success(HostedBackendConfigurationValues(baseURL: baseURL, anonKey: anonKey))
            }
        }
    }

    private static func validateBaseURL(_ raw: String?) -> Result<URL, HostedBackendConfigurationError> {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.missingBaseURL)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme, let host = url.host else {
            return .failure(.malformedBaseURL)
        }
        guard scheme.lowercased() == "https" else {
            return .failure(.insecureBaseURL)
        }
        guard !host.isEmpty, !loopbackHosts.contains(host.lowercased()) else {
            return .failure(.insecureBaseURL)
        }
        guard !trimmed.hasSuffix("/"), url.path.hasSuffix(requiredBasePathSuffix) else {
            return .failure(.malformedBaseURL)
        }
        return .success(url)
    }

    private static func validateAnonKey(_ raw: String?) -> Result<String, HostedBackendConfigurationError> {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.missingAnonKey)
        }
        guard trimmed != placeholderAnonKey else {
            return .failure(.placeholderAnonKey)
        }
        // Legacy Supabase anon keys are JWTs: exactly three non-empty
        // base64url ('.'-joined) segments. This deliberately REJECTS the
        // newer `sb_publishable_...`/`sb_secret_...` key format, which
        // has no dots — see issue #122 §3: a modern publishable key is
        // not a drop-in substitute for the three Athlete-facing
        // `verify_jwt=true` functions, and this bounded task validates
        // only the JWT-compatible legacy format rather than silently
        // accepting a shape that would fail those functions' own gate.
        let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy(isBase64URLSegment) else {
            return .failure(.malformedAnonKeyFormat)
        }
        return .success(trimmed)
    }

    private static func isBase64URLSegment(_ segment: Substring) -> Bool {
        !segment.isEmpty && segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// The two already-validated, ready-to-use values —
/// `CompositionRootLoaderView`'s Release branch constructs
/// `ParentAuthenticationConfiguration(baseURL:)` and
/// `AthleteDeviceAuthorizationGatewayConfiguration(anonKey:)` directly
/// from this, never from the raw strings themselves.
struct HostedBackendConfigurationValues: Sendable, Equatable {
    let baseURL: URL
    let anonKey: String
}

/// Closed, `Sendable`, `Equatable` failure set — every case name and
/// `errorDescription` is reviewed, fixed text; neither ever contains the
/// raw base URL or key string. `CompositionRootLoaderView` surfaces this
/// through the SAME `StartupDiagnostics.describe(_:)` path any other
/// startup failure already uses, so a misconfigured Release build fails
/// closed and legibly (issue #122 §4) without a second diagnostic UI.
enum HostedBackendConfigurationError: Error, Equatable, Sendable, LocalizedError {
    /// No value at all for the hosted base URL key (Release build was
    /// archived without the Codemagic-provisioned build setting).
    case missingBaseURL
    /// A value was present but is not a well-formed absolute URL, or
    /// its path does not end with the one required `/functions/v1`
    /// suffix (or ends with a trailing slash — see
    /// `ParentAuthenticationConfiguration`'s own "NO trailing slash"
    /// doc comment).
    case malformedBaseURL
    /// The URL is well-formed but is not `https`, or its host is empty
    /// or one of the local-development loopback hosts — the exact
    /// "never silently fall back to localhost on physical builds" case
    /// issue #122 §4 names explicitly.
    case insecureBaseURL
    /// No value at all for the hosted gateway key.
    case missingAnonKey
    /// The value is literally the known non-functional development
    /// placeholder string, committed on purpose so a Release build that
    /// forgets to override it fails closed instead of silently reusing
    /// a key that was never meant to authenticate anything.
    case placeholderAnonKey
    /// The value is non-empty and not the placeholder, but is not
    /// shaped like the legacy JWT-format anon key every
    /// `verify_jwt=true` Athlete-facing function requires (see this
    /// type's own `validateAnonKey` doc comment) — most likely a modern
    /// `sb_publishable_...`/`sb_secret_...` key, which issue #122 §3
    /// explicitly says is not a drop-in substitute here.
    case malformedAnonKeyFormat

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Hosted backend base URL is not configured for this build."
        case .malformedBaseURL:
            return "Hosted backend base URL is not a well-formed https://<project>.supabase.co/functions/v1 URL."
        case .insecureBaseURL:
            return "Hosted backend base URL must be https and must not be a local-development host."
        case .missingAnonKey:
            return "Hosted backend gateway key is not configured for this build."
        case .placeholderAnonKey:
            return "Hosted backend gateway key is still the development placeholder."
        case .malformedAnonKeyFormat:
            return "Hosted backend gateway key is not in the expected legacy anon-key (JWT) format."
        }
    }
}
