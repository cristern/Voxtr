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
        /// `clearStoredSession()` ran while THIS exact operation was
        /// still suspended on a network await (R6, ChatGPT review
        /// 6024820299) — mirrors `ParentAuthenticationService
        /// .sessionGeneration`'s own established guard exactly. The
        /// operation's result is discarded rather than persisted or
        /// returned as if it succeeded; never retried automatically by
        /// this type itself.
        case sessionCleared
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

    /// Review round 4 (PR #116, ChatGPT review 6020919614): `session_renew`
    /// is only ever backend-legal while `now < session.expires_at` —
    /// confirmed directly against `authz.device_session_issue_challenge`
    /// and `authz.device_session_submit`
    /// (`20261004060000_authz_device_session_v1.sql`), both of which
    /// reject with `session_invalid`/`not_available` once the sliding
    /// window has already lapsed. A sliding window that only "slides"
    /// when actually used must therefore renew BEFORE that deadline,
    /// not after it — this lead time is this policy's own bounded,
    /// deterministic trigger for doing so, never a redefinition of the
    /// accepted 7-day/90-day numbers themselves (§3 of the canonical
    /// contract).
    static let slidingWindowRenewalLeadTime: TimeInterval = 24 * 60 * 60

    private let service: AthleteDeviceAuthorizationSessionService
    private let store: AthleteDeviceAuthorizationSessionStoring
    private let clock: AthleteDeviceAuthorizationSessionClock

    /// Coalesces concurrent callers for the SAME `deviceGrantId` into
    /// one in-flight attempt — a second caller awaits the first's
    /// result rather than starting its own redundant network round
    /// trip. Keyed by `deviceGrantId` rather than assuming a singleton,
    /// even though exactly one grant is active per installation in
    /// practice. Each registration carries its own `token` (see
    /// `nextInFlightToken`) so a stale registration's own cleanup can
    /// never remove a NEWER registration `clearStoredSession()` put in
    /// its place for the same grant (R6, ChatGPT review 6024820299).
    private var inFlightTasks: [UUID: (token: Int, task: Task<String, Error>)] = [:]
    private var nextInFlightToken = 0

    /// Test-only observability seam (reachable only via `@testable
    /// import`, never read by any production code): bumped every time
    /// `ensureActiveSession()` JOINS an already-registered in-flight
    /// task, so deterministic tests can build a real join barrier
    /// instead of trusting `Task.yield()` scheduling order (R6
    /// follow-up, ChatGPT review 6025279987: "five yields still do not
    /// establish a join barrier").
    var joinCountForTesting = 0

    /// Bumped by every `clearStoredSession()` call — mirrors
    /// `ParentAuthenticationService.sessionGeneration`'s own
    /// established guard exactly (R6, ChatGPT review 6024820299).
    /// `resolveActiveSession` (via `attemptRenew`/`attemptIssue`)
    /// captures this value before its own network awaits and refuses
    /// to persist or return a successful result if it changed while
    /// suspended — the actor's own reentrancy means an explicit clear
    /// (e.g. Athlete sign-out) CAN interleave with an operation
    /// already in flight across an `await` point, and without this
    /// guard that operation could silently resurrect a session the
    /// caller just explicitly cleared.
    private var sessionGeneration = 0

    public init(
        service: AthleteDeviceAuthorizationSessionService,
        store: AthleteDeviceAuthorizationSessionStoring = KeychainAthleteDeviceAuthorizationSessionStore(),
        clock: AthleteDeviceAuthorizationSessionClock = SystemAthleteDeviceAuthorizationSessionClock()
    ) {
        self.service = service
        self.store = store
        self.clock = clock
    }

    /// Read-only exposure of `sessionGeneration` (R1, ChatGPT review
    /// 6056376095 on issue #111): lets a caller that performs its OWN
    /// further work AFTER `ensureActiveSession()` returns — persisting
    /// data fetched with the token, then making a SEPARATE later
    /// network call (`AthleteBackendHydrationAdapter`'s get→hydrate→ack
    /// sequence is exactly this) — detect whether `clearStoredSession()`
    /// ran since, the same way this manager's own internal
    /// `checkNotCleared` already does for its own issue/renew awaits.
    /// Never mutable from outside; `clearStoredSession()` remains the
    /// only way to advance it.
    public var currentSessionGeneration: Int { sessionGeneration }

    /// Returns a bearer token this installation can present RIGHT NOW
    /// for `deviceGrantId` — renewing or (only when genuinely needed)
    /// reissuing first, entirely automatically. Concurrent calls for
    /// the same grant share one attempt and its one result.
    public func ensureActiveSession(deviceGrantId: UUID) async throws -> String {
        if let existing = inFlightTasks[deviceGrantId] {
            joinCountForTesting += 1
            return try await existing.task.value
        }
        nextInFlightToken += 1
        let myToken = nextInFlightToken
        // Captured HERE, synchronously, at registration — never inside
        // the scheduled Task body below (R6 follow-up, ChatGPT review
        // 6025069937): the Task's body is not guaranteed to run its
        // first statement immediately, so clearStoredSession() could
        // run, bump sessionGeneration, and evict this very
        // registration BEFORE the body ever executes — reading
        // sessionGeneration only then would wrongly capture the
        // ALREADY-BUMPED value instead of the one that was current
        // when this call was actually accepted.
        let generationAtStart = sessionGeneration
        let task = Task { [weak self] in
            guard let self else { throw SessionFailure.network }
            return try await self.resolveActiveSession(deviceGrantId: deviceGrantId, generationAtStart: generationAtStart)
        }
        inFlightTasks[deviceGrantId] = (token: myToken, task: task)
        defer {
            // Only remove OUR OWN registration. clearStoredSession()
            // may already have evicted this entry and let a newer
            // task be registered in its place for the same grant
            // (R6, ChatGPT review 6024820299) — blindly nil-ing the
            // slot here could wrongly drop that newer registration
            // instead of our own already-stale one.
            if inFlightTasks[deviceGrantId]?.token == myToken {
                inFlightTasks[deviceGrantId] = nil
            }
        }
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
        // Bumped unconditionally, even when nothing is currently
        // stored — an in-flight FIRST-TIME session_issue has no
        // session stored yet either (that's exactly what it's
        // suspended trying to write), so gating the bump on "a
        // session existed" would miss precisely that race (mirrors
        // `ParentAuthenticationService.signOut()`'s own identical
        // reasoning).
        sessionGeneration += 1
        store.clearSession()
        // Evict every in-flight registration, for every grant — the
        // store holds at most one session for this installation
        // regardless of which grant requested it, so a clear
        // invalidates whatever is in flight entirely. A caller after
        // this point must get a genuinely fresh attempt, never join
        // an operation already known (by its own captured
        // generation) to be invalidated (R6, ChatGPT review
        // 6024820299). The already-running tasks themselves are not
        // cancelled; each independently refuses to persist/return a
        // successful result once it reaches its own generation check.
        inFlightTasks.removeAll()
    }

    private func resolveActiveSession(deviceGrantId: UUID, generationAtStart: Int, forceOnlineCheck: Bool = false) async throws -> String {
        // R6 follow-up (ChatGPT review 6025279987): checked HERE,
        // before touching the store or the service at all. The Task
        // this method runs in is not guaranteed to start executing
        // immediately after ensureActiveSession() registers it — if
        // clearStoredSession() runs in that gap, this guard stops a
        // now-stale operation from reading/clearing cached state (the
        // fast-path return below, or the signing-key-check branch's
        // own store.clearSession()) or starting service work under a
        // generation that no longer applies.
        try checkNotCleared(generationAtStart: generationAtStart)
        let now = clock.now()
        if let stored = store.loadSession(), stored.deviceGrantId == deviceGrantId {
            // Review round 4 (PR #116, ChatGPT review 6020919614): a
            // cached session's mere presence is never proof of current
            // authorization on its own (§3.4 point 2) — including of
            // THIS installation's own identity. Session Keychain
            // material can survive an app reinstall even though the
            // signing key's own installation marker did not (§3.4
            // point 3): a reinstall is a NEW installation requiring
            // full re-pairing, checked here — before ever returning or
            // renewing a cached token — not only once a network call
            // happens to need to sign something.
            guard service.currentInstallationHasExistingSigningKey() else {
                store.clearSession()
                throw SessionFailure.installationKeyUnavailable
            }
            if now < stored.expiresAt {
                // `forceOnlineCheck` (Athlete hydration/activation
                // integration slice, §5.2's own correction): a restoration/
                // online-validation caller must never present "freshly
                // verified" on the strength of a merely-unexpired cached
                // token — this policy's own sliding-window fast path below
                // is the EXACT thing that requirement forbids relying on.
                // Skipping straight to a real `session_renew` here, for
                // ANY remaining sliding-window time (not only within the
                // renewal lead time), is what `ensureFreshlyVerifiedSession`
                // below requires; `ensureActiveSession`'s own ordinary
                // fast path is completely unaffected (`forceOnlineCheck`
                // defaults to `false`, and this branch's shape for that
                // default case is byte-for-byte what it was before this
                // parameter existed).
                if !forceOnlineCheck && now < stored.expiresAt.addingTimeInterval(-Self.slidingWindowRenewalLeadTime) {
                    // Comfortably within the sliding window — no
                    // network call needed; this IS the policy's own
                    // sliding-window definition (see this type's own
                    // top-level doc comment).
                    return stored.sessionToken
                }
                // Within the renewal lead time of the sliding-window
                // deadline, but not past it yet — the ONLY window in
                // which the backend will ever accept `session_renew`
                // (see `slidingWindowRenewalLeadTime`'s own doc
                // comment for the confirmed backend check this
                // satisfies).
                if let renewed = try await attemptRenew(deviceGrantId: deviceGrantId, stored: stored, generationAtStart: generationAtStart) {
                    return renewed
                }
                // Cleanly rejected (not a transient network issue —
                // those are already retried inside attemptRenew) —
                // fall through to a fresh chain.
            }
            // now >= stored.expiresAt: the sliding window has already
            // lapsed (with or without the absolute cap also reached).
            // Renewal is no longer backend-legal at all past this
            // point — never attempted here. A fresh `session_issue`
            // with the SAME key is still fully automatic (§3.5) and
            // handles both cases identically.
        }
        return try await attemptIssue(deviceGrantId: deviceGrantId, generationAtStart: generationAtStart)
    }

    /// Athlete hydration/activation integration slice (§5.2): forces a
    /// genuine `session_issue`/`session_renew` network round trip for
    /// `deviceGrantId`, even when a locally-cached, unexpired session
    /// exists — the one thing `ensureActiveSession()`'s own intentional
    /// sliding-window fast path (this type's own top-level doc comment)
    /// can never provide on its own. A caller presenting "connected via
    /// backend session, freshly verified" (CloudKit transition plan
    /// §4.6 state 2) MUST have obtained its token from this method, not
    /// `ensureActiveSession()` — the correction that document's §5.2
    /// makes explicitly: "the manager's existing cached-token fast path
    /// must not satisfy this requirement."
    ///
    /// Deliberately does NOT join `inFlightTasks`' coalescing (unlike
    /// `ensureActiveSession()`): a forced-fresh caller must never
    /// silently share another caller's already-resolved (possibly
    /// fast-pathed) result — it always performs its own attempt, though
    /// it still participates in the SAME `sessionGeneration` staleness
    /// protocol as every other operation this type performs (captured
    /// at entry, rechecked after every awaited call, exactly like
    /// `ensureActiveSession()`'s own task body).
    public func ensureFreshlyVerifiedSession(deviceGrantId: UUID) async throws -> String {
        let generationAtStart = sessionGeneration
        return try await resolveActiveSession(deviceGrantId: deviceGrantId, generationAtStart: generationAtStart, forceOnlineCheck: true)
    }

    /// R6 follow-up (ChatGPT review 6025069937): checked immediately
    /// after EVERY resumed service outcome or error, in both
    /// `attemptRenew` and `attemptIssue`, BEFORE any of that call's own
    /// branches run — never only before the final persist. A stale
    /// operation must neither mutate storage (e.g. `.grantNotAvailable`'s
    /// own `store.clearSession()`, which could otherwise delete a
    /// genuinely newer post-clear session) nor start a further network
    /// attempt (a `.network` retry, or falling through to a fresh
    /// `session_issue` after a stale `.sessionInvalid` rejection) —
    /// `session_issue` in particular has a real server-side effect
    /// (revoking the grant's current active session) that a merely-
    /// discarded LOCAL result can never undo.
    private func checkNotCleared(generationAtStart: Int) throws {
        guard generationAtStart == sessionGeneration else {
            throw SessionFailure.sessionCleared
        }
    }

    /// Returns the (unchanged) bearer token on a successful renewal,
    /// or `nil` if renewal was cleanly rejected so the caller falls
    /// through to a fresh `session_issue` — never `nil` for a
    /// transient network failure, which is retried here first.
    private func attemptRenew(deviceGrantId: UUID, stored: AthleteDeviceAuthorizationSessionRecord, generationAtStart: Int) async throws -> String? {
        var lastFailure: SessionFailure = .network
        for _ in 0..<Self.maxAttemptsPerCall {
            let outcome: AthleteDeviceAuthorizationSessionRenewOutcome
            do {
                outcome = try await service.renewSession(deviceGrantId: deviceGrantId, sessionToken: stored.sessionToken) {
                    // R6 follow-up (ChatGPT review 6025279987): called by
                    // the service between its own two network awaits —
                    // after the challenge succeeds, before signing/
                    // submitting — so a stale operation's SUBMIT (a real
                    // server-side effect) is never sent in the first
                    // place, not merely discarded once it returns.
                    try checkNotCleared(generationAtStart: generationAtStart)
                }
            } catch let error as AthleteDeviceAuthorizationSessionError {
                try checkNotCleared(generationAtStart: generationAtStart)
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
            try checkNotCleared(generationAtStart: generationAtStart)
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
        }
        throw lastFailure
    }

    private func attemptIssue(deviceGrantId: UUID, generationAtStart: Int) async throws -> String {
        var lastFailure: SessionFailure = .network
        for _ in 0..<Self.maxAttemptsPerCall {
            let outcome: AthleteDeviceAuthorizationSessionIssueOutcome
            do {
                outcome = try await service.issueSession(deviceGrantId: deviceGrantId) {
                    // R6 follow-up (ChatGPT review 6025279987): same
                    // reasoning as attemptRenew's own identical closure.
                    try checkNotCleared(generationAtStart: generationAtStart)
                }
            } catch let error as AthleteDeviceAuthorizationSessionError {
                try checkNotCleared(generationAtStart: generationAtStart)
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
            try checkNotCleared(generationAtStart: generationAtStart)
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
