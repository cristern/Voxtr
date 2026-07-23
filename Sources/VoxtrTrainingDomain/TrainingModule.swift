import Foundation
import VoxtrCore

/// Training domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns LoggedActivity,
/// ActivityLoad, and TrainingAttachment (Section 9). TrainingAttachment
/// is schema-only per Section 19 — no upload/download logic exists here
/// or anywhere else in this codebase. Load calculation logic itself
/// deliberately lives outside this module — see the separate
/// Calculation Engine design; Training only stores and validates.
public struct TrainingModule: VoxtrModule {
    public static let domainID = "training"

    public init() {}
}
