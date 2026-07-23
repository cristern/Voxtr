// swift-tools-version: 6.0
import PackageDescription

// Vǫxtr — technical foundation, updated for Domain & Data Model v1.3
// ("Complete Foundation Schema" — full field-level specs for every
// entity in the domain ownership table).
//
// This package IS the "modular monolith" described in 02_Architecture_v1_0:
// one deployable app, composed of isolated domain modules (SPM targets).
// Per v1.2's governing rule (Section 1.1): a domain module may reference
// another domain only through stable identifiers (VoxtrCoreContracts),
// read-only projections, or domain events (VoxtrCore's EventBus).
// Cross-domain SwiftData relationships are prohibited — enforced here by
// the fact that no *Domain target depends on any other *Domain target.
//
// Package names follow v1.2 Section 8.1's recommended split exactly:
// VoxtrCoreContracts, VoxtrCoreReferenceData, and *Domain per feature
// domain. VoxtrCore (Sprint 0 infrastructure — DI, EventBus, logging,
// persistence/sync protocols) and VoxtrSettings are unaffected by v1.2
// and keep their original names.

let package = Package(
    name: "Voxtr",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VoxtrCore", targets: ["VoxtrCore"]),
        .library(name: "VoxtrAppShell", targets: ["VoxtrAppShell"]),
    ],
    targets: [
        // MARK: - Infrastructure (Sprint 0, unaffected by v1.2)
        .target(name: "VoxtrCore"),

        // MARK: - Core data (v1.2 Section 3/4 — "not feature workflows")
        .target(name: "VoxtrCoreContracts"),
        .target(name: "VoxtrCoreReferenceData", dependencies: ["VoxtrCoreContracts"]),

        // MARK: - Feature domain modules (v1.2 Section 3 ownership table)
        // Each depends ONLY on VoxtrCore + VoxtrCoreContracts — never on
        // another *Domain target, and never on VoxtrCoreReferenceData
        // (they store SportId/ActivityCategoryId, not the entities).
        .target(name: "VoxtrAthleteDomain", dependencies: ["VoxtrCore", "VoxtrCoreContracts"]),
        .target(name: "VoxtrParentDomain", dependencies: ["VoxtrCore", "VoxtrCoreContracts"]),
        .target(name: "VoxtrPlanningDomain", dependencies: ["VoxtrCore", "VoxtrCoreContracts"]),
        .target(name: "VoxtrTrainingDomain", dependencies: ["VoxtrCore", "VoxtrCoreContracts"]),
        .target(name: "VoxtrReflectionDomain", dependencies: ["VoxtrCore", "VoxtrCoreContracts"]),
        .target(name: "VoxtrDevelopmentDomain", dependencies: ["VoxtrCore", "VoxtrCoreContracts"]),
        .target(name: "VoxtrDecisionSupportDomain", dependencies: ["VoxtrCore", "VoxtrCoreContracts"]),
        .target(name: "VoxtrNotificationsDomain", dependencies: ["VoxtrCore", "VoxtrCoreContracts"]),
        .target(name: "VoxtrSettings", dependencies: ["VoxtrCore", "VoxtrCoreContracts"]),

        // MARK: - Composition root (the only target allowed to see every module)
        .target(
            name: "VoxtrAppShell",
            dependencies: [
                "VoxtrCore", "VoxtrCoreContracts", "VoxtrCoreReferenceData",
                "VoxtrAthleteDomain", "VoxtrParentDomain", "VoxtrPlanningDomain",
                "VoxtrTrainingDomain", "VoxtrReflectionDomain", "VoxtrDevelopmentDomain",
                "VoxtrDecisionSupportDomain", "VoxtrNotificationsDomain", "VoxtrSettings",
            ]
        ),

        // MARK: - Verification tests
        .testTarget(
            name: "VoxtrSprint0Tests",
            dependencies: [
                "VoxtrCore", "VoxtrCoreContracts", "VoxtrCoreReferenceData", "VoxtrAppShell",
                "VoxtrAthleteDomain", "VoxtrParentDomain", "VoxtrPlanningDomain",
                "VoxtrTrainingDomain", "VoxtrReflectionDomain",
            ]
        ),
    ]
)
