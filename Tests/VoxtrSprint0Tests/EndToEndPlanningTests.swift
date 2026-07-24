import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrParentDomain
import VoxtrAthleteDomain
import VoxtrPlanningDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// S2.5: mirrors EndToEndOnboardingTests.swift's pattern — a real on-disk
// SQLite store (temp file, cleaned up after), with a SECOND, independent
// ModelContainer built against the same file to prove persistence
// survives the container itself being discarded and recreated, not just
// a fresh repository instance reading from a container that never went
// away.

@Suite("End-to-end weekly planning lifecycle (S2.5)", .serialized)
struct EndToEndPlanningTests {

    @Test("Restore family → create draft → add activities → recreate container → restore week+activities → edit while draft → commit → edit rejected after commit")
    @MainActor
    func fullPlanningLifecycleAcrossContainerRecreation() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("e2e-planning-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(AppSchema.modelTypes)
        let weekStart = LocalDate(year: 2026, month: 1, day: 5)

        // 1. Restore existing family (create it first, on disk).
        let firstConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let firstContainer = try ModelContainer(for: schema, configurations: [firstConfiguration])
        let onboardingCoordinator = FamilyOnboardingCoordinator(
            modelContext: firstContainer.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: firstContainer.mainContext),
            athleteRepository: AthleteRepository(modelContext: firstContainer.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: firstContainer.mainContext)
        )
        let created = try onboardingCoordinator.createFamily(
            parentGivenName: "Kari",
            athleteGivenName: "Jonas",
            athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
            athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            athleteDevelopmentStage: .parentLed
        )
        let athleteId = created.athlete.athleteId

        let firstRestorationService = FamilyRestorationService(
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: firstContainer.mainContext),
            athleteRepository: AthleteRepository(modelContext: firstContainer.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: firstContainer.mainContext)
        )
        guard case .existingFamily = try firstRestorationService.restoreState() else {
            Issue.record("Expected .existingFamily right after creating it")
            return
        }

        // 2. Create current-week draft, 3. add multiple activities.
        let firstPlanningRepository = PlanningRepository(modelContext: firstContainer.mainContext)
        let firstPlanningService = PlanningService(repository: firstPlanningRepository)
        let weekPlan = try firstPlanningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try firstPlanningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: LocalDate(year: 2026, month: 1, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try firstPlanningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .recovery,
            title: "Mobility session", localDate: LocalDate(year: 2026, month: 1, day: 7),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        // 4. Recreate ModelContainer.
        let secondConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let secondContainer = try ModelContainer(for: schema, configurations: [secondConfiguration])

        // 5. Restore the same week and activities.
        let secondRestorationService = FamilyRestorationService(
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: secondContainer.mainContext),
            athleteRepository: AthleteRepository(modelContext: secondContainer.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: secondContainer.mainContext)
        )
        guard case .existingFamily = try secondRestorationService.restoreState() else {
            Issue.record("Expected .existingFamily after recreating the container")
            return
        }
        let secondPlanningRepository = PlanningRepository(modelContext: secondContainer.mainContext)
        let secondPlanningService = PlanningService(repository: secondPlanningRepository)
        let restoredWeekPlan = try secondPlanningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        #expect(restoredWeekPlan.id == weekPlan.id, "getOrCreateWeekPlan must return the SAME plan, not create a new one")
        let restoredActivities = try secondPlanningService.fetchPlannedActivities(forWeekPlan: restoredWeekPlan.weekPlanId)
        #expect(restoredActivities.count == 2)
        #expect(restoredActivities.map(\.title) == ["Endurance run", "Mobility session"])

        // 6. Edit an activity while draft.
        let firstActivity = try #require(restoredActivities.first)
        let edited = try secondPlanningService.editPlannedActivity(
            firstActivity.plannedActivityId,
            expectedWeekPlanId: restoredWeekPlan.weekPlanId,
            activityType: firstActivity.activityType,
            title: "Long endurance run",
            localDate: firstActivity.localDate,
            timeZoneId: firstActivity.timeZoneId
        )
        #expect(edited.title == "Long endurance run")

        // 7. Commit the week.
        let committed = try secondPlanningService.commitWeekPlan(
            restoredWeekPlan.weekPlanId,
            expectedRevision: restoredWeekPlan.revision,
            committedBy: ActorId(rawValue: created.participant.id)
        )
        #expect(committed.status == .committed)

        // 8. Verify editing is rejected after commit.
        #expect(throws: PlanningServiceError.self) {
            try secondPlanningService.editPlannedActivity(
                firstActivity.plannedActivityId,
                expectedWeekPlanId: restoredWeekPlan.weekPlanId,
                activityType: firstActivity.activityType,
                title: "Should not apply",
                localDate: firstActivity.localDate,
                timeZoneId: firstActivity.timeZoneId
            )
        }
        let stillEdited = try secondPlanningRepository.fetchPlannedActivity(byId: firstActivity.plannedActivityId)
        #expect(stillEdited?.title == "Long endurance run")
    }
}
