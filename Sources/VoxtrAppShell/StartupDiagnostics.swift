import Foundation
import SwiftData

/// Critical startup diagnostics fix: `CompositionRootLoaderView`
/// previously showed only `error.localizedDescription` on a
/// `ModelContainer` construction failure — for a `SwiftDataError`,
/// this is often just "The operation couldn't be completed.
/// (SwiftData.SwiftDataError error 1.)", with no information about
/// which schema version was targeted, what the underlying NSError
/// actually says, or what migration path was attempted. This made
/// diagnosing the real build-130 startup failure impossible from the
/// TestFlight feedback alone.
///
/// This type extracts every field the investigation asked for —
/// concrete Swift error type, `localizedDescription`, NSError domain,
/// NSError code, `failureReason`, `recoverySuggestion`, nested
/// underlying errors, the current schema version, and the migration
/// plan's full version sequence — into one readable, multi-line
/// string. Deliberately does NOT include `NSError.userInfo` wholesale
/// (which could contain incidental values, e.g. full file paths) —
/// only the specific, named diagnostic fields requested.
public enum StartupDiagnostics {
    /// The current schema version and the full migration plan's
    /// version sequence — static facts about this build, not about any
    /// particular failure, but essential context for reading one.
    public static var schemaContext: String {
        let latestVersion = AppCurrentSchema.versionIdentifier
        let planVersions = AppSchemaMigrationPlan.schemas.map { schema in
            "\(schema.versionIdentifier.major).\(schema.versionIdentifier.minor).\(schema.versionIdentifier.patch)"
        }
        return """
        Target schema version: \(latestVersion.major).\(latestVersion.minor).\(latestVersion.patch)
        Migration plan version sequence: \(planVersions.joined(separator: " → "))
        """
    }

    /// A full, multi-line diagnostic description of `error` — the
    /// concrete Swift type, every NSError-bridged field the
    /// investigation asked for, and any nested underlying errors,
    /// unwrapped up to a reasonable depth so a genuinely nested
    /// CoreData/SwiftData failure (as build 130's own crash trace was)
    /// is fully visible rather than truncated at the first, often
    /// generic, layer.
    public static func describe(_ error: Error) -> String {
        var lines: [String] = []
        lines.append(schemaContext)
        lines.append("")
        lines.append(describeSingle(error, depth: 0))

        var current: Error? = (error as NSError).underlyingError()
        var depth = 1
        while let underlying = current, depth <= 5 {
            lines.append(describeSingle(underlying, depth: depth))
            current = (underlying as NSError).underlyingError()
            depth += 1
        }

        return lines.joined(separator: "\n")
    }

    private static func describeSingle(_ error: Error, depth: Int) -> String {
        let indent = String(repeating: "  ", count: depth)
        let nsError = error as NSError
        var parts: [String] = []
        parts.append("\(indent)Swift error type: \(type(of: error))")
        parts.append("\(indent)localizedDescription: \(error.localizedDescription)")
        parts.append("\(indent)NSError domain: \(nsError.domain)")
        parts.append("\(indent)NSError code: \(nsError.code)")
        if let failureReason = nsError.localizedFailureReason {
            parts.append("\(indent)failureReason: \(failureReason)")
        }
        if let recoverySuggestion = nsError.localizedRecoverySuggestion {
            parts.append("\(indent)recoverySuggestion: \(recoverySuggestion)")
        }
        return parts.joined(separator: "\n")
    }
}

private extension NSError {
    /// `NSUnderlyingErrorKey` is the standard, documented key CoreData
    /// (and most of Foundation) uses to chain a lower-level cause onto
    /// a higher-level error — this is exactly the chain a
    /// `NSPersistentStoreCoordinator` migration failure produces.
    func underlyingError() -> Error? {
        userInfo[NSUnderlyingErrorKey] as? Error
    }
}
