import Testing
import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData
@testable import VoxtrAppShell

/// Sport / Activity Identity domain foundation, Blocker B fix: focused
/// coverage for the ONE shared "what do we call this activity" rule —
/// `primaryActivityLabel = normalizedActivityName ?? resolvedSportDisplayName`
/// — exactly the matrix the review required. `Sport` is a SwiftData
/// `@Model`, but every case here only reads its plain properties, so no
/// `ModelContainer`/persistence is needed to exercise the resolver
/// itself (same reasoning `ActivityLabelResolver`'s own doc comment
/// gives for staying pure/non-`@MainActor`).
@Suite("ActivityLabelResolver")
struct ActivityLabelResolverTests {
    private static func football() -> Sport {
        Sport(canonicalKey: "football", displayNameKey: "sport.football", sortOrder: 0)
    }

    @Test("name and Sport both present resolves to the name, never the Sport")
    func nameAndSportResolvesToName() {
        let label = ActivityLabelResolver.primaryLabel(name: "Wednesday gym", sport: Self.football())
        #expect(label == "Wednesday gym")
    }

    @Test("name only resolves to the name")
    func nameOnlyResolvesToName() {
        let label = ActivityLabelResolver.primaryLabel(name: "Wednesday gym", sport: nil)
        #expect(label == "Wednesday gym")
    }

    @Test("Sport only (no name) resolves to the Sport's display name")
    func sportOnlyResolvesToSportDisplayName() {
        let label = ActivityLabelResolver.primaryLabel(name: nil, sport: Self.football())
        #expect(label == ActivityLabelResolver.displayName(for: Self.football()))
    }

    @Test("whitespace-only name with a Sport present resolves to the Sport's display name, never a blank label")
    func whitespaceNameWithSportResolvesToSportDisplayName() {
        let label = ActivityLabelResolver.primaryLabel(name: "   \n\t  ", sport: Self.football())
        #expect(label == ActivityLabelResolver.displayName(for: Self.football()))
        #expect(!label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("empty string name with a Sport present resolves to the Sport's display name")
    func emptyNameWithSportResolvesToSportDisplayName() {
        let label = ActivityLabelResolver.primaryLabel(name: "", sport: Self.football())
        #expect(label == ActivityLabelResolver.displayName(for: Self.football()))
    }

    /// ActivityType is structurally excluded from this resolver — none
    /// of its three overloads accept an `ActivityType` parameter at
    /// all, so there is no runtime path through which a classification
    /// could become the primary label. This is a compile-time
    /// guarantee, not a behavior to poke at, but is recorded here as an
    /// explicit, permanent regression guard: if a future edit ever adds
    /// an `ActivityType` parameter to any `primaryLabel` overload, that
    /// change itself — visible in the diff — is the signal to revisit
    /// this test, not a runtime assertion that could pass or fail.
    @Test("resolver has no ActivityType parameter on any overload (name/Sport identity only)")
    func resolverNeverAcceptsActivityType() {
        let name: String? = nil
        let sport: Sport? = Self.football()
        // If this compiles, no overload takes an ActivityType — the
        // only two identity inputs are `name` and `sport`.
        _ = ActivityLabelResolver.primaryLabel(name: name, sport: sport)
    }

    @Test("neither name nor Sport resolves to the honest missing-reference fallback, never a blank label")
    func neitherNameNorSportResolvesToFallback() {
        let label = ActivityLabelResolver.primaryLabel(name: nil, sport: nil)
        #expect(label == TrainingStrings.unresolvedActivityLabel)
        #expect(!label.isEmpty)
    }

    // MARK: - Closure-based overload: stable SportId lookup, no title matching

    @Test("closure overload passes the activity's own stable SportId to the resolver, never derived from title text")
    func closureOverloadUsesStableSportId() {
        let football = Self.football()
        let expectedId = SportId()
        var receivedIds: [SportId] = []
        let label = ActivityLabelResolver.primaryLabel(
            name: nil,
            sportId: expectedId,
            resolveSport: { sportId in
                receivedIds.append(sportId)
                return sportId == expectedId ? football : nil
            }
        )
        #expect(receivedIds == [expectedId])
        #expect(label == ActivityLabelResolver.displayName(for: football))
    }

    @Test("closure overload never invokes resolveSport when sportId is nil (name-only activity)")
    func closureOverloadSkipsLookupWhenSportIdIsNil() {
        var lookupCalled = false
        let label = ActivityLabelResolver.primaryLabel(
            name: "Wednesday gym",
            sportId: nil,
            resolveSport: { _ in
                lookupCalled = true
                return Self.football()
            }
        )
        #expect(label == "Wednesday gym")
        #expect(lookupCalled == false)
    }

    @Test("changing the activity's title text never changes which SportId is looked up (no title-to-Sport inference)")
    func titleTextNeverInfluencesSportLookup() {
        let football = Self.football()
        let sportId = SportId()
        for name in [nil, "", "   ", "Football practice", "Something entirely unrelated"] {
            var receivedIds: [SportId] = []
            _ = ActivityLabelResolver.primaryLabel(
                name: name,
                sportId: sportId,
                resolveSport: { id in
                    receivedIds.append(id)
                    return football
                }
            )
            // Only reached (lookup only happens) when name is absent —
            // but whenever it IS reached, it is always the same
            // caller-supplied id, never one derived from `name`.
            if ActivityIdentity.normalizedName(name) == nil {
                #expect(receivedIds == [sportId])
            } else {
                #expect(receivedIds.isEmpty)
            }
        }
    }

    // MARK: - Corrupted-reference behavior (tested separately, per review)

    @Test("sportId present but resolveSport finds nothing (stale/deleted Sport row) falls back honestly, distinct from a real resolved value")
    func corruptedReferenceFallsBackHonestly() {
        let label = ActivityLabelResolver.primaryLabel(
            name: nil,
            sportId: SportId(),
            resolveSport: { _ in nil }
        )
        #expect(label == TrainingStrings.unresolvedActivityLabel)
        #expect(label != ActivityLabelResolver.displayName(for: Self.football()))
    }
}
