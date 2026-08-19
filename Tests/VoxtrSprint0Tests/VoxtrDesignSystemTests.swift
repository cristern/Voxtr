import Foundation
import Testing
import VoxtrCoreContracts
@testable import VoxtrAppShell

/// Design Foundation V0.1: the one piece of reusable, non-visual logic
/// this round introduces — `AthleteColor.forAthleteId(_:)`'s
/// deterministic `AthleteId` → palette-entry mapping (see that method's
/// own doc comment for why this is the FALLBACK only, used when no
/// explicit `AthleteSettings.preferredColor` exists, and why this
/// derives from the id's own UUID bytes rather than any list position
/// or `hashValue`). Everything else this round adds (`VoxtrColor`,
/// `VoxtrTypography`, the reusable view modifiers, `VoxtrSectionHeading`)
/// is either a `Color`/`Font` constant or a `View`, with no meaningful
/// non-visual behaviour to unit test — runtime appearance remains a
/// TestFlight gate, not something these tests claim to prove. Athlete
/// Color canonical preference round: `AthleteColor` itself is now
/// declared in `VoxtrCoreContracts` (the persisted domain type); this
/// file tests the presentation-layer extension `VoxtrAppShell` adds to
/// it (`forAthleteId(_:)`, `color`, `displayName`).
@Suite("AthleteColor")
struct VoxtrDesignSystemTests {
    private func athleteId(_ uuidString: String) -> AthleteId {
        AthleteId(rawValue: UUID(uuidString: uuidString)!)
    }

    @Test("forAthleteId(_:) is a deterministic function of the id's own UUID bytes, always returning a valid palette case")
    func forAthleteIdIsDeterministicFromKnownBytes() {
        // All-zero bytes sum to 0 -> 0 % 8 == 0 -> the first case.
        #expect(AthleteColor.forAthleteId(athleteId("00000000-0000-0000-0000-000000000000")) == .blue)
        // Byte sum 1 -> index 1.
        #expect(AthleteColor.forAthleteId(athleteId("00000000-0000-0000-0000-000000000001")) == .indigo)
        // Byte sum 7 -> index 7, the last case.
        #expect(AthleteColor.forAthleteId(athleteId("00000000-0000-0000-0000-000000000007")) == .cyan)
        // Byte sum 8 wraps back to index 0 — the same documented
        // "duplicate colour once >8 athletes exist" wrap behaviour as
        // before, now driven by the id's own bytes instead of a list
        // index.
        #expect(AthleteColor.forAthleteId(athleteId("00000000-0000-0000-0000-000000000008")) == .blue)
        // All-0xFF bytes: 16 * 255 = 4080, 4080 % 8 == 0 -> the first case.
        #expect(AthleteColor.forAthleteId(athleteId("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")) == .blue)
    }

    @Test("forAthleteId(_:) is deterministic — the same AthleteId always returns the same colour, across repeated calls")
    func forAthleteIdIsDeterministicAcrossRepeatedCalls() {
        let id = athleteId("11111111-2222-3333-4444-555555555555")
        let firstResult = AthleteColor.forAthleteId(id)
        for _ in 0..<20 {
            #expect(AthleteColor.forAthleteId(id) == firstResult)
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

        let aliceAlone = AthleteColor.forAthleteId(alice)

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
                #expect(AthleteColor.forAthleteId(id) == aliceAlone)
            }
        }
    }

    @Test("forAthleteId(_:) always returns one of the eight palette cases")
    func forAthleteIdAlwaysReturnsAValidCase() {
        let ids = (0..<50).map { _ in AthleteId() }
        for id in ids {
            #expect(AthleteColor.allCases.contains(AthleteColor.forAthleteId(id)))
        }
    }

    /// Athlete Color canonical preference round: the Athlete Settings
    /// picker's own label text — every case must have a distinct,
    /// non-empty display name, so the picker never shows two options
    /// that read the same or a blank row for a valid persisted value.
    @Test("Every AthleteColor case has a distinct, non-empty displayName")
    func everyCaseHasADistinctDisplayName() {
        let names = AthleteColor.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == AthleteColor.allCases.count)
    }
}
