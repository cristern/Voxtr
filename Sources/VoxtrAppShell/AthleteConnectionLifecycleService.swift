import CloudKit
import VoxtrCore

/// Athlete Connection Foundation B2.5: the one AppShell orchestration
/// service that SEQUENCES the already-built B2.2 → B2.3 → B2.4 chain —
/// it does not reimplement any of their internal validation.
///
/// Flow:
/// 1. `participantShareCoordinator.resolveAcceptedShare(from:)` (B2.2) —
///    real CloudKit share acceptance/resolution.
/// 2. `identityBindingService.bind(acceptedWorkspaceId:)` (B2.3) — binds
///    the accepted transport identity to the existing local Vǫxtr
///    identity.
/// 3. `sessionActivationService.activate(boundIdentity:)` (B2.4) —
///    revalidates and activates the canonical `CurrentSessionActor`.
///
/// LAYERING: this file imports `CloudKit` because `connect(from:)`'s own
/// parameter type (`CKShare.Metadata`) is the real iOS-delivered
/// callback payload — the actual boundary where transport-facing input
/// arrives, exactly like B2.2's own coordinator. It does NOT put
/// SwiftData/domain lookup logic in `VoxtrCore/CloudKit` (that stays
/// B2.2's job) and does NOT put CloudKit types into `VoxtrParentDomain`/
/// `VoxtrAthleteDomain` (B2.3/B2.4 never see this file's imports).
///
/// ERROR SEMANTICS: never flattens errors into a string here — each
/// stage's real, typed underlying `Error` is preserved by wrapping it in
/// the matching `AthleteConnectionLifecycleError` case. No retry loop,
/// no sleep/delay, no automatic fallback identity — a failure at any
/// stage stops the chain and surfaces explicitly.
///
/// TESTABILITY: depends on the CONCRETE `FamilyWorkspaceParticipantShareCoordinator`
/// rather than a protocol seam — a seam would buy nothing here.
/// `CKShare.Metadata` has no public initializer reachable without a real
/// accepted share (B2.2's own XCTEST-SAFETY doc comment), so no fake
/// conforming to any protocol could ever be exercised via `connect(from:)`
/// in a test either way; introducing one would be an abstraction with no
/// testing payoff. `connect(acceptedShare:)` below is the actual,
/// fully-testable seam this service exposes for B2.3 sequencing — see
/// this file's own test file for exactly what is and is not covered, and
/// why.
///
/// `sessionActivationService`, by contrast, IS typed against the
/// `AthleteSessionActivating` protocol below rather than the concrete
/// `AthleteSessionActivationService` (a `final class`, so no subclass
/// seam is possible either way). Reason: proving this service correctly
/// wraps a GENUINE later B2.4 failure (distinct from a B2.3 failure)
/// requires a participant that is `.active` at B2.3 bind time but
/// rejected at B2.4 activation time — e.g. revoked or re-linked between
/// the two calls. No canonical repository/domain transition exists yet
/// to move an already-`.active` `WorkspaceParticipant` into such a state
/// (`ParentWorkspaceRepository`'s `acceptInvitation`/`declineInvitation`/
/// `revokeInvitation` all require `state == .invited`), so fabricating
/// that persisted state directly would mean mutating a `@Model` field in
/// a way production code itself cannot reach — exactly what this
/// codebase's own conventions forbid. The protocol seam instead lets a
/// test run B2.3 for real (a genuinely `.active` participant, never an
/// impossible domain state) and substitute a fake B2.4 collaborator that
/// throws a real `AthleteSessionActivationError` case — proving this
/// service's own wrapping/sequencing, not re-testing B2.4's internal
/// validation (already covered by B2.4's own test suite). The one
/// production conformance is `AthleteSessionActivationService` itself
/// (below); nothing about B2.4's own contract, validation, or call sites
/// changed to introduce this — it remains the sole real implementation
/// this service is ever constructed with in production
/// (`CompositionRoot`).
///
/// ACTOR ISOLATION: `@MainActor`, matching all three collaborators.
@MainActor
public final class AthleteConnectionLifecycleService {

    private let participantShareCoordinator: FamilyWorkspaceParticipantShareCoordinator
    private let identityBindingService: AthleteConnectionIdentityBindingService
    private let sessionActivationService: AthleteSessionActivating

    public init(
        participantShareCoordinator: FamilyWorkspaceParticipantShareCoordinator,
        identityBindingService: AthleteConnectionIdentityBindingService,
        sessionActivationService: AthleteSessionActivating
    ) {
        self.participantShareCoordinator = participantShareCoordinator
        self.identityBindingService = identityBindingService
        self.sessionActivationService = sessionActivationService
    }

    /// The real, production entry point — takes the actual `CKShare
    /// .Metadata` iOS hands the app via `application(_:
    /// userDidAcceptCloudKitShareWith:)`. Performs real CloudKit network
    /// I/O (via B2.2), so — matching `FamilyWorkspaceParticipantShareCoordinator
    /// .resolveAcceptedShare(from:)`'s own XCTEST-SAFETY doc comment —
    /// this specific entry point is never exercised from a unit test;
    /// `connect(acceptedShare:)` below is the directly-testable
    /// continuation of the same sequencing logic.
    public func connect(from metadata: CKShare.Metadata) async throws -> CurrentSessionActor {
        let accepted: AcceptedFamilyWorkspaceShare
        do {
            accepted = try await participantShareCoordinator.resolveAcceptedShare(from: metadata)
        } catch {
            throw AthleteConnectionLifecycleError.shareAcceptanceOrResolutionFailed(error)
        }
        return try connect(acceptedShare: accepted)
    }

    /// The B2.3 → B2.4 continuation, taking an ALREADY-resolved B2.2
    /// result directly — no `CKShare.Metadata`/CloudKit I/O involved, so
    /// this is fully unit-testable against a locally-constructed
    /// `AcceptedFamilyWorkspaceShare` (see that type's own doc comment:
    /// its fields are freely constructible, unlike `CKShare.Metadata`
    /// itself). Not `private` so `AthleteConnectionLifecycleServiceTests`
    /// (`@testable import`) can call it directly to test B2.3/B2.4
    /// sequencing and failure propagation without CloudKit.
    func connect(acceptedShare: AcceptedFamilyWorkspaceShare) throws -> CurrentSessionActor {
        let bound: BoundAthleteIdentity
        do {
            bound = try identityBindingService.bind(acceptedWorkspaceId: acceptedShare.workspaceId)
        } catch {
            throw AthleteConnectionLifecycleError.identityBindingFailed(error)
        }

        do {
            return try sessionActivationService.activate(boundIdentity: bound)
        } catch {
            throw AthleteConnectionLifecycleError.sessionActivationFailed(error)
        }
    }
}

/// Test seam ONLY: lets `AthleteConnectionLifecycleServiceTests`
/// substitute a fake B2.4 collaborator so a genuine LATER activation
/// failure (after a real, successful B2.3 bind) can be tested without
/// fabricating a persisted domain state production code itself cannot
/// reach — see `AthleteConnectionLifecycleService`'s own doc comment for
/// the full rationale. `AthleteSessionActivationService` (B2.4, unmodified)
/// conforms below and is the only production implementation ever passed
/// in (`CompositionRoot`).
///
/// `@MainActor`: matches `AthleteSessionActivationService.activate(
/// boundIdentity:)`'s own isolation exactly — that service is
/// `@MainActor` (it touches `ParentWorkspaceRepository`, itself
/// `@MainActor` because it touches `ModelContext`), so its conformance
/// below would otherwise need to satisfy a `nonisolated` protocol
/// requirement with a main-actor-isolated method, which Swift 6 rejects
/// as a potential data race. Isolating the protocol itself — not
/// `@preconcurrency`, not `nonisolated` on the service — is the correct
/// fix: every real and fake conformer in this codebase already runs on
/// `@MainActor` (`AthleteConnectionLifecycleService` itself is
/// `@MainActor`, and so is every test that constructs a fake), so this
/// isolation reflects how the type is actually used, not an artificial
/// constraint.
@MainActor
public protocol AthleteSessionActivating {
    func activate(boundIdentity: BoundAthleteIdentity) throws -> CurrentSessionActor
}

extension AthleteSessionActivationService: AthleteSessionActivating {}

/// Explicit, differentiated failure semantics — never flattened into a
/// generic string. Each case wraps the real underlying typed error from
/// the stage that failed (`FamilyWorkspaceShareAcceptanceError`,
/// `AthleteConnectionIdentityBindingError`, or
/// `AthleteSessionActivationError`, respectively) rather than re-deriving
/// details. Not `Sendable`/`Equatable`: wraps an existential `Error`,
/// mirroring `FamilyWorkspaceShareAcceptanceError`'s (B2.2) own
/// reasoning — every throw/catch site stays within this service's own
/// `@MainActor` isolation.
public enum AthleteConnectionLifecycleError: Error {
    /// B2.2 failed — either resolving/accepting the CloudKit share
    /// itself, or decoding the shared root record. The chain stops here;
    /// B2.3/B2.4 are never invoked.
    case shareAcceptanceOrResolutionFailed(Error)
    /// B2.2 succeeded, but B2.3 could not bind the accepted transport
    /// identity to an existing local Vǫxtr identity. The chain stops
    /// here; B2.4 is never invoked.
    case identityBindingFailed(Error)
    /// B2.2 and B2.3 both succeeded, but B2.4 could not (re)validate and
    /// activate the bound identity as the current session actor.
    case sessionActivationFailed(Error)
}

extension AthleteConnectionLifecycleError {
    /// A short, calm, non-technical description safe for the minimal
    /// Internal Alpha UI (`AthleteRootView`) — deliberately never
    /// includes the wrapped underlying error's own description, which
    /// may reference CloudKit-specific details (e.g. `CKError`
    /// descriptions can include zone/record identifiers). The real
    /// underlying `Error` remains available for logs/debugging via each
    /// case's own associated value — see `AthleteRuntimeSession
    /// .handleAcceptedCloudKitShare(_:)`, which logs it before storing
    /// only this presentation-safe state.
    public var presentationSafeDescription: String {
        switch self {
        case .shareAcceptanceOrResolutionFailed:
            "Couldn't confirm the invitation with iCloud yet."
        case .identityBindingFailed:
            "Couldn't match this invitation to an existing Vǫxtr athlete."
        case .sessionActivationFailed:
            "Couldn't activate this connection right now."
        }
    }
}
