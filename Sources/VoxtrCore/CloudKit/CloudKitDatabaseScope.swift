import Foundation

/// Athlete Connection Foundation B1: which CloudKit database a piece of
/// transport infrastructure targets. A small, project-owned enum rather
/// than exposing `CKDatabase.Scope` directly at every call site — this is
/// the "small provider/factory abstraction" the B1 task scope asked for,
/// kept intentionally tiny (two cases, matching exactly what Foundation B
/// discovery's zone model needs) rather than a larger protocol hierarchy.
///
/// Maps 1:1 onto Foundation B discovery's two CloudKit-backed placements:
/// - `.private` → the current user's own private database. Foundation B's
///   Athlete Private Zone (raw `summaryOnly`/`privateToAthlete` Reflection
///   content) lives here — never shared with the Parent's `CKShare`.
/// - `.shared` → the CloudKit shared database, where an accepted `CKShare`
///   (rooted at the `FamilyWorkspace` record, per DDM-006) actually lives
///   once B2 creates it. B1 does not create any zone or share yet — this
///   only identifies which database a later operation targets.
public enum CloudKitDatabaseScope: Sendable, Equatable, CaseIterable {
    case `private`
    case shared
}
