import Testing
import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like PersistenceTests.swift, these exercise @Model types and
// therefore require the Xcode/macOS SwiftData runtime to actually run —
// written but not executed in this sandbox.

@Suite("Identifier and value types")
struct IdentifierTests {
    @Test("A generated identifier round-trips through its rawValue")
    func roundTrips() {
        let id = AthleteId()
        #expect(AthleteId(rawValue: id.rawValue) == id)
    }

    @Test("LocalDate parses and formats as YYYY-MM-DD")
    func localDateISOFormat() {
        let date = LocalDate(year: 2026, month: 3, day: 5)
        #expect(date.isoString == "2026-03-05")
        #expect(LocalDate(isoString: "2026-03-05") == date)
    }
}

@Suite("Planning domain model (v1.3)")
struct PlanningDomainModelTests {

    @Test("WeekPlan starts at revision 1 in draft status")
    func weekPlanDefaults() {
        let plan = WeekPlan(athleteId: AthleteId(), weekStart: LocalDate(year: 2026, month: 3, day: 2))
        #expect(plan.revision == 1)
        #expect(plan.status == .draft)
    }

    @Test("PlannedActivity may omit sport, duration and intensity")
    func plannedActivityOptionalFields() {
        let activity = PlannedActivity(
            weekPlanId: WeekPlanId(),
            athleteId: AthleteId(),
            activityType: .individualTraining,
            title: "Strength session",
            localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        #expect(activity.sportId == nil)
        #expect(activity.plannedDurationMinutes == nil)
    }

    @Test("PlanningDecision requires resultingRevision exactly when accepted")
    func planningDecisionAcceptedInvariant() {
        let decision = PlanningDecision(
            weekPlanId: WeekPlanId(),
            baseRevision: 1,
            resultingRevision: 2,
            authorId: ActorId(),
            decisionType: .commitWeek,
            accepted: true
        )
        #expect(decision.resultingRevision == 2)
    }
}

@Suite("Training domain model (v1.3)")
struct TrainingDomainModelTests {

    @Test("LoggedActivity carries a traceability-only planned activity ID")
    func loggedActivityTraceability() {
        let plannedId = PlannedActivityId()
        let logged = LoggedActivity(
            athleteId: AthleteId(),
            plannedActivityId: plannedId,
            activityType: .match,
            title: "Saturday match",
            startedAt: .now,
            durationMinutes: 90,
            status: .completed,
            perceivedExertion: 8,
            source: "planned"
        )
        #expect(logged.plannedActivityId == plannedId.rawValue)
    }
}

@Suite("AthleteProfile revision (v1.4)")
struct AthleteProfileRevisionTests {

    @Test("A new AthleteProfile starts at revision 1")
    func initialRevisionIsOne() {
        let profile = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .sharedOwnership
        )
        #expect(profile.revision == 1)
    }

    @Test("A successful mutation increments revision by exactly 1 and the event carries the resulting revision")
    func successfulMutationIncrementsRevision() throws {
        let profile = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .sharedOwnership
        )
        let event = try profile.applyMutation(expectedRevision: 1, changedFields: ["preferredName"]) {
            $0.preferredName = "Jonte"
        }
        #expect(profile.revision == 2)
        #expect(event.revision == 2)
        #expect(profile.preferredName == "Jonte")
    }

    @Test("Two sequential successful mutations each increment by exactly 1")
    func sequentialMutationsIncrementOneAtATime() throws {
        let profile = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .sharedOwnership
        )
        try profile.applyMutation(expectedRevision: 1, changedFields: ["preferredName"]) { $0.preferredName = "Jonte" }
        try profile.applyMutation(expectedRevision: 2, changedFields: ["developmentStage"]) { $0.developmentStage = .guidedIndependence }
        #expect(profile.revision == 3)
    }

    @Test("A stale expectedRevision is rejected as a conflict, and the profile is left unchanged")
    func staleWriteIsRejected() {
        let profile = AthleteProfile(
            workspaceId: WorkspaceId(),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .sharedOwnership
        )
        // Simulate another device/guardian committing first.
        try? profile.applyMutation(expectedRevision: 1, changedFields: ["preferredName"]) { $0.preferredName = "Jonte" }
        #expect(profile.revision == 2)

        // This caller is still working off revision 1 — stale.
        #expect(throws: AthleteProfileConflictError.staleRevision(expected: 1, actual: 2)) {
            try profile.applyMutation(expectedRevision: 1, changedFields: ["givenName"]) { $0.givenName = "Should not apply" }
        }
        // Rejected mutation must not have been applied.
        #expect(profile.givenName == "Jonas")
        #expect(profile.revision == 2)
    }
}


struct ReflectionDomainModelTests {

    @Test("ActivityReflection requires at least one numeric or text response")
    func reflectionRequiresContent() {
        let reflection = ActivityReflection(
            athleteId: AthleteId(),
            loggedActivityId: LoggedActivityId(),
            authorId: ActorId(),
            visibility: .sharedWithGuardians,
            energy: 4
        )
        #expect(reflection.energy == 4)
    }

    @Test("ParentObservation cannot be privateToAthlete")
    func parentObservationVisibilityConstraint() {
        let observation = ParentObservation(
            athleteId: AthleteId(),
            authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 3, day: 3),
            text: "Looked tired after the match",
            visibility: .summaryOnly
        )
        #expect(observation.visibility == .summaryOnly)
    }
}
