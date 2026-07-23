import Foundation
import SwiftData

/// Deliberately NOT a business entity. Sprint 0's acceptance criterion is
/// "persistence works locally" — this model exists solely to prove a
/// SwiftData round-trip (write, fetch) works, without inventing any
/// Athlete/Training/Reflection entity that Sprint 1 hasn't defined yet.
/// Delete this once a real domain module needs its own @Model types.
@Model
public final class AppDiagnosticsRecord {
    public var launchedAt: Date
    public var schemaVersion: String

    public init(launchedAt: Date = .now, schemaVersion: String = "sprint0") {
        self.launchedAt = launchedAt
        self.schemaVersion = schemaVersion
    }
}
