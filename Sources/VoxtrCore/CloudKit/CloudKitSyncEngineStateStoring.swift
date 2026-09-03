import CloudKit
import Foundation

/// Athlete Connection Foundation B1: where `CKSyncEngine`'s own opaque,
/// `Codable` continuity state (`CKSyncEngine.State.Serialization`) is
/// persisted between launches, so the engine can resume efficiently
/// instead of re-fetching everything from scratch every time.
///
/// This state is infrastructure bookkeeping about ONE device's own sync
/// progress — it is explicitly LOCAL-ONLY and must never be written into
/// the Family Shared Zone or synced to another device (Foundation B
/// discovery's own architecture boundary: "CloudKit transport ≠ domain
/// owner"; this state isn't a Vǫxtr business entity at all). `private`
/// and `shared` engine state are stored under separate keys so the two
/// `CKSyncEngine` instances (see `CloudKitTransport`) never collide.
public protocol CloudKitSyncEngineStateStoring: Sendable {
    func loadState(for scope: CloudKitDatabaseScope) -> CKSyncEngine.State.Serialization?
    func saveState(_ state: CKSyncEngine.State.Serialization, for scope: CloudKitDatabaseScope)
}

/// `UserDefaults`-backed implementation — the smallest maintainable
/// option for a small piece of per-device, non-sensitive opaque `Data`.
/// Chosen over a dedicated local SwiftData/file-based record per the B1
/// task's own "choose the smallest maintainable option" guidance: this
/// state is not a Vǫxtr business entity, so it does not belong in
/// `AppSchema`, and `UserDefaults` already is this project's established
/// place for small local-only, non-synced device state.
public final class UserDefaultsCloudKitSyncEngineStateStore: CloudKitSyncEngineStateStoring {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadState(for scope: CloudKitDatabaseScope) -> CKSyncEngine.State.Serialization? {
        guard let data = defaults.data(forKey: key(for: scope)) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    public func saveState(_ state: CKSyncEngine.State.Serialization, for scope: CloudKitDatabaseScope) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key(for: scope))
    }

    private func key(for scope: CloudKitDatabaseScope) -> String {
        "com.voxtr.cloudKitTransport.syncEngineState.\(scope)"
    }
}
