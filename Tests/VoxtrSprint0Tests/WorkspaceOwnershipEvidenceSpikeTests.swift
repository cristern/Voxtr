import Testing
import CloudKit
@testable import VoxtrOwnershipEvidenceSpike
import VoxtrCore

/// Athlete Connection V1 Security Contract Correction — "Focused Spike:
/// Existing Workspace Ownership Verification." See
/// `WorkspaceOwnershipEvidenceSpike.swift`'s own doc comment and
/// `Docs/AthleteConnectionOwnershipVerificationSpike.md` for the full
/// investigation and verdict.
///
/// XCTEST-SAFETY (matching this codebase's own established convention —
/// see `CloudKitTransportTests.swift` and every other CloudKit-facing
/// test in this suite): this file NEVER calls
/// `WorkspaceOwnershipEvidenceSpike.fetchWebAuthToken(apiToken:transport:scope:)`
/// against a real `CloudKitTransport`/`CKDatabase`. Doing so would require a real, entitled
/// `CKContainer` (unsafe/unavailable in a plain XCTest/Swift Testing
/// process, per `CloudKitTransport`'s own doc comment on why container
/// realization is deferred) AND a real CloudKit Dashboard API Token,
/// which does not exist anywhere in this repository or CI environment.
/// What IS verified here, compile-time and structurally: the candidate
/// type/method signature exists and type-checks against this package's
/// real `import CloudKit`, and the small `Outcome` enum's own value
/// semantics — proving the API surface this spike investigated is real
/// and reachable, never that a live Apple-service round-trip succeeded.
@Suite("Athlete Connection ownership spike: candidate mechanism compiles and its Outcome values behave correctly")
struct WorkspaceOwnershipEvidenceSpikeTests {

    @Test("Outcome cases are distinct and Equatable, including associated failure messages")
    func outcomeValuesAreDistinct() {
        #expect(WorkspaceOwnershipEvidenceSpike.Outcome.tokenObtained == .tokenObtained)
        #expect(WorkspaceOwnershipEvidenceSpike.Outcome.failed("x") == .failed("x"))
        #expect(WorkspaceOwnershipEvidenceSpike.Outcome.tokenObtained != .failed("x"))
        #expect(WorkspaceOwnershipEvidenceSpike.Outcome.failed("a") != .failed("b"))
    }

    @Test("fetchWebAuthToken(apiToken:transport:scope:) exists with the expected async throwing signature, referenced but never invoked")
    func candidateMethodSignatureCompiles() {
        // Referencing the function as a value (never calling it) is a real,
        // compile-time proof that CKFetchWebAuthTokenOperation and this
        // wrapper's signature — including its use of this codebase's own
        // `CloudKitTransport`/`CloudKitDatabaseScope` types — are both
        // valid against Vǫxtr's actual `import CloudKit` and Swift 6
        // concurrency checking (`CloudKitTransport` is `@MainActor`; this
        // reference itself proves the signature type-checks without
        // needing to actually call it, which this file's own
        // XCTEST-SAFETY note explains it deliberately never does).
        let fn: (String, CloudKitTransport, CloudKitDatabaseScope) async throws -> WorkspaceOwnershipEvidenceSpike.Outcome =
            WorkspaceOwnershipEvidenceSpike.fetchWebAuthToken(apiToken:transport:scope:)
        #expect(String(describing: type(of: fn)).contains("Outcome"))
    }
}
