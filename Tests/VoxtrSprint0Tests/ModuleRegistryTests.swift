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

    // Calendar Planning Source V1: adds the `calendarPlanning` domain
    // (`CalendarPlanningModule`, registered in `ModuleRegistry.allModules()`)
    // — the tenth domain, bringing this set back in sync with the "ten
    // domains" this test's own title has always claimed. Update this set
    // (and, if the count changes again, this comment) whenever a new
    // domain module is genuinely added to `ModuleRegistry.allModules()`.
    @Test("Exactly the ten domains from 02_Architecture_v1_0 are registered")
    func registersExpectedDomains() {
        let ids = Set(ModuleRegistry.allModules().map { type(of: $0).domainID })
        let expected: Set<String> = [
            "athlete", "parent", "planning", "training", "reflection",
            "development", "decisionSupport", "notifications", "calendarPlanning", "settings",
        ]
        #expect(ids == expected)
    }

    @Test("Every registered module has a unique domain ID")
    func domainIDsAreUnique() {
        #expect(ModuleRegistry.hasUniqueDomainIDs())
    }
}
