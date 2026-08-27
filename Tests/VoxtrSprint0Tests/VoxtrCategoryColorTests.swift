import Testing
import SwiftUI
@testable import VoxtrAppShell
import VoxtrCoreContracts

/// Training Breakdown round: focused tests for `VoxtrCategoryColor`'s
/// deterministic, presentation-only Sport/Activity Type colour mapping.
/// Deliberately compares `Color` VALUES (structural `Equatable`
/// equality), never rendered RGB pixel output — the Design System
/// architecture here is a plain value-returning function, not a
/// rendering pipeline, so `Color == Color` is the appropriate, stable
/// contract to test against.
@Suite("VoxtrCategoryColor (Statistics Training Breakdown)")
struct VoxtrCategoryColorTests {
    @Test("The same stable key always maps to the same color")
    func sameKeyMapsToSameColor() {
        let key = "9E3F6E9E-2B7A-4A0B-8C1D-000000000001"
        #expect(VoxtrCategoryColor.color(forStableKey: key) == VoxtrCategoryColor.color(forStableKey: key))
    }

    /// Required test: determinism must not depend on call/array order —
    /// computing the SAME set of keys in reverse order must yield the
    /// exact same per-key color as computing them in forward order.
    @Test("Mapping is independent of the order keys are computed in")
    func mappingIsIndependentOfCallOrder() {
        let keys = ["no-sport", "teamTraining", "9E3F6E9E-2B7A-4A0B-8C1D-000000000002", "strength"]
        let forward = keys.map { VoxtrCategoryColor.color(forStableKey: $0) }
        let backward = keys.reversed().map { VoxtrCategoryColor.color(forStableKey: $0) }
        #expect(forward == backward.reversed())
    }

    @Test("Every mapped color is drawn from the bounded AthleteColor palette")
    func mappedColorIsAlwaysFromTheBoundedPalette() {
        let palette = AthleteColor.allCases.map(\.color)
        let keys = ["no-sport", "teamTraining", "match", "9E3F6E9E-2B7A-4A0B-8C1D-000000000003"]
        for key in keys {
            #expect(palette.contains(VoxtrCategoryColor.color(forStableKey: key)))
        }
    }

    @Test("Two different stable keys can legitimately map to the same color slot (finite palette, acceptable collision)")
    func differentKeysMayCollideButRemainIndividuallyStable() {
        // Two distinct keys chosen only to prove collisions don't crash
        // or misbehave — the finite eight-color palette makes some
        // collision mathematically inevitable once there are more than
        // eight categories; this test isn't asserting these TWO
        // specific keys collide, only that whichever slot each maps to
        // stays stable under repeated calls.
        let keyA = "category-a"
        let keyB = "category-b"
        let firstA = VoxtrCategoryColor.color(forStableKey: keyA)
        let firstB = VoxtrCategoryColor.color(forStableKey: keyB)
        let secondA = VoxtrCategoryColor.color(forStableKey: keyA)
        let secondB = VoxtrCategoryColor.color(forStableKey: keyB)
        #expect(firstA == secondA)
        #expect(firstB == secondB)
    }
}
