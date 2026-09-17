import CloudKit
import VoxtrCore

/// SPIKE — NOT A PRODUCTION FEATURE. Athlete Connection V1 Security Contract
/// Correction, "Focused Spike: Existing Workspace Ownership Verification."
///
/// THIS TARGET IS DELIBERATELY LINKED BY NOTHING SHIPPING. Neither
/// `VoxtrAppShell` (the composition root every app target depends on) nor
/// `App/ParentApp`/`App/AthleteApp` reference this target or product at
/// all — see `Package.swift`'s own comment at this target's declaration.
/// It exists ONLY to prove, at compile time against this codebase's real
/// `CloudKitTransport`/`CloudKitDatabaseScope` types, that the candidate
/// mechanism below (`CKFetchWebAuthTokenOperation`) is a real, callable,
/// available API — never to be invoked from a real user flow. It is
/// included only in `VoxtrSprint0Tests`'s dependency list (a test-only
/// target that is never shipped in either app) so Codemagic's existing
/// `package-tests` workflow gives real compile validation of this file,
/// mirroring `VoxtrAthleteScanner`'s own established isolation pattern
/// (a leaf target excluded from `VoxtrAppShell`) but isolating from
/// PRODUCTION APPS specifically rather than from tests, since this code
/// must never reach a shipping binary at all.
///
/// WHAT THIS SPIKE INVESTIGATES: whether a native iOS app can obtain an
/// Apple-issued credential that an INDEPENDENT Vǫxtr backend could use to
/// verify — via a direct call to Apple's own CloudKit Web Services REST
/// API, not by trusting a client-reported claim — that the current
/// ParentApp session has genuine CloudKit access to a specific, already-
/// existing `FamilyWorkspace` root record
/// (`FamilyWorkspaceOwnerShareCoordinator.ensureRootRecord`, saved to
/// `transport.database(for: .private)` — see that file's own
/// `ensureSharingRoot`/`ensureZone`/`ensureRootRecord`, confirmed as the
/// actual creation site during this spike's repository investigation).
///
/// THE CANDIDATE MECHANISM: `CKFetchWebAuthTokenOperation` — a real,
/// native `CloudKit` framework operation (`CKDatabaseOperation` subclass),
/// available since iOS 9.2/macOS 10.11 — confirmed via Apple's own SDK
/// header (`CKFetchWebAuthTokenOperation.h`), well within this package's
/// `.iOS(.v17)` floor (`Package.swift:24`). It takes a CloudKit
/// Dashboard-issued API Token and, using the device's ALREADY-
/// AUTHENTICATED native CloudKit session (the SAME iCloud account already
/// governing the FamilyWorkspace's private database — no separate,
/// user-visible re-authentication step), yields a short-lived Web Auth
/// Token. That token, if handed to an independent backend, lets the
/// backend itself call CloudKit Web Services' REST API to fetch the
/// FamilyWorkspace record AS THAT USER — Apple's own servers, not this
/// app, decide whether that fetch succeeds.
///
/// WHAT THIS DOES NOT ESTABLISH (the spike's central negative finding —
/// see the delivery report and `Docs/AthleteConnectionOwnershipVerificationSpike.md`
/// for the full analysis): Apple's own developer forums confirm Sign in
/// with Apple's `sub` and CloudKit's user identifiers are NOT linked by
/// any documented Apple mechanism. A Web Auth Token obtained here proves
/// "this app session currently has native CloudKit access to this
/// record" — a real, Apple-verified, independently-checkable fact — but
/// does NOT, by itself, cryptographically prove that fact belongs to a
/// specific, separately-authenticated Sign-in-with-Apple identity. See
/// the delivery report's point-by-point analysis (Section 3, item 4) for
/// why this spike's verdict is NOT VERIFIED / NOT FEASIBLE as a complete,
/// cryptographically air-tight ownership proof, despite every other
/// property (points 1, 2, 3, 5, 6) being satisfied.
public enum WorkspaceOwnershipEvidenceSpike {

    /// Every distinct outcome this spike's candidate call can produce —
    /// kept small and honest: this is a PROOF-OF-CONCEPT surface, not a
    /// production error taxonomy. `.tokenObtained` is deliberately NOT
    /// named `.ownershipVerified` — obtaining a Web Auth Token is only
    /// the FIRST half of the candidate protocol (native token
    /// acquisition); the SECOND half (an independent backend using that
    /// token against CloudKit Web Services' REST API) is explicitly out
    /// of this spike's executable scope — no hosted backend or CloudKit
    /// Dashboard API Token exists in this environment (see the delivery
    /// report's "missing operational prerequisite" section). Nothing in
    /// this codebase calls this type in a real user flow.
    public enum Outcome: Equatable, Sendable {
        case tokenObtained
        case failed(String)
    }

    /// Demonstrates the real, documented shape of the candidate call —
    /// never invoked by production code, never given a real CloudKit
    /// Dashboard API Token by anything in this repository. `apiToken` is
    /// an explicit, injected parameter (never hardcoded, never embedded
    /// in the app, per this spike's own scope constraints) precisely so
    /// this file cannot accidentally ship a real credential.
    ///
    /// Takes the SAME `CloudKitTransport`/`CloudKitDatabaseScope` shape
    /// `FamilyWorkspaceOwnerShareCoordinator.ensureSharingRoot` already
    /// uses (`transport.database(for: .private)`) — this is deliberate:
    /// a real (non-spike) implementation of this mechanism would need to
    /// operate on the SAME private database the FamilyWorkspace root
    /// record already lives in, and using this codebase's own existing
    /// transport abstraction here, rather than a raw `CKDatabase`,
    /// proves that fit at compile time instead of merely asserting it in
    /// prose.
    ///
    /// Mirrors `CloudKitContainerProvider`'s own established
    /// `withCheckedThrowingContinuation` bridging pattern for a
    /// completion-block CloudKit API, rather than inventing a new
    /// wrapping convention.
    public static func fetchWebAuthToken(
        apiToken: String,
        transport: CloudKitTransport,
        scope: CloudKitDatabaseScope
    ) async throws -> Outcome {
        // `CloudKitTransport` is `@MainActor` (see that type's own doc
        // comment) — `database(for:)` is synchronous but actor-isolated,
        // so calling it from this nonisolated `async` function requires
        // an explicit await for the implicit actor hop, exactly as any
        // other cross-actor call in this codebase does.
        let database = await transport.database(for: scope)
        let operation = CKFetchWebAuthTokenOperation(APIToken: apiToken)
        return try await withCheckedThrowingContinuation { continuation in
            operation.fetchWebAuthTokenCompletionBlock = { webAuthToken, operationError in
                if let operationError {
                    continuation.resume(returning: .failed(operationError.localizedDescription))
                    return
                }
                guard webAuthToken != nil else {
                    continuation.resume(returning: .failed("No web auth token and no error — unexpected CloudKit response shape."))
                    return
                }
                continuation.resume(returning: .tokenObtained)
            }
            database.add(operation)
        }
    }
}
