import Testing
@testable import VoxtrAppShell

/// Design Foundation V0.1: the one piece of reusable, non-visual logic
/// this round introduces — `VoxtrAthleteColor.forIndex(_:)`'s
/// deterministic index → palette-entry mapping (see that method's own
/// doc comment for why no canonical persisted athlete colour exists to
/// read instead). Everything else this round adds (`VoxtrColor`,
/// `VoxtrTypography`, the reusable view modifiers, `VoxtrSectionHeading`)
/// is either a `Color`/`Font` constant or a `View`, with no meaningful
/// non-visual behaviour to unit test — runtime appearance remains a
/// TestFlight gate, not something these tests claim to prove.
@Suite("VoxtrAthleteColor")
struct VoxtrDesignSystemTests {
    @Test("forIndex(_:) cycles deterministically through the eight-colour palette, always returning a valid case")
    func forIndexCyclesDeterministically() {
        #expect(VoxtrAthleteColor.forIndex(0) == .blue)
        #expect(VoxtrAthleteColor.forIndex(1) == .indigo)
        #expect(VoxtrAthleteColor.forIndex(7) == .cyan)
        // Wraps back to the start once the palette is exhausted —
        // the documented "duplicate colour once >8 athletes" behavior.
        #expect(VoxtrAthleteColor.forIndex(8) == .blue)
        #expect(VoxtrAthleteColor.forIndex(9) == .indigo)
    }

    @Test("forIndex(_:) is deterministic — the same index always returns the same colour")
    func forIndexIsDeterministic() {
        for index in 0..<20 {
            #expect(VoxtrAthleteColor.forIndex(index) == VoxtrAthleteColor.forIndex(index))
        }
    }

    @Test("forIndex(_:) never crashes or produces an invalid case for a negative index")
    func forIndexHandlesNegativeIndexSafely() {
        // Defensive only — no production call site passes a negative
        // index (array indices from `.enumerated()` are always >= 0) —
        // this proves the modulo arithmetic itself can't trap.
        #expect(VoxtrAthleteColor.forIndex(-1) == .cyan)
        #expect(VoxtrAthleteColor.forIndex(-8) == .blue)
    }
}
