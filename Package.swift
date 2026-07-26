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
        // Everything below was previously an internal-only target — fine
        // for other targets *inside* this package (e.g. VoxtrAppShell
        // depending on VoxtrAthleteDomain), but invisible to anything
        // outside the package, including the native VoxtrSprint0Tests
        // target in App/Voxtr.xcodeproj. SwiftPM only exposes declared
        // `products` to external consumers — that mismatch (target
        // exists, product doesn't) is exactly what produced "Missing
        // package product" for seven targets at once.
        .library(name: "VoxtrCoreContracts", targets: ["VoxtrCoreContracts"]),
        .library(name: "VoxtrCoreReferenceData", targets: ["VoxtrCoreReferenceData"]),
        .library(name: "VoxtrAthleteDomain", targets: ["VoxtrAthleteDomain"]),
        .library(name: "VoxtrParentDomain", targets: ["VoxtrParentDomain"]),
        .library(name: "VoxtrPlanningDomain", targets: ["VoxtrPlanningDomain"]),
        .library(name: "VoxtrTrainingDomain", targets: ["VoxtrTrainingDomain"]),
        .library(name: "VoxtrReflectionDomain", targets: ["VoxtrReflectionDomain"]),
        .library(name: "VoxtrCoachingDomain", targets: ["VoxtrCoachingDomain"]),
        .library(name: "VoxtrMotivationDomain", targets: ["VoxtrMotivationDomain"]),
        .library(name: "VoxtrDevelopmentDomain", targets: ["VoxtrDevelopmentDomain"]),
        .library(name: "VoxtrDecisionSupportDomain", targets: ["VoxtrDecisionSupportDomain"]),
        .library(name: "VoxtrNotificationsDomain", targets: ["VoxtrNotificationsDomain"]),
        .library(name: "VoxtrSettings", targets: ["VoxtrSettings"]),
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

        // Sprint 14: extracted from VoxtrAppShell — the pure coaching
        // decision core (CoachingEngine, CoachingResult/CoachingInsight)
        // and its neutral input model (WeeklyCoachingContext). Depends
        // only on VoxtrCoreContracts, not VoxtrCore — unlike the other
        // *Domain targets above, nothing here needs VoxtrCore's DI
        // container, EventBus, or persistence/logging infrastructure;
        // this is pure decision logic over already-flattened value
        // types, with no need for any of that.
        .target(name: "VoxtrCoachingDomain", dependencies: ["VoxtrCoreContracts"]),

        // Sprint 15 (revised): Motivation domain — Quote and
        // DailyQuoteProvider. Athlete-agnostic (every user sees the
        // same quote on a given day, no AthleteId/LocalDate needed
        // anywhere in its API) but depends on VoxtrCoreContracts for
        // `DateProvider` — DailyQuoteProvider's injected clock
        // abstraction. That's a real, justified need, not speculative
        // coupling; VoxtrCoreContracts is the shared foundational
        // layer every domain already depends on, not another feature
        // domain, so this still doesn't introduce a domain-to-domain
        // dependency. Designed to be extended in place — Daily
        // Challenge, Weekly Theme, Reflection Prompts, Celebrations,
        // Motivation Timeline are all expected to live here later, per
        // this sprint's explicit future-proofing goal.
        .target(name: "VoxtrMotivationDomain", dependencies: ["VoxtrCoreContracts"]),
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
                "VoxtrTrainingDomain", "VoxtrReflectionDomain", "VoxtrCoachingDomain", "VoxtrMotivationDomain", "VoxtrDevelopmentDomain",
                "VoxtrDecisionSupportDomain", "VoxtrNotificationsDomain", "VoxtrSettings",
            ],
            // Sprint 15 (revised): the first resource this target has
            // ever declared — StaticQuoteRepository's bundled
            // Quotes.json. Declaring this generates the `Bundle.module`
            // extension StaticQuoteRepository.swift uses to locate it.
            resources: [.process("Resources/Quotes.json")]
        ),

        // MARK: - Verification tests
        .testTarget(
            name: "VoxtrSprint0Tests",
            dependencies: [
                "VoxtrCore", "VoxtrCoreContracts", "VoxtrCoreReferenceData", "VoxtrAppShell",
                "VoxtrAthleteDomain", "VoxtrParentDomain", "VoxtrPlanningDomain",
                "VoxtrTrainingDomain", "VoxtrReflectionDomain", "VoxtrCoachingDomain", "VoxtrMotivationDomain",
            ]
        ),
    ]
)
