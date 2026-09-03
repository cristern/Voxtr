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
