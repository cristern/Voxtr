import CloudKit

/// Athlete Connection Foundation B1: the smallest useful internal
/// representation of "is CloudKit usable right now" — a project-owned
/// wrapper around `CKAccountStatus` rather than exposing that type (and
/// therefore requiring `import CloudKit`) at every call site that only
/// needs to know availability, not raw CloudKit details.
///
/// `.notYetChecked` is this type's own addition, distinct from every real
/// `CKAccountStatus` case — it is the honest initial value before anyone
/// has actually asked CloudKit, never conflated with `.couldNotDetermine`
/// (a real negative answer from CloudKit itself). Never equate "not yet
/// checked"/"unavailable" with "no family exists / onboarding required" —
/// those are unrelated concerns (see `CloudKitTransport`'s own doc
/// comment).
///
/// B1 does not build user-facing error UI for any non-`.available` case —
/// that is explicitly deferred to a later slice.
public enum CloudKitAvailability: Sendable, Equatable {
    case notYetChecked
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    public init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .couldNotDetermine
        @unknown default: self = .couldNotDetermine
        }
    }
}

/// PR #77 follow-up: pairs `CloudKitTransport.refreshAvailability()`'s
/// semantic result with the safe, bounded diagnostic from the underlying
/// `CKContainer.accountStatus()` lookup, when that lookup itself threw.
/// `CloudKitAvailability` stays a plain semantic enum — no CKError data
/// folded into it — since every existing `== .available` comparison
/// throughout this codebase only ever needs the semantic half; the
/// diagnostic half exists solely so a caller several layers up (the
/// Internal Alpha on-device diagnostic surface) can show the concrete
/// `CKError.Code` behind a `.couldNotDetermine`/etc. result instead of
/// only the generic case name.
public struct CloudKitAvailabilityResult: Sendable, Equatable {
    public let availability: CloudKitAvailability
    /// `nil` for a normal, non-throwing status resolution — including a
    /// real `.noAccount`/`.restricted` answer, which is not an error and
    /// carries no `CKError` to report. Populated only when
    /// `accountStatus()` itself threw.
    public let diagnostic: CloudKitErrorDiagnostic?

    public init(availability: CloudKitAvailability, diagnostic: CloudKitErrorDiagnostic?) {
        self.availability = availability
        self.diagnostic = diagnostic
    }
}
