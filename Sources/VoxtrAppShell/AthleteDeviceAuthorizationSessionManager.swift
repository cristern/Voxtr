import Foundation

/// Injectable so deterministic tests never depend on `Date()` / real
/// wall-clock time (CLAUDE.md §8) — mirrors
/// `AthleteDeviceAuthorizationPollingClock`'s own established seam
/// shape for this codebase, adapted to "what time is it" rather than
/// "sleep for this long".
public protocol AthleteDeviceAuthorizationSessionClock: Sendable {
    func now() -> Date
}

public struct SystemAthleteDeviceAuthorizationSessionClock: AthleteDeviceAuthorizationSessionClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Athlete Connection V1 device-authorization session contract (§3.3–
/// §3.5, §8 step 4): the ONE production policy owner for the 7-day
/// sliding / 90-day absolute device-authorization session lifecycle —
/// renewing, automatically reissuing, and persisting, using only the
/// installation's own already-established signing key. Named
/// distinctly from `AthleteRuntimeSession` — see
/// `AthleteDeviceAuthorizationSessionModels.swift`'s own family naming
/// note.
///
/// NEVER triggers Parent re-pairing on its own. The three genuine
/// Parent-involvement cases (§3.5) are: the grant is revoked/
/// unavailable, or the presented session is rejected, by a FRESH
/// network call (`.grantUnavailable` below — never inferred from a
/// stale local clock); the installation key is lost
/// (`.installationKeyUnavailable` — reinstall, detected the same way
/// `currentInstallationHasExistingSigningKey()` already detects it);
/// or no session has ever existed for this installation (handled
/// transparently by issuing a first one). Every other path — including
/// the full 90-day absolute cap elapsing — is handled automatically,
/// issuing a brand-new chain with the SAME key, exactly as §3.5
/// requires: "no recurring Parent re-pairing solely because that cap
/// elapsed."
///
/// Treats a stored session as live, unverified metadata exactly as far
/// as the sliding window allows (§3.4 point 2's "never bearer-token
/// possession alone" governs every call ACROSS the network — reading
/// an unexpired local `expiresAt` to skip an unnecessary round trip is
/// not a security check, it is this policy's own sliding-window
/// definition).
@MainActor
public final class AthleteDeviceAuthorizationSessionManager {

    public enum SessionFailure: Error, Equatable {
        /// The grant itself is gone/inactive, or a presented session
        /// was rejected, by a FRESH network call. Genuinely requires
        /// Parent action (re-approval/re-pairing) — never something
        /// this type retries past.
        case grantUnavailable
        /// `loadExistingSigningKey()` failed — reinstall or orphaned
        /// Keychain material. Genuinely requires a brand-new pairing
        /// attempt; never silently replaced with a freshly minted key.
        case installationKeyUnavailable
        case gatewayConfigurationMissing
        case network
        case malformedResponse
    }

    /// Bounded — a lost-response/ambiguous network failure during
    /// either `device-session-challenge` or `device-session-submit` is
    /// retried with a FRESH challenge (§3.3's own "lost-response retry"
    /// rule); both `session_issue` and `session_renew` are genuinely
    /// idempotent in effect under the server's lock ordering, so a
    /// retry can never produce two live sessions. Bounded, never
    /// unbounded, so a genuinely offline device fails visibly instead
    /// of looping forever.
    static let maxAttemptsPerCall = 3

    private let service: AthleteDeviceAuthorizationSessionService
    private let store: AthleteDeviceAuthorizationSessionStoring
    private let clock: AthleteDeviceAuthorizationSessionClock

    /// Coalesces concurrent callers for the SAME `deviceGrantId` into
    /// one in-flight attempt — a second caller awaits the first's
    /// result rather than starting its own redundant network round
    /// trip. Keyed by `deviceGrantId` rather than assuming a singleton,
    /// even though exactly one grant is active per installation in
    /// practice.
    private var inFlightTasks: [UUID: Task<String, Error>] = [:]

    public init(
        service: AthleteDeviceAuthorizationSessionService,
        store: AthleteDeviceAuthorizationSessionStoring = KeychainAthleteDeviceAuthorizationSessionStore(),
        clock: AthleteDeviceAuthorizationSessionClock = SystemAthleteDeviceAuthorizationSessionClock()
    ) {
        self.service = service
        self.store = store
        self.clock = clock
    }

    /// Returns a bearer token this installation can present RIGHT NOW
    /// for `deviceGrantId` — renewing or (only when genuinely needed)
    /// reissuing first, entirely automatically. Concurrent calls for
    /// the same grant share one attempt and its one result.
    public func ensureActiveSession(deviceGrantId: UUID) async throws -> String {
        if let existingTask = inFlightTasks[deviceGrantId] {
            return try await existingTask.value
        }
        let task = Task { [weak self] in
            guard let self else { throw SessionFailure.network }
            return try await self.resolveActiveSession(deviceGrantId: deviceGrantId)
        }
        inFlightTasks[deviceGrantId] = task
        defer { inFlightTasks[deviceGrantId] = nil }
        return try await task.value
    }

    /// Discards any stored session for this installation. Call this
    /// only in response to a CONFIRMED reason (explicit Athlete sign-
    /// out, or a caller reacting to a `.grantUnavailable`/
    /// `.installationKeyUnavailable` failure already surfaced by this
    /// type) — never automatically just because a local clock looks
    /// expired; `ensureActiveSession` itself already handles every
    /// ordinary expiry transition.
    public func clearStoredSession() {
        store.clearSession()
    }

    private func resolveActiveSession(deviceGrantId: UUID) async throws -> String {
        let now = clock.now()
        if let stored = store.loadSession(), stored.deviceGrantId == deviceGrantId {
            if now < stored.expiresAt {
                // Sliding window still open — no network call needed.
                return stored.sessionToken
            }
            if now < stored.absoluteExpiresAt {
                if let renewed = try await attemptRenew(deviceGrantId: deviceGrantId, stored: stored) {
                    return renewed
                }
                // Renewal was cleanly rejected (not a transient network
                // issue — those are already retried inside
                // attemptRenew) — fall through to a fresh chain, the
                // "renewal no longer possible but the grant/key may
                // still be fine" path §3.5 describes.
            }
        }
        return try await attemptIssue(deviceGrantId: deviceGrantId)
    }

    /// Returns the (unchanged) bearer token on a successful renewal,
    /// or `nil` if renewal was cleanly rejected so the caller falls
    /// through to a fresh `session_issue` — never `nil` for a
    /// transient network failure, which is retried here first.
    private func attemptRenew(deviceGrantId: UUID, stored: AthleteDeviceAuthorizationSessionRecord) async throws -> String? {
        var lastFailure: SessionFailure = .network
        for _ in 0..<Self.maxAttemptsPerCall {
            do {
                let outcome = try await service.renewSession(deviceGrantId: deviceGrantId, sessionToken: stored.sessionToken)
                switch outcome {
                case .renewed(let expiresAt, let absoluteExpiresAt):
                    let updated = AthleteDeviceAuthorizationSessionRecord(
                        deviceGrantId: deviceGrantId,
                        sessionToken: stored.sessionToken,
                        expiresAt: expiresAt,
                        absoluteExpiresAt: absoluteExpiresAt
                    )
                    persist(updated)
                    return updated.sessionToken
                case .sessionInvalid, .grantNotAvailable, .notAvailable:
                    return nil
                }
            } catch let error as AthleteDeviceAuthorizationSessionError {
                switch error {
                case .network:
                    lastFailure = .network
                    continue
                case .malformedResponse:
                    throw SessionFailure.malformedResponse
                case .signingKeyUnavailable:
                    store.clearSession()
                    throw SessionFailure.installationKeyUnavailable
                case .gatewayConfigurationMissing:
                    throw SessionFailure.gatewayConfigurationMissing
                }
            }
        }
        throw lastFailure
    }

    private func attemptIssue(deviceGrantId: UUID) async throws -> String {
        var lastFailure: SessionFailure = .network
        for _ in 0..<Self.maxAttemptsPerCall {
            do {
                let outcome = try await service.issueSession(deviceGrantId: deviceGrantId)
                switch outcome {
                case .issued(let sessionToken, let expiresAt, let absoluteExpiresAt):
                    let record = AthleteDeviceAuthorizationSessionRecord(
                        deviceGrantId: deviceGrantId,
                        sessionToken: sessionToken,
                        expiresAt: expiresAt,
                        absoluteExpiresAt: absoluteExpiresAt
                    )
                    persist(record)
                    return sessionToken
                case .grantNotAvailable:
                    store.clearSession()
                    throw SessionFailure.grantUnavailable
                case .notAvailable:
                    // Ambiguous — a race on the fresh challenge this
                    // very call just requested. Retried with a brand-
                    // new challenge, same as a transient network
                    // failure (§3.3's own lost-response retry rule).
                    lastFailure = .network
                    continue
                }
            } catch let error as AthleteDeviceAuthorizationSessionError {
                switch error {
                case .network:
                    lastFailure = .network
                    continue
                case .malformedResponse:
                    throw SessionFailure.malformedResponse
                case .signingKeyUnavailable:
                    store.clearSession()
                    throw SessionFailure.installationKeyUnavailable
                case .gatewayConfigurationMissing:
                    throw SessionFailure.gatewayConfigurationMissing
                }
            }
        }
        throw lastFailure
    }

    /// Deliberately never thrown further: the in-memory token this
    /// call already obtained is still truthfully valid right now, and
    /// surfacing a save failure as if the whole operation failed would
    /// be dishonest. A failed save means only that a future relaunch
    /// may need to reissue sooner than the real server-side expiry —
    /// wasteful, never incorrect, since `session_issue` is itself
    /// idempotent in effect. A richer "unpersisted" warning surface
    /// (matching `AthleteDeviceAuthorizationPairingCoordinator`'s own
    /// `unpersistedAuthorizationWarning`) is a UI-facing concern
    /// deliberately out of this task's scope.
    private func persist(_ record: AthleteDeviceAuthorizationSessionRecord) {
        try? store.saveSession(record)
    }
}
