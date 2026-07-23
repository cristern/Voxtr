import Foundation
import os

/// Central logging entry point. Every domain module logs through this
/// rather than instantiating its own `os.Logger`, so subsystem/category
/// naming stays consistent as more modules are added.
///
/// ENGINEERING TRADE-OFF: the Engineering Guide does not name a specific
/// logging library. `os.Logger` was chosen (Apple-native, zero
/// dependencies, works with the system Console/Instruments) over a
/// third-party logging library. Revisit only if structured remote log
/// shipping becomes a real requirement — not needed for Sprint 0.
public enum VoxtrLog {

    private static let subsystem = "com.voxtr.app"

    /// One categorized logger per domain module, matching 02_Architecture_v1_0's
    /// domain list, so log output can be filtered by module in Console.app.
    public enum Category: String {
        case core, athlete, parent, planning, training
        case reflection, development, decisionSupport, notifications, settings
        case appShell
    }

    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}
