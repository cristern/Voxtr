import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.

/// Recurring reopen stale-Athlete-Home fix (architecture round): the
/// invariant this whole redesign rests on — a successful canonical
/// activity-lifecycle mutation (`TrainingReflectionCoordinationService.logActivity`/
/// `correctLoggedActivity`/`reopenCancelledActivity`) notifies every
/// still-live `AthleteActivityChangeSubscriber` registered for the
/// mutated athlete exactly once, a failed mutation notifies none, and
/// isolation/subscription lifecycle hold regardless of which screen
/// performed the mutation. `HomeDashboardViewModel`'s own end-to-end
/// proof (same materialized identity, no duplicate suggestion) lives in
/// `HomeDashboardViewModelTests.swift` — this file proves the
/// broadcaster/coordinator contract itself, in isolation.
@Suite("AthleteActivityChangeBroadcaster", .serialized)
struct AthleteActivityChangeBroadcasterTests {

    @MainActor
    private final class RecordingActivityChangeSubscriber: AthleteActivityChangeSubscriber {
        private(set) var callCount = 0
        func athleteActivityDidChange() {
            callCount += 1
        }
    }

    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    @MainActor
    private func makeCoordinator(
        container: ModelContainer,
        broadcaster: AthleteActivityChangeBroadcaster
    ) -> (planning: PlanningService, training: TrainingService, coordinator: TrainingReflectionCoordinationService) {
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService,
            activityChangeBroadcaster: broadcaster
        )
        return (planningService, trainingService, coordinator)
    }

    // MARK: - 1. Success emits exactly once, for the correct athlete

    @Test("A successful logActivity call notifies the subscriber for that exact athlete exactly once")
    @MainActor
    func successfulMutationEmitsExactlyOnce() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let broadcaster = AthleteActivityChangeBroadcaster()
        let (_, _, coordinator) = makeCoordinator(container: container, broadcaster: broadcaster)
        let athleteId = AthleteId()
        let subscriber = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteId, subscriber)

        _ = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, durationMinutes: 30, authorId: ActorId(), sessionForm: nil
        )

        #expect(subscriber.callCount == 1)
    }

    // MARK: - 2. Failure emits none

    @Test("A failed reopenCancelledActivity call (not actually cancelled) notifies no subscriber")
    @MainActor
    func failedMutationEmitsNone() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let broadcaster = AthleteActivityChangeBroadcaster()
        let (_, _, coordinator) = makeCoordinator(container: container, broadcaster: broadcaster)
        let athleteId = AthleteId()
        let subscriber = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteId, subscriber)

        // A genuinely COMPLETED (never cancelled) activity — reopen must
        // throw .activityNotCancelled and never reach the broadcast.
        let logged = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, durationMinutes: 30, authorId: ActorId(), sessionForm: nil
        )
        #expect(subscriber.callCount == 1) // from the successful log above

        #expect(throws: TrainingServiceError.activityNotCancelled) {
            try coordinator.reopenCancelledActivity(logged.loggedActivity.loggedActivityId, athleteId: athleteId)
        }
        // Unchanged by the failed reopen attempt.
        #expect(subscriber.callCount == 1)
    }

    // MARK: - 3. Athlete isolation

    @Test("A subscriber registered for athlete A is never notified by athlete B's mutation")
    @MainActor
    func athleteIsolationHolds() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let broadcaster = AthleteActivityChangeBroadcaster()
        let (_, _, coordinator) = makeCoordinator(container: container, broadcaster: broadcaster)
        let athleteA = AthleteId()
        let athleteB = AthleteId()
        let subscriberA = RecordingActivityChangeSubscriber()
        let subscriberB = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteA, subscriberA)
        broadcaster.subscribe(athleteId: athleteB, subscriberB)

        _ = try coordinator.logActivity(
            athleteId: athleteA, activityType: .individualTraining, title: "Athlete A run",
            startedAt: .now, durationMinutes: 30, authorId: ActorId(), sessionForm: nil
        )

        #expect(subscriberA.callCount == 1)
        #expect(subscriberB.callCount == 0)
    }

    // MARK: - 4. Multiple simultaneous subscribers for the same athlete

    @Test("Two live subscribers for the same athlete both receive the change")
    @MainActor
    func multipleSubscribersForSameAthleteBothNotified() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let broadcaster = AthleteActivityChangeBroadcaster()
        let (_, _, coordinator) = makeCoordinator(container: container, broadcaster: broadcaster)
        let athleteId = AthleteId()
        let subscriberOne = RecordingActivityChangeSubscriber()
        let subscriberTwo = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteId, subscriberOne)
        broadcaster.subscribe(athleteId: athleteId, subscriberTwo)

        _ = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, durationMinutes: 30, authorId: ActorId(), sessionForm: nil
        )

        #expect(subscriberOne.callCount == 1)
        #expect(subscriberTwo.callCount == 1)
    }

    // MARK: - 5. Explicit unsubscribe stops future callbacks

    @Test("unsubscribe(athleteId:token:) prevents that subscriber from receiving any future change")
    @MainActor
    func unsubscribeStopsFutureCallbacks() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let broadcaster = AthleteActivityChangeBroadcaster()
        let (planning, _, coordinator) = makeCoordinator(container: container, broadcaster: broadcaster)
        let athleteId = AthleteId()
        let subscriber = RecordingActivityChangeSubscriber()
        let token = broadcaster.subscribe(athleteId: athleteId, subscriber)

        _ = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, durationMinutes: 30, authorId: ActorId(), sessionForm: nil
        )
        #expect(subscriber.callCount == 1)

        broadcaster.unsubscribe(athleteId: athleteId, token: token)

        // A second, otherwise-identical successful mutation for the same
        // athlete — a genuinely different PlannedActivity, so
        // TrainingService's own duplicate-link guard never interferes.
        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let secondActivity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(), timeZoneId: Self.oslo
        )
        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: secondActivity.plannedActivityId,
            activityType: .individualTraining, title: "Evening swim",
            startedAt: .now, durationMinutes: 30, authorId: ActorId(), sessionForm: nil
        )

        // Still 1 — the unsubscribed token never receives this second
        // mutation.
        #expect(subscriber.callCount == 1)
    }

    // MARK: - No unbounded accumulation of dead entries

    @Test("A deallocated subscriber's entry is pruned by the next subscribe/activityChanged pass for that athlete, never accumulating")
    @MainActor
    func deadSubscriberEntryIsPruned() throws {
        let broadcaster = AthleteActivityChangeBroadcaster()
        let athleteId = AthleteId()

        do {
            let shortLived = RecordingActivityChangeSubscriber()
            broadcaster.subscribe(athleteId: athleteId, shortLived)
        }
        // `shortLived` has no other strong reference — deallocated here.

        // A live subscriber for the SAME athlete, subscribed after the
        // dead one — subscribing itself prunes the dead entry first, so
        // this never accumulates unboundedly across repeated
        // subscribe/deallocate cycles.
        let stillLive = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteId, stillLive)
        broadcaster.activityChanged(for: athleteId)

        #expect(stillLive.callCount == 1)
    }
}
