import Foundation
import SwiftData
import VoxtrCore

/// Wires together every Core service and every domain module exactly
/// once. Both `AthleteApp` and `ParentApp` call `CompositionRoot.build()`
/// once at launch (via `CompositionRootLoaderView`) and use the
/// resulting `modelContainer` for the rest of the app's lifetime.
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
        persistence: PersistenceProviding = SwiftDataPersistenceController(modelTypes: AppSchema.modelTypes),
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
        log.info("Composition root built with \(ModuleRegistry.allModules().count) modules, schema of \(AppSchema.modelTypes.count) model types.")

        await eventBus.publish(AppDidFinishLaunchingEvent())

        return CompositionRoot(container: container, eventBus: eventBus, modelContainer: modelContainer)
    }
}
