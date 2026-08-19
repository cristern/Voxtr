import Foundation
import Testing
import VoxtrCoreContracts
@testable import VoxtrAppShell

/// Design Foundation V0.1: the one piece of reusable, non-visual logic
/// this round introduces — `VoxtrAthleteColor.forAthleteId(_:)`'s
/// deterministic `AthleteId` → palette-entry mapping (see that method's
/// own doc comment for why no canonical persisted athlete colour exists
/// to read instead, and why this derives from the id's own UUID bytes
/// rather than any list position or `hashValue`). Everything else this
/// round adds (`VoxtrColor`, `VoxtrTypography`, the reusable view
/// modifiers, `VoxtrSectionHeading`) is either a `Color`/`Font` constant
/// or a `View`, with no meaningful non-visual behaviour to unit test —
/// runtime appearance remains a TestFlight gate, not something these
/// tests claim to prove.
@Suite("VoxtrAthleteColor")
struct VoxtrDesignSystemTests {
    private func athleteId(_ uuidString: String) -> AthleteId {
        AthleteId(rawValue: UUID(uuidString: uuidString)!)
    }

    @Test("forAthleteId(_:) is a deterministic function of the id's own UUID bytes, always returning a valid palette case")
    func forAthleteIdIsDeterministicFromKnownBytes() {
        // All-zero bytes sum to 0 -> 0 % 8 == 0 -> the first case.
        #expect(VoxtrAthleteColor.forAthleteId(athleteId("00000000-0000-0000-0000-000000000000")) == .blue)
        // Byte sum 1 -> index 1.
        #expect(VoxtrAthleteColor.forAthleteId(athleteId("00000000-0000-0000-0000-000000000001")) == .indigo)
        // Byte sum 7 -> index 7, the last case.
        #expect(VoxtrAthleteColor.forAthleteId(athleteId("00000000-0000-0000-0000-000000000007")) == .cyan)
        // Byte sum 8 wraps back to index 0 — the same documented
        // "duplicate colour once >8 athletes exist" wrap behaviour as
        // before, now driven by the id's own bytes instead of a list
        // index.
        #expect(VoxtrAthleteColor.forAthleteId(athleteId("00000000-0000-0000-0000-000000000008")) == .blue)
        // All-0xFF bytes: 16 * 255 = 4080, 4080 % 8 == 0 -> the first case.
        #expect(VoxtrAthleteColor.forAthleteId(athleteId("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")) == .blue)
    }

    @Test("forAthleteId(_:) is deterministic — the same AthleteId always returns the same colour, across repeated calls")
    func forAthleteIdIsDeterministicAcrossRepeatedCalls() {
        let id = athleteId("11111111-2222-3333-4444-555555555555")
        let firstResult = VoxtrAthleteColor.forAthleteId(id)
        for _ in 0..<20 {
            #expect(VoxtrAthleteColor.forAthleteId(id) == firstResult)
        }
    }

    @Test("forAthleteId(_:) depends only on the id's own value, never on any list, order, or position")
    func forAthleteIdIsIndependentOfListPositionOrOrdering() {
        // The mapping takes a single AthleteId with no list/collection
        // involved at all — there is no index parameter to vary. This
        // proves the same id keeps its colour when queried standing
        // alone, in a different order, and repeated within a
        // collection — none of which can change the result, since
        // nothing about a list is ever part of the computation.
        let alice = athleteId("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let bob = athleteId("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let carol = athleteId("cccccccc-cccc-cccc-cccc-cccccccccccc")

        let aliceAlone = VoxtrAthleteColor.forAthleteId(alice)

        // Simulate re-ordering the roster around `alice` in every
        // position — first, middle, last, and repeated — none of it
        // may affect alice's own colour.
        let orderings: [[AthleteId]] = [
            [alice, bob, carol],
            [bob, alice, carol],
            [bob, carol, alice],
            [alice, alice, bob, carol],
        ]
        for ordering in orderings {
            for id in ordering where id == alice {
                #expect(VoxtrAthleteColor.forAthleteId(id) == aliceAlone)
            }
        }
    }

    @Test("forAthleteId(_:) always returns one of the eight palette cases")
    func forAthleteIdAlwaysReturnsAValidCase() {
        let ids = (0..<50).map { _ in AthleteId() }
        for id in ids {
            #expect(VoxtrAthleteColor.allCases.contains(VoxtrAthleteColor.forAthleteId(id)))
        }
    }
}
