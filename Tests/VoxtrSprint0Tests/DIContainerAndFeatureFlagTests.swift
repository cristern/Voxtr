import Testing
import VoxtrCore

@Suite("DI container")
struct DIContainerTests {
    protocol Greeter { func greet() -> String }
    struct EnglishGreeter: Greeter { func greet() -> String { "hello" } }

    @Test("Registered services resolve to the same implementation")
    func registerAndResolve() {
        let container = DIContainer()
        container.register(Greeter.self) { EnglishGreeter() }
        #expect(container.resolve(Greeter.self).greet() == "hello")
    }

    @Test("Resolving an unregistered optional service returns nil")
    func resolveOptionalMissing() {
        let container = DIContainer()
        #expect(container.resolveOptional(Greeter.self) == nil)
    }
}

@Suite("Feature flags")
struct FeatureFlagTests {

    @Test("A flag defaults to disabled, then reflects being set")
    func localProviderTogglesFlag() {
        let suiteName = "sprint0-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults suite")
            return
        }
        let provider = LocalFeatureFlagProvider(defaults: defaults)

        #expect(provider.isEnabled(.sprint0DiagnosticsEnabled) == false)
        provider.setEnabled(true, for: .sprint0DiagnosticsEnabled)
        #expect(provider.isEnabled(.sprint0DiagnosticsEnabled) == true)

        defaults.removePersistentDomain(forName: suiteName)
    }
}
