import Testing
@testable import VoxtrAppShell
import VoxtrCore

// ENGINEERING TRADE-OFF: the Engineering Guide mandates Swift 6 but does
// not name a specific test framework. Swift Testing (`import Testing`)
// was chosen over XCTest as it's the modern, strict-concurrency-native
// framework for Swift 6 — consistent with the Guide's stated technology
// list. Revisit only if the eventual iOS deployment target can't yet
// support it.

@Suite("Module registry")
struct ModuleRegistryTests {

    @Test("Exactly the ten domains from 02_Architecture_v1_0 are registered")
    func registersExpectedDomains() {
        let ids = Set(ModuleRegistry.allModules().map { type(of: $0).domainID })
        let expected: Set<String> = [
            "athlete", "parent", "planning", "training", "reflection",
            "development", "decisionSupport", "notifications", "settings",
        ]
        #expect(ids == expected)
    }

    @Test("Every registered module has a unique domain ID")
    func domainIDsAreUnique() {
        #expect(ModuleRegistry.hasUniqueDomainIDs())
    }
}
