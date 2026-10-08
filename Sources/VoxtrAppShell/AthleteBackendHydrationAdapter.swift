import Foundation
import VoxtrCore
import VoxtrCoreContracts

/// Athlete Connection V1 hydration lifecycle (§4, §5, §8 step 5, issue
/// #111) — the domain-neutral adapter §5 calls for: translates a
/// successful `hydration_get` response into the EXISTING
/// `AthleteConnectionInvitationCloudRecordPayload` shape, so
/// `AthleteIdentityHydrationService.hydrate(_:)` itself needs no
/// change and the legacy CKShare-sourced path
/// (`AthleteConnectionLifecycleService.connect(acceptedShare:)`)
/// remains completely untouched and intact.
///
/// ORCHESTRATION, NOT A SECOND HYDRATION IMPLEMENTATION: this type
/// contains NO upsert/conflict/repository logic of its own — every
/// local persistence decision is `AthleteIdentityHydrationService
/// .hydrate(_:)`'s alone, reused unchanged. This type's only three
/// responsibilities are: (1) obtain a valid device-authorization
/// session and a fresh, action-bound signature for `hydration_get`/
/// `hydration_ack` via the existing session manager/service, (2) map
/// the wire-decoded `AthleteDeviceAuthorizationHydrationFields` into
/// `AthleteConnectionInvitationCloudRecordPayload`, and (3) ACK ONLY
/// AFTER `hydrate(_:)` has already returned successfully — never
/// before, never on any decoding/identity/conflict/persistence failure
/// (§4.3: "hydration-ack is called only after hydrate(...) completes
/// successfully end to end").
///
/// NO NEW PERSISTED ORCHESTRATION STATE: a lost response/relaunch
/// between `hydration_get` and `hydration_ack`, or between `hydrate(_:)`
/// succeeding and `ackHydration` actually confirming, needs none —
/// every one of `hydrate(_:)`'s six upsert steps is already idempotent
/// by stable ID (find-by-ID-or-create), so simply calling
/// `hydrate(deviceGrantId:)` again on the next attempt safely resumes:
/// a fresh `hydration_get` either returns the SAME payload again (ack
/// never confirmed) — re-running `hydrate(_:)` against it is a pure
/// no-op — or reports `.alreadyCompleted` (a previous ack DID land,
/// just its response was lost) — handled as success without ever
/// re-attempting local hydration. Nothing here needs its own Keychain/
/// UserDefaults/SwiftData row to track "did I already ack this."
///
/// NEVER activates the athlete's own membership and never claims live
/// access from cached session/receipt metadata (§2.4, §5) — this type
/// calls `hydrate(_:)` and nothing else; the canonical `.invited ->
/// .active` transition remains exclusively `AcceptWorkspaceInvitationService`'s
/// job, untouched by this file. The existing legacy CloudKit
/// acceptance path is likewise untouched: this is an independent,
/// parallel adapter, not a replacement.
///
/// Never wired into any UI/navigation by this task — `CompositionRoot`
/// registers it for later resolution, exactly like every other
/// Athlete Connection V1 service at this stage.
///
/// `@MainActor`: matches `AthleteDeviceAuthorizationSessionManager`/
/// `AthleteDeviceAuthorizationSessionService`/`AthleteIdentityHydrationService`,
/// every collaborator this type composes.
@MainActor
public final class AthleteBackendHydrationAdapter {
    private let sessionManager: AthleteDeviceAuthorizationSessionManager
    private let sessionService: AthleteDeviceAuthorizationSessionService
    private let identityHydrationService: AthleteIdentityHydrationService

    public init(
        sessionManager: AthleteDeviceAuthorizationSessionManager,
        sessionService: AthleteDeviceAuthorizationSessionService,
        identityHydrationService: AthleteIdentityHydrationService
    ) {
        self.sessionManager = sessionManager
        self.sessionService = sessionService
        self.identityHydrationService = identityHydrationService
    }

    /// Performs one full get -> local-hydrate -> ack attempt for
    /// `deviceGrantId`. Safe to call repeatedly (see this type's own
    /// NO NEW PERSISTED ORCHESTRATION STATE doc comment) — a caller
    /// retries this exact method with no special-cased resume logic of
    /// its own needed.
    ///
    /// SESSION-STALENESS/CANCELLATION (R1, ChatGPT review 6056376095):
    /// `sessionManager.currentSessionGeneration` is captured once, right
    /// after the FIRST `ensureActiveSession()` call succeeds, and
    /// rechecked (together with cooperative task cancellation) after
    /// EVERY subsequent await — inside `getHydration`/`ackHydration`'s
    /// own challenge→submit seam (via `checkNotCancelled`) AND again
    /// right after each of those calls returns — before touching local
    /// persistence, starting the ACK-side session acquisition, or
    /// reporting success. `clearStoredSession()` only ever runs for a
    /// CONFIRMED reason (explicit sign-out, or this manager's own
    /// reaction to `.grantUnavailable`/`.installationKeyUnavailable`),
    /// so detecting it here stops a GET response that arrived AFTER
    /// such a clear from ever being persisted as if it were still
    /// current, and stops a now-stale attempt from reporting success
    /// after a late-arriving ACK confirmation. Never destructive: any
    /// local upsert this call already committed before detecting
    /// staleness/cancellation stays — safely resumable, same as any
    /// other interrupted attempt.
    public func hydrate(deviceGrantId: UUID) async throws -> AthleteBackendHydrationOutcome {
        let getSessionToken = try await sessionManager.ensureActiveSession(deviceGrantId: deviceGrantId)
        let capturedGeneration = sessionManager.currentSessionGeneration

        let getOutcome = try await sessionService.getHydration(
            deviceGrantId: deviceGrantId, sessionToken: getSessionToken
        ) {
            try self.checkSessionStillValid(capturedGeneration: capturedGeneration)
        }
        try checkSessionStillValid(capturedGeneration: capturedGeneration)

        let fields: AthleteDeviceAuthorizationHydrationFields
        switch getOutcome {
        case .notAvailable, .sessionInvalid, .grantNotAvailable:
            return .notYetAvailable
        case .alreadyCompleted:
            return .alreadyCompleted
        case .deadlinePassed:
            return .deadlinePassed
        case .grantRevoked:
            return .grantRevoked
        case .hydrated(let hydratedFields):
            fields = hydratedFields
        }

        // VALUE validation (R2, ChatGPT review 6056376095), BEFORE any
        // local upsert: `AthleteIdentityHydrationService.hydrate(_:)`
        // itself only parses/validates `athleteBirthDateISO`/
        // `athleteDevelopmentStage` when creating a BRAND NEW athlete
        // profile — a pre-existing, same-workspace athlete profile
        // short-circuits before ever reaching that validation, and
        // `athleteTimeZoneId` is never validated there at all. A
        // malformed value must never be accepted just because the
        // local graph already happens to have a matching profile from
        // an earlier attempt.
        try validateFieldValues(fields)

        let payload = AthleteConnectionInvitationCloudRecordPayload(
            workspaceId: fields.workspaceId,
            intendedParticipantId: fields.intendedParticipantId,
            intendedAthleteId: fields.intendedAthleteId,
            parentId: fields.parentId,
            parentGivenName: fields.parentGivenName,
            workspaceDisplayName: fields.workspaceDisplayName,
            ownerParticipantId: fields.ownerParticipantId,
            athleteGivenName: fields.athleteGivenName,
            athleteBirthDateISO: fields.athleteBirthDateISO,
            athleteTimeZoneId: fields.athleteTimeZoneId,
            athleteDevelopmentStage: fields.athleteDevelopmentStage
        )

        // Local hydration must fully succeed BEFORE any ack attempt —
        // never caught/swallowed here; propagates exactly as
        // `AthleteIdentityHydrationService.hydrate(_:)` itself throws
        // it (§4.3; CLAUDE.md's own "never flatten errors" convention).
        try identityHydrationService.hydrate(payload)
        try checkSessionStillValid(capturedGeneration: capturedGeneration)

        let ackSessionToken = try await sessionManager.ensureActiveSession(deviceGrantId: deviceGrantId)
        let ackOutcome = try await sessionService.ackHydration(
            deviceGrantId: deviceGrantId, sessionToken: ackSessionToken
        ) {
            try self.checkSessionStillValid(capturedGeneration: capturedGeneration)
        }
        try checkSessionStillValid(capturedGeneration: capturedGeneration)

        switch ackOutcome {
        case .acked, .alreadyCompleted:
            // `.alreadyCompleted` here means a DIFFERENT, earlier
            // attempt's own ack already landed server-side (a lost-
            // response retry) — this attempt's local hydrate() call
            // just above was a safe, idempotent no-op; both cases are
            // equally genuine success.
            return .hydratedAndAcked
        case .notAvailable, .sessionInvalid, .grantNotAvailable, .deadlinePassed, .grantRevoked:
            // The LOCAL upsert above already happened and is safely
            // resumable (see this type's own doc comment) — this is
            // never represented as if hydration itself failed; only
            // the ack confirmation did. A caller retries this exact
            // method with a fresh proof (§4.3's own "retry ack with
            // fresh proof" rule); it never re-fabricates or duplicates
            // local rows.
            throw AthleteBackendHydrationError.ackNotConfirmed(ackOutcome)
        }
    }

    /// Throws `CancellationError` if this `Task` was cancelled, or
    /// `.sessionInvalidatedOrCancelled` if `sessionManager`'s own
    /// generation has moved past `capturedGeneration` — i.e.
    /// `clearStoredSession()` ran since this attempt started. Never
    /// starts a new session on cancellation's behalf; the caller simply
    /// stops.
    private func checkSessionStillValid(capturedGeneration: Int) throws {
        try Task.checkCancellation()
        guard capturedGeneration == sessionManager.currentSessionGeneration else {
            throw AthleteBackendHydrationError.sessionInvalidatedOrCancelled
        }
    }

    /// Validates the three fields `AthleteIdentityHydrationService
    /// .hydrate(_:)` can leave unvalidated for a pre-existing athlete
    /// profile (see this method's own call site doc comment). Uses the
    /// exact canonical parsers/types those local upsert steps
    /// themselves use for a NEW profile (`LocalDate(isoString:)`,
    /// `DevelopmentStage(rawValue:)`, `TimeZoneId.timeZone`), so a value
    /// this rejects is genuinely one `hydrate(_:)` itself would also
    /// have rejected had it reached its own validation. No PII in the
    /// thrown error — only the field name.
    private func validateFieldValues(_ fields: AthleteDeviceAuthorizationHydrationFields) throws {
        guard LocalDate(isoString: fields.athleteBirthDateISO) != nil else {
            throw AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteBirthDateISO")
        }
        guard DevelopmentStage(rawValue: fields.athleteDevelopmentStage) != nil else {
            throw AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteDevelopmentStage")
        }
        guard TimeZoneId(rawValue: fields.athleteTimeZoneId).timeZone != nil else {
            throw AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteTimeZoneId")
        }
    }
}

/// `AthleteBackendHydrationAdapter.hydrate(deviceGrantId:)`'s terminal,
/// non-throwing results — every one of these is a definite business
/// outcome, never a transient failure the caller must distinguish from
/// a real error.
public enum AthleteBackendHydrationOutcome: Equatable {
    /// `AthleteIdentityHydrationService.hydrate(_:)` succeeded this
    /// call AND the backend confirms the grant's hydration lifecycle is
    /// complete.
    case hydratedAndAcked
    /// The grant's permanent `hydration_outcome` marker was already
    /// `'acked'` at the GET step itself — nothing to hydrate (or ack)
    /// this call; a strictly earlier attempt already fully completed
    /// this grant's hydration end to end.
    case alreadyCompleted
    case deadlinePassed
    case grantRevoked
    /// Nothing uploaded yet, or a transient session/security fold
    /// (`notAvailable`/`sessionInvalid`/`grantNotAvailable`) — a
    /// legitimate, retryable state, never a permanent failure.
    case notYetAvailable
}

/// Everything `AthleteIdentityHydrationService.hydrate(_:)` itself can
/// throw already propagates as its own typed `AthleteIdentityHydrationError`
/// — never re-wrapped here — and every session/network failure from
/// `ensureActiveSession`/`getHydration`/`ackHydration` propagates as
/// its own already-distinct typed error (`AthleteDeviceAuthorizationSessionManager
/// .SessionFailure`/`AthleteDeviceAuthorizationSessionError`). This is
/// the ONE genuinely new failure this type itself introduces.
public enum AthleteBackendHydrationError: Error, Equatable {
    /// Local hydration (`AthleteIdentityHydrationService.hydrate(_:)`)
    /// already succeeded and persisted real rows THIS call — but the
    /// immediately-following `ackHydration` did not confirm completion
    /// (`.acked`/`.alreadyCompleted`). Never destructive: the local
    /// upsert is safely resumable (see `AthleteBackendHydrationAdapter`'s
    /// own doc comment); retrying `hydrate(deviceGrantId:)` attempts a
    /// fresh ack with fresh proof and never re-fabricates or
    /// duplicates local rows.
    case ackNotConfirmed(AthleteDeviceAuthorizationHydrationAckOutcome)
    /// This attempt's `Task` was cancelled, or `sessionManager
    /// .clearStoredSession()` ran (explicit sign-out, or the manager's
    /// own reaction to a grant/key failure) since this attempt
    /// started — detected after an await, before touching local
    /// persistence, starting further session/network work, or
    /// reporting success (R1, ChatGPT review 6056376095). Whatever
    /// already persisted locally before this was detected is NOT
    /// rolled back — it is safely resumable, same as any other
    /// interrupted attempt (see this type's own NO NEW PERSISTED
    /// ORCHESTRATION STATE doc comment). Never represented as a
    /// completed hydration.
    case sessionInvalidatedOrCancelled
    /// `getHydration` returned a `.hydrated` payload whose
    /// `athleteBirthDateISO`/`athleteDevelopmentStage`/`athleteTimeZoneId`
    /// value failed validation against the exact canonical parser
    /// `AthleteIdentityHydrationService.hydrate(_:)` itself would use
    /// (R2, ChatGPT review 6056376095) — checked here BEFORE any local
    /// upsert, because that service only runs its own validation when
    /// creating a brand-new athlete profile; a pre-existing, same-
    /// workspace profile would otherwise short-circuit past it. Never
    /// acked: the backend's recoverable snapshot survives for a
    /// genuine retry with a non-malformed payload. `field` names only
    /// which of the three failed — never the value itself (no PII in
    /// this error).
    case malformedHydrationPayload(field: String)
}
