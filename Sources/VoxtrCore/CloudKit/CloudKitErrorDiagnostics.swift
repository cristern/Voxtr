import CloudKit
import Foundation

/// Athlete Connection invitation-flow runtime diagnostics follow-up
/// (ParentApp "Connect Athlete App" — build 502/507/511/516/119/123/124):
/// a small, PURE (no CloudKit I/O, no network, no entitlement) classifier
/// that turns any `Error` thrown along the invitation path into a small
/// set of SAFE, structured, loggable fields.
///
/// WHY: with the CKContainer signing crash resolved (PR #75), "Connect
/// Athlete App" now fails gracefully with a generic friendly message —
/// but the actual `CKError.Code` behind that failure was being discarded
/// at TWO separate points before this file existed:
///
/// 1. `FamilyWorkspaceOwnerShareCoordinator`'s own `log.error(...)` calls
///    captured only `error.localizedDescription` — free natural-language
///    text, not a stable, filterable code.
/// 2. `AthleteFamilyManagementViewModel.message(forHandoffError:)`
///    pattern-matches on `AthleteConnectionOwnerHandoffError`'s CASE only
///    and never reads the case's own associated `Error` payload at all.
///
/// Neither location made it possible to answer "which CKError.Code
/// actually happened" from a TestFlight device's Console/sysdiagnose log.
///
/// SAFETY: never includes a human-readable description string (which
/// could echo request/record context), never a `CKRecord.ID`/record
/// content, never athlete/profile/account data. Only classification
/// fields Apple's own `CKError` type exposes as plain, non-identifying
/// value types (`Code`, `retryAfterSeconds`, a COUNT and a deduped SET of
/// child codes for partial failures — never the `CKRecord.ID` keys
/// `partialErrorsByItemID` uses).
///
/// TESTABILITY: `CKError(_ code:userInfo:)` is a plain, synchronous value
/// initializer (no I/O, no entitlement — documented back to iOS 8, long
/// before CloudKit sharing existed) exactly like this file's own sibling
/// `FamilyWorkspaceOwnerShareCoordinator.isRecoverableShareCreationConflict(code:)`
/// already relies on for its own XCTest coverage — this type's own
/// `classify(stage:error:)` is `nonisolated` and side-effect-free for the
/// same reason, directly unit-testable with no CloudKit entitlement.
public struct CloudKitErrorDiagnostic: Equatable, Sendable {
    public let stage: String
    /// "CKError" when `error` is one; otherwise the Swift runtime type
    /// name of whatever was thrown (e.g. "DecodingError") — never its
    /// message text.
    public let errorTypeName: String
    /// Symbolic `CKError.Code` case name (e.g. "networkUnavailable"),
    /// produced by `CloudKitErrorDiagnostics.codeName(_:)` — see that
    /// function's own doc comment for why this is an explicit switch
    /// rather than `String(describing:)` (PR #76 follow-up: on the real
    /// Codemagic/Xcode toolchain, `String(describing:)` on a `CKError.Code`
    /// renders `"CKErrorCode(rawValue: N)"`, not the symbolic case name —
    /// this codebase had no compiler available to catch that assumption
    /// before Codemagic's own test run proved it wrong).
    public let ckErrorCode: String?
    public let ckErrorCodeRawValue: Int?
    public let retryAfterSeconds: Double?
    /// Count of entries in `CKError.partialErrorsByItemID`, when present.
    public let partialFailureCount: Int?
    /// Deduped, sorted `CKError.Code` names of the PARTIAL failures —
    /// never their `CKRecord.ID` keys.
    public let partialFailureCodes: [String]?
    /// Only populated when `error` is NOT a `CKError` — the bridged
    /// `NSError` domain/code (every Swift `Error` bridges to `NSError`;
    /// this mirrors the same bridging this codebase's own
    /// `FamilyWorkspaceOwnerShareCoordinator` already relies on to reach
    /// `CKRecordChangedErrorServerRecordKey`).
    public let underlyingDomain: String?
    public let underlyingCode: Int?

    public init(
        stage: String,
        errorTypeName: String,
        ckErrorCode: String?,
        ckErrorCodeRawValue: Int?,
        retryAfterSeconds: Double?,
        partialFailureCount: Int?,
        partialFailureCodes: [String]?,
        underlyingDomain: String?,
        underlyingCode: Int?
    ) {
        self.stage = stage
        self.errorTypeName = errorTypeName
        self.ckErrorCode = ckErrorCode
        self.ckErrorCodeRawValue = ckErrorCodeRawValue
        self.retryAfterSeconds = retryAfterSeconds
        self.partialFailureCount = partialFailureCount
        self.partialFailureCodes = partialFailureCodes
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
    }
}

public enum CloudKitErrorDiagnostics {

    /// PURE — no CloudKit I/O, no network, no entitlement requirement.
    /// `nonisolated`: touches no actor state, matching this file's own
    /// `FamilyWorkspaceOwnerShareCoordinator.isRecoverableShareCreationConflict(code:)`
    /// precedent for why a pure classification helper should not inherit
    /// `@MainActor` isolation merely by being declared near CloudKit code.
    public nonisolated static func classify(stage: String, error: Error) -> CloudKitErrorDiagnostic {
        guard let ckError = error as? CKError else {
            let nsError = error as NSError
            return CloudKitErrorDiagnostic(
                stage: stage,
                errorTypeName: String(describing: type(of: error)),
                ckErrorCode: nil,
                ckErrorCodeRawValue: nil,
                retryAfterSeconds: nil,
                partialFailureCount: nil,
                partialFailureCodes: nil,
                underlyingDomain: nsError.domain,
                underlyingCode: nsError.code
            )
        }

        var partialCount: Int?
        var partialCodes: [String]?
        if let partial = ckError.partialErrorsByItemID, !partial.isEmpty {
            partialCount = partial.count
            let codes = partial.values.compactMap { ($0 as? CKError)?.code }
            partialCodes = Array(Set(codes.map(codeName))).sorted()
        }

        return CloudKitErrorDiagnostic(
            stage: stage,
            errorTypeName: "CKError",
            ckErrorCode: codeName(ckError.code),
            ckErrorCodeRawValue: ckError.code.rawValue,
            retryAfterSeconds: ckError.retryAfterSeconds,
            partialFailureCount: partialCount,
            partialFailureCodes: partialCodes,
            underlyingDomain: nil,
            underlyingCode: nil
        )
    }

    /// Explicit symbolic name for a `CKError.Code` — PR #76 follow-up:
    /// `String(describing: someCode)` was assumed to render the case name
    /// (matching Swift's usual synthesized `Equatable`/`CustomStringConvertible`
    /// behavior for an NS_ERROR_ENUM-imported type), but Codemagic's real
    /// Xcode toolchain proved that assumption false — it renders
    /// `"CKErrorCode(rawValue: 9)"` instead, because `CKError.Code` is
    /// bridged from an Objective-C `NS_ERROR_ENUM`/`NS_TYPED_ENUM`-style
    /// integer constant, not a native Swift enum with a synthesized
    /// description. An explicit switch, verified by Codemagic's own
    /// compiler (this repository has none locally), is the correct fix.
    /// `@unknown default`: covers a raw value from a future SDK this
    /// switch predates, rather than failing to compile against it or
    /// silently mis-mapping it to an existing case.
    public nonisolated static func codeName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: "internalError"
        case .partialFailure: "partialFailure"
        case .networkUnavailable: "networkUnavailable"
        case .networkFailure: "networkFailure"
        case .badContainer: "badContainer"
        case .serviceUnavailable: "serviceUnavailable"
        case .requestRateLimited: "requestRateLimited"
        case .missingEntitlement: "missingEntitlement"
        case .notAuthenticated: "notAuthenticated"
        case .permissionFailure: "permissionFailure"
        case .unknownItem: "unknownItem"
        case .invalidArguments: "invalidArguments"
        case .resultsTruncated: "resultsTruncated"
        case .serverRecordChanged: "serverRecordChanged"
        case .serverRejectedRequest: "serverRejectedRequest"
        case .assetFileNotFound: "assetFileNotFound"
        case .assetFileModified: "assetFileModified"
        case .incompatibleVersion: "incompatibleVersion"
        case .constraintViolation: "constraintViolation"
        case .operationCancelled: "operationCancelled"
        case .changeTokenExpired: "changeTokenExpired"
        case .batchRequestFailed: "batchRequestFailed"
        case .zoneBusy: "zoneBusy"
        case .badDatabase: "badDatabase"
        case .quotaExceeded: "quotaExceeded"
        case .zoneNotFound: "zoneNotFound"
        case .limitExceeded: "limitExceeded"
        case .userDeletedZone: "userDeletedZone"
        case .tooManyParticipants: "tooManyParticipants"
        case .alreadyShared: "alreadyShared"
        case .referenceViolation: "referenceViolation"
        case .managedAccountRestricted: "managedAccountRestricted"
        case .participantMayNeedVerification: "participantMayNeedVerification"
        case .serverResponseLost: "serverResponseLost"
        case .assetNotAvailable: "assetNotAvailable"
        case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
        case .participantAlreadyInvited: "participantAlreadyInvited"
        @unknown default: "unknown(rawValue: \(code.rawValue))"
        }
    }

    /// Single-line, greppable format:
    /// `AthleteInviteCloudKit stage=share-save ckCode=permissionFailure ckCodeRaw=10`
    /// — matches the shape requested for TestFlight Console/sysdiagnose
    /// filtering. `nonisolated`/pure: string formatting only.
    public nonisolated static func format(_ diagnostic: CloudKitErrorDiagnostic) -> String {
        var parts = ["AthleteInviteCloudKit", "stage=\(diagnostic.stage)"]
        if let code = diagnostic.ckErrorCode {
            parts.append("ckCode=\(code)")
            if let raw = diagnostic.ckErrorCodeRawValue {
                parts.append("ckCodeRaw=\(raw)")
            }
        } else {
            parts.append("errorType=\(diagnostic.errorTypeName)")
            if let domain = diagnostic.underlyingDomain {
                parts.append("domain=\(domain)")
            }
            if let code = diagnostic.underlyingCode {
                parts.append("code=\(code)")
            }
        }
        if let retryAfter = diagnostic.retryAfterSeconds {
            parts.append("retryAfter=\(retryAfter)")
        }
        if let count = diagnostic.partialFailureCount {
            parts.append("partialFailureCount=\(count)")
        }
        if let codes = diagnostic.partialFailureCodes, !codes.isEmpty {
            parts.append("partialFailureCodes=\(codes.joined(separator: ","))")
        }
        return parts.joined(separator: " ")
    }

    /// Internal Alpha diagnostic surface follow-up: a short, on-screen
    /// form — `"<stage> · <code>"` — for a Product Owner to read directly
    /// off a TestFlight device, distinct from `format(_:)`'s fuller
    /// greppable line (used for `os.Logger`/Copy diagnostic). Uses
    /// `errorTypeName` as the code half when there is no `CKError.Code`
    /// (e.g. `FamilyWorkspaceSharingError.accountUnavailable`'s own
    /// `CloudKitAvailability` case name) — never `localizedDescription`.
    public nonisolated static func conciseDisplay(_ diagnostic: CloudKitErrorDiagnostic) -> String {
        let code = diagnostic.ckErrorCode ?? diagnostic.errorTypeName
        return "\(diagnostic.stage) · \(code)"
    }
}
