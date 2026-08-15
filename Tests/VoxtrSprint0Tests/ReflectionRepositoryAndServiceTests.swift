import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("ReflectionRepository and ReflectionService (S4.0)", .serialized)
struct ReflectionRepositoryAndServiceTests {

    @Test("Recording an ActivityReflection persists it, linked to a LoggedActivity by typed ID")
    @MainActor
    func recordActivityReflectionPersistsWithLink() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let loggedActivityId = LoggedActivityId()

        let reflection = try service.recordActivityReflection(
            athleteId: athleteId,
            loggedActivityId: loggedActivityId,
            authorId: ActorId(),
            visibility: .privateToAthlete,
            satisfaction: 4
        )

        #expect(reflection.loggedActivityId == loggedActivityId.rawValue)
        #expect(reflection.visibility == .privateToAthlete)
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReflection>()).count == 1)
    }

    @Test("Recording a ParentObservation persists it, optionally linked to a LoggedActivity")
    @MainActor
    func recordParentObservationPersistsWithOptionalLink() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let loggedActivityId = LoggedActivityId()

        let observation = try service.recordParentObservation(
            athleteId: athleteId,
            authorId: ActorId(),
            relatedLoggedActivityId: loggedActivityId,
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            text: "Looked strong today."
        )

        #expect(observation.relatedLoggedActivityId == loggedActivityId.rawValue)
        #expect(observation.visibility == .sharedWithGuardians)
        #expect(try container.mainContext.fetch(FetchDescriptor<ParentObservation>()).count == 1)
    }

    @Test("Recording a ParentObservation without a LoggedActivity link is allowed")
    @MainActor
    func recordParentObservationWithoutLinkIsAllowed() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)

        let observation = try service.recordParentObservation(
            athleteId: AthleteId(),
            authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 6),
            text: "General note."
        )

        #expect(observation.relatedLoggedActivityId == nil)
    }

    @Test("Fetching reflections by athlete returns only that athlete's reflections, ordered deterministically")
    @MainActor
    func fetchReflectionsByAthleteScopesAndOrders() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let firstAthlete = AthleteId()
        let secondAthlete = AthleteId()

        _ = try service.recordActivityReflection(
            athleteId: firstAthlete, loggedActivityId: LoggedActivityId(), authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 3
        )
        _ = try service.recordActivityReflection(
            athleteId: secondAthlete, loggedActivityId: LoggedActivityId(), authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 5
        )

        let first = try service.fetchActivityReflections(forAthlete: firstAthlete)
        let second = try service.fetchActivityReflections(forAthlete: firstAthlete)

        #expect(first.count == 1)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("Fetching reflections for one LoggedActivity returns only reflections linked to it")
    @MainActor
    func fetchReflectionsForOneLoggedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let firstLoggedActivity = LoggedActivityId()
        let secondLoggedActivity = LoggedActivityId()

        _ = try service.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: firstLoggedActivity, authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 3
        )
        _ = try service.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: secondLoggedActivity, authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 4
        )

        let results = try service.fetchActivityReflections(forLoggedActivity: firstLoggedActivity)

        #expect(results.count == 1)
        #expect(results.first?.loggedActivityId == firstLoggedActivity.rawValue)
    }

    @Test("Fetching parent observations by athlete returns only that athlete's observations, ordered deterministically by localDate")
    @MainActor
    func fetchParentObservationsByAthleteOrderedDeterministically() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()

        // Inserted out of chronological order deliberately.
        _ = try service.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 8), text: "Thursday"
        )
        _ = try service.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 5), text: "Monday"
        )
        _ = try service.recordParentObservation(
            athleteId: otherAthleteId, authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 6), text: "Other athlete"
        )

        let first = try service.fetchParentObservations(forAthlete: athleteId)
        let second = try service.fetchParentObservations(forAthlete: athleteId)

        #expect(first.map(\.text) == ["Monday", "Thursday"])
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("S4.1: recording an activity reflection succeeds for a not-yet-reflected-on LoggedActivity")
    @MainActor
    func recordActivityReflectionSucceedsWhenNoneExistsYet() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let loggedActivityId = LoggedActivityId()

        let reflection = try service.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: loggedActivityId, authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 4
        )

        #expect(reflection.athleteId == athleteId.rawValue)
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReflection>()).count == 1)
    }

    @Test("S4.1: fetching the reflection for one LoggedActivity returns it (singular convenience)")
    @MainActor
    func fetchSingularReflectionForLoggedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let loggedActivityId = LoggedActivityId()
        _ = try service.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: loggedActivityId, authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 4
        )

        let found = try service.fetchActivityReflection(forLoggedActivity: loggedActivityId)
        let notFound = try service.fetchActivityReflection(forLoggedActivity: LoggedActivityId())

        #expect(found != nil)
        #expect(found?.loggedActivityId == loggedActivityId.rawValue)
        #expect(notFound == nil)
    }

    @Test("S4.1: reflection history for one athlete does not include another athlete's reflections")
    @MainActor
    func athleteScopingExcludesOtherAthletes() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        _ = try service.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: LoggedActivityId(), authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 3
        )
        _ = try service.recordActivityReflection(
            athleteId: otherAthleteId, loggedActivityId: LoggedActivityId(), authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 5
        )

        let results = try service.fetchActivityReflections(forAthlete: athleteId)

        #expect(results.count == 1)
        #expect(results.allSatisfy { $0.athleteId == athleteId.rawValue })
    }

    @Test("S4.1: recording a second reflection for the same athlete and LoggedActivity is rejected")
    @MainActor
    func duplicateReflectionForSameAthleteAndLoggedActivityRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let loggedActivityId = LoggedActivityId()
        _ = try service.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: loggedActivityId, authorId: ActorId(),
            visibility: .privateToAthlete, satisfaction: 3
        )

        #expect(throws: ReflectionServiceError.activityReflectionAlreadyExists) {
            try service.recordActivityReflection(
                athleteId: athleteId, loggedActivityId: loggedActivityId, authorId: ActorId(),
                visibility: .privateToAthlete, satisfaction: 5
            )
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReflection>()).count == 1)
    }

    @Test("S4.1: existing entity invariants still hold — a text-only reflection is valid, and numeric fields stay within 1-5")
    @MainActor
    func existingEntityInvariantsStillHold() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)

        // v1.3 Section 10.1: at least one numeric OR text response is
        // required — a text-only reflection (no numeric fields at all)
        // must still be valid.
        let textOnly = try service.recordActivityReflection(
            athleteId: AthleteId(), loggedActivityId: LoggedActivityId(), authorId: ActorId(),
            visibility: .privateToAthlete, learningNote: "Pushed through the last interval."
        )
        #expect(textOnly.bodyFeeling == nil)
        #expect(textOnly.learningNote == "Pushed through the last interval.")

        // bodyFeeling/energy/satisfaction are documented as 1-5.
        let numeric = try service.recordActivityReflection(
            athleteId: AthleteId(), loggedActivityId: LoggedActivityId(), authorId: ActorId(),
            visibility: .privateToAthlete, bodyFeeling: 5, energy: 1, satisfaction: 3
        )
        #expect(numeric.bodyFeeling == 5)
        #expect(numeric.energy == 1)
    }

    @Test("VX-022: an out-of-range bodyFeeling is rejected through a controlled error, not a precondition crash")
    @MainActor
    func outOfRangeBodyFeelingRejectedViaControlledError() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)

        #expect(throws: ReflectionServiceError.invalidField("bodyFeeling/energy/satisfaction must be 1-5")) {
            try service.recordActivityReflection(
                athleteId: AthleteId(), loggedActivityId: LoggedActivityId(), authorId: ActorId(),
                visibility: .privateToAthlete, bodyFeeling: 99
            )
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityReflection>()).count == 0)
    }

    @Test("S4.2: creating a parent observation persists it")
    @MainActor
    func createParentObservationPersists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)

        let observation = try service.recordParentObservation(
            athleteId: AthleteId(), authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 6), text: "Great effort at practice."
        )

        #expect(observation.text == "Great effort at practice.")
        #expect(try container.mainContext.fetch(FetchDescriptor<ParentObservation>()).count == 1)
    }

    @Test("S4.2: the optional LoggedActivity link can be present or absent")
    @MainActor
    func optionalLoggedActivityLinkagePresentOrAbsent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let loggedActivityId = LoggedActivityId()

        let linked = try service.recordParentObservation(
            athleteId: AthleteId(), authorId: ActorId(), relatedLoggedActivityId: loggedActivityId,
            localDate: LocalDate(year: 2026, month: 1, day: 6), text: "About today's session."
        )
        let unlinked = try service.recordParentObservation(
            athleteId: AthleteId(), authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 6), text: "General note."
        )

        #expect(linked.relatedLoggedActivityId == loggedActivityId.rawValue)
        #expect(unlinked.relatedLoggedActivityId == nil)
    }

    @Test("S4.2: observations for one athlete never include another athlete's observations")
    @MainActor
    func athleteScopingForParentObservations() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        _ = try service.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 6), text: "For this athlete."
        )
        _ = try service.recordParentObservation(
            athleteId: otherAthleteId, authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 6), text: "For the other athlete."
        )

        let results = try service.fetchParentObservations(forAthlete: athleteId)

        #expect(results.count == 1)
        #expect(results.allSatisfy { $0.athleteId == athleteId.rawValue })
    }

    @Test("S4.2: fetching observations for one LoggedActivity returns only those linked to it, deterministically ordered, and multiple are allowed")
    @MainActor
    func fetchObservationsForOneLoggedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)
        let athleteId = AthleteId()
        let targetLoggedActivity = LoggedActivityId()
        let otherLoggedActivity = LoggedActivityId()

        // Two observations on the same LoggedActivity — allowed,
        // unlike ActivityReflection's one-per-pair rule.
        _ = try service.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(), relatedLoggedActivityId: targetLoggedActivity,
            localDate: LocalDate(year: 2026, month: 1, day: 8), text: "Second note"
        )
        _ = try service.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(), relatedLoggedActivityId: targetLoggedActivity,
            localDate: LocalDate(year: 2026, month: 1, day: 5), text: "First note"
        )
        _ = try service.recordParentObservation(
            athleteId: athleteId, authorId: ActorId(), relatedLoggedActivityId: otherLoggedActivity,
            localDate: LocalDate(year: 2026, month: 1, day: 6), text: "Unrelated"
        )

        let first = try service.fetchParentObservations(forLoggedActivity: targetLoggedActivity)
        let second = try service.fetchParentObservations(forLoggedActivity: targetLoggedActivity)

        #expect(first.map(\.text) == ["First note", "Second note"])
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("S4.2: existing entity invariants still hold — visibility can never be privateToAthlete for a parent-authored note")
    @MainActor
    func parentObservationVisibilityInvariantStillHolds() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let repository = ReflectionRepository(modelContext: container.mainContext)
        let service = ReflectionService(repository: repository)

        // Confirms the default stays .sharedWithGuardians (never
        // .privateToAthlete) — the entity's own precondition already
        // forbids .privateToAthlete outright; this exercises the
        // legitimate default rather than attempting to trigger that
        // (uncatchable) precondition.
        let observation = try service.recordParentObservation(
            athleteId: AthleteId(), authorId: ActorId(),
            localDate: LocalDate(year: 2026, month: 1, day: 6), text: "Default visibility check."
        )

        #expect(observation.visibility == .sharedWithGuardians)
        #expect(observation.visibility != .privateToAthlete)
    }
}
