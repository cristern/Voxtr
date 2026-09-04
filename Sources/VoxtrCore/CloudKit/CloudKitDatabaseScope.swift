import Foundation

/// Athlete Connection Foundation B1: which CloudKit database a piece of
/// transport infrastructure targets. A small, project-owned enum rather
/// than exposing `CKDatabase.Scope` directly at every call site — this is
/// the "small provider/factory abstraction" the B1 task scope asked for,
/// kept intentionally tiny (two cases) rather than a larger protocol
/// hierarchy.
///
/// PR #61 follow-up: this type names CloudKit DATABASE scope only — the
/// CURRENT device's own private database, or the CURRENT device's own
/// shared database (zones another owner has shared TO it). It
/// deliberately encodes no Parent/Athlete role assumption and no claim
/// about which zone lives in which database, because that depends on
/// which role the current device is actually playing:
/// - `.private` → the current user's own private database. What a Parent
///   device stores here differs from what an Athlete device stores here
///   (see `CloudKitTransport`'s own doc comment for the full, corrected
///   explanation) — this type itself makes no distinction.
/// - `.shared` → the current user's own shared database — zones shared
///   TO the current user by some other owner, never zones the current
///   user itself created/owns.
///
/// B1 does not create any zone or share yet — this only identifies which
/// database a later operation targets.
public enum CloudKitDatabaseScope: Sendable, Equatable, CaseIterable {
    case `private`
    case shared
}
