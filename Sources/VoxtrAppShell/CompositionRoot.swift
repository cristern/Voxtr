import Foundation
import SwiftData
import VoxtrCore

/// Wires together every Core service and every domain module exactly
/// once. The real `VoxtrApp` (created in Xcode, not in this package —
/// see the note in the accompanying gap report) should do nothing more
/// than call `CompositionRoot.build()` and hand the result to its
/// SwiftUI `Scene`.
@MainActor
public final class CompositionRoot {

    public let container: DIContainer
    public let eventBus: EventBus
    public let modelContainer: ModelContainer

    private init(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) {
        self.container = container
        self.eventBus = eventBus
        self.modelContainer = modelContainer
    }

    public static func build(
        persistence: PersistenceProviding = SwiftDataPersistenceController(),
        sync: SyncProviding = NoopSyncProvider(),
        featureFlags: FeatureFlagProviding = LocalFeatureFlagProvider()
    ) async throws -> CompositionRoot {
        let container = DIContainer()
        let eventBus = EventBus()

        container.register(SyncProviding.self) { sync }
        container.register(FeatureFlagProviding.self) { featureFlags }

        let modelContainer = try persistence.makeModelContainer()

        for module in ModuleRegistry.allModules() {
            await module.configure(container: container, eventBus: eventBus)
        }

        let log = VoxtrLog.logger(.appShell)
        log.info("Sprint 0 composition root built with \(ModuleRegistry.allModules().count) modules.")

        await eventBus.publish(AppDidFinishLaunchingEvent())

        return CompositionRoot(container: container, eventBus: eventBus, modelContainer: modelContainer)
    }
}
