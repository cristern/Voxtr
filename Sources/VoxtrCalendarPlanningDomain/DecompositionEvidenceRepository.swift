import Foundation
import SwiftData
import VoxtrCoreContracts

/// VX-038: insert/fetch `DecompositionEvidence` + its
/// `DecompositionEvidenceChild` rows TOGETHER — the two types are always
/// created and read as one unit (evidence for one split, plus every one
/// of its children), so one repository owns both, matching the "smallest
/// coherent" shape rather than forcing an artificial one-repository-per-
/// type split for two tightly-coupled tables. No `update`: evidence is
/// immutable once created — see `DecompositionEvidence`'s own "CREATE-
/// ONLY" doc comment; nothing in this domain ever rewrites an existing
/// evidence row's children.
@MainActor
public final class DecompositionEvidenceRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// One durable evidence row for the given `children` — `children`
    /// must already be in the intended presentation order; each is
    /// written with its own `orderIndex` matching its position in this
    /// array.
    @discardableResult
    public func insert(
        sourceId: ExternalPlanningSourceId,
        recurringEventIdentifier: String?,
        normalizedTitle: String?,
        createdBy: ActorId,
        children: [(athleteId: AthleteId, sportId: SportId?, activityType: ActivityType, startOffsetMinutes: Int, durationMinutes: Int)]
    ) throws -> DecompositionEvidence {
        let evidence = DecompositionEvidence(
            sourceId: sourceId,
            recurringEventIdentifier: recurringEventIdentifier,
            normalizedTitle: normalizedTitle,
            createdBy: createdBy
        )
        modelContext.insert(evidence)
        for (index, child) in children.enumerated() {
            modelContext.insert(DecompositionEvidenceChild(
                evidenceId: evidence.decompositionEvidenceId,
                athleteId: child.athleteId,
                sportId: child.sportId,
                activityType: child.activityType,
                startOffsetMinutes: child.startOffsetMinutes,
                durationMinutes: child.durationMinutes,
                orderIndex: index
            ))
        }
        try modelContext.save()
        return evidence
    }

    /// Every evidence row for ONE source — the caller applies the
    /// recurring-identifier-first, normalized-title-fallback precedence
    /// (see `CalendarPlanningCoordinationService.suggestedSplit(for:source:)`)
    /// over this small, per-family list; never returned across a source
    /// or workspace boundary.
    public func fetchAll(forSource sourceId: ExternalPlanningSourceId) throws -> [DecompositionEvidence] {
        let rawSourceId = sourceId.rawValue
        return try modelContext.fetch(FetchDescriptor<DecompositionEvidence>())
            .filter { $0.sourceId == rawSourceId }
    }

    /// Every child for ONE evidence row, ordered.
    public func fetchChildren(forEvidence evidenceId: DecompositionEvidenceId) throws -> [DecompositionEvidenceChild] {
        let rawEvidenceId = evidenceId.rawValue
        return try modelContext.fetch(FetchDescriptor<DecompositionEvidenceChild>())
            .filter { $0.evidenceId == rawEvidenceId }
            .sorted { $0.orderIndex < $1.orderIndex }
    }
}
