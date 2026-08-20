import Foundation
import SwiftData
import VoxtrCoreContracts

/// Sport / Activity Identity domain foundation, Part 2: the smallest
/// repository capability needed to activate the existing, previously-
/// dormant `Sport` model — fetch all, fetch by stable `SportId`, and
/// idempotently seed the bounded canonical set. `VoxtrCoreReferenceData`
/// is the one place this owns Sport truth (per the approved contract:
/// "Do not give every feature its own Sport truth") — no `*Domain`
/// target may hold a second copy of this repository or its seed list,
/// and none needs to: they only ever store `SportId?`, never `Sport`
/// itself (see `Package.swift`'s dependency rule).
@MainActor
public final class SportRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func fetchAllSports() throws -> [Sport] {
        try modelContext.fetch(FetchDescriptor<Sport>(sortBy: [SortDescriptor(\.sortOrder)]))
    }

    /// Stable-identity resolution by typed `SportId` — never by
    /// `displayNameKey` or any localized/derived string.
    public func fetchSport(byId sportId: SportId) throws -> Sport? {
        let rawId = sportId.rawValue
        var descriptor = FetchDescriptor<Sport>(predicate: #Predicate { $0.id == rawId })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Idempotent: matches existing rows by `canonicalKey` so calling
    /// this on every launch never duplicates or re-creates a Sport that
    /// already exists. Bounded seed set only (approved contract: "Do NOT
    /// add a giant taxonomy") — Football, Hockey, Bandy. Each uses a
    /// hardcoded, deterministic well-known UUID (the same pattern
    /// `ActorId.system` already establishes in `Identifier.swift`) so
    /// identity is stable across installs/environments, never
    /// regenerated, and never derived from a localized display name.
    @discardableResult
    public func seedCanonicalSportsIfNeeded() throws -> [Sport] {
        let existingKeys = Set(try fetchAllSports().map(\.canonicalKey))
        var inserted: [Sport] = []
        for definition in Self.canonicalSports where !existingKeys.contains(definition.canonicalKey) {
            let sport = Sport(
                id: definition.id,
                canonicalKey: definition.canonicalKey,
                displayNameKey: definition.displayNameKey,
                sortOrder: definition.sortOrder
            )
            modelContext.insert(sport)
            inserted.append(sport)
        }
        if !inserted.isEmpty {
            try modelContext.save()
        }
        return inserted
    }

    private struct SportDefinition {
        let id: SportId
        let canonicalKey: String
        let displayNameKey: String
        let sortOrder: Int
    }

    private static let canonicalSports: [SportDefinition] = [
        SportDefinition(
            id: SportId(rawValue: UUID(uuidString: "9E3F6E9E-2B7A-4A0B-8C1D-000000000001")!),
            canonicalKey: "football",
            displayNameKey: "sport.football",
            sortOrder: 1
        ),
        SportDefinition(
            id: SportId(rawValue: UUID(uuidString: "9E3F6E9E-2B7A-4A0B-8C1D-000000000002")!),
            canonicalKey: "hockey",
            displayNameKey: "sport.hockey",
            sortOrder: 2
        ),
        SportDefinition(
            id: SportId(rawValue: UUID(uuidString: "9E3F6E9E-2B7A-4A0B-8C1D-000000000003")!),
            canonicalKey: "bandy",
            displayNameKey: "sport.bandy",
            sortOrder: 3
        ),
    ]
}
