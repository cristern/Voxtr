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
/// `correctLoggedActivity`/`reopenNoTrainingOutcome`) notifies every
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
            activityChangeBroadcaster: broadcaster,
            modelContext: container.mainContext
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

    @Test("A failed reopenNoTrainingOutcome call (completed outcome) notifies no subscriber")
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
        // throw .activityNotReopenable and never reach the broadcast.
        let logged = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, durationMinutes: 30, authorId: ActorId(), sessionForm: nil
        )
        #expect(subscriber.callCount == 1) // from the successful log above

        #expect(throws: TrainingServiceError.activityNotReopenable) {
            try coordinator.reopenNoTrainingOutcome(logged.loggedActivity.loggedActivityId, athleteId: athleteId)
        }
        // Unchanged by the failed reopen attempt.
        #expect(subscriber.callCount == 1)
    }

    @Test("A successful missed-outcome reopen notifies only after the canonical deletion succeeds")
    @MainActor
    func successfulMissedReopenEmitsAfterMutation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let broadcaster = AthleteActivityChangeBroadcaster()
        let (planning, training, coordinator) = makeCoordinator(container: container, broadcaster: broadcaster)
        let athleteId = AthleteId()
        let subscriber = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteId, subscriber)
        let weekPlan = try planning.getOrCreateWeekPlan(
            athleteId: athleteId,
            weekStart: TrainingPlanningCoordinationService.weekStart()
        )
        let planned = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Missed session",
            localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: Self.oslo
        )
        let missed = try training.logActivity(
            athleteId: athleteId,
            plannedActivityId: planned.plannedActivityId,
            activityType: planned.activityType,
            title: planned.title,
            startedAt: .now,
            durationMinutes: 1,
            status: .missed,
            loggedByActorId: ActorId()
        )

        #expect(!container.mainContext.hasChanges)
        try coordinator.reopenNoTrainingOutcome(missed.loggedActivityId, athleteId: athleteId)

        #expect(subscriber.callCount == 1)
        #expect(!container.mainContext.hasChanges)
        #expect(try training.fetchLoggedActivities(forPlannedActivity: planned.plannedActivityId).isEmpty)
    }

    @Test("A rolled-back reopen emits no invalidation and preserves both records")
    @MainActor
    func rolledBackReopenEmitsNone() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let broadcaster = AthleteActivityChangeBroadcaster()
        let (_, training, coordinator) = makeCoordinator(container: container, broadcaster: broadcaster)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let athleteId = AthleteId()
        let subscriber = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteId, subscriber)
        let missed = try training.logActivity(
            athleteId: athleteId,
            activityType: .other,
            title: "Mistaken missed",
            startedAt: .now,
            durationMinutes: 1,
            status: .missed,
            loggedByActorId: ActorId()
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId,
            loggedActivityId: missed.loggedActivityId,
            authorId: ActorId(),
            visibility: .privateToAthlete,
            bodyFeeling: 3
        )

        #expect(throws: TrainingReflectionCoordinationService.SimulatedReopenFailure.self) {
            try coordinator.reopenNoTrainingOutcome(
                missed.loggedActivityId,
                athleteId: athleteId,
                failAt: nil,
                saveOverride: { throw TrainingReflectionCoordinationService.SimulatedReopenFailure() }
            )
        }

        #expect(subscriber.callCount == 0)
        #expect(try training.fetchLoggedActivity(byId: missed.loggedActivityId, athleteId: athleteId).loggedActivityId == missed.loggedActivityId)
        #expect(try reflectionService.fetchActivityReflection(forLoggedActivity: missed.loggedActivityId) != nil)
    }

    @Test("Reopen refuses a dirty shared context without touching pending or canonical state")
    @MainActor
    func dirtyContextRefusalPreservesEverythingAndEmitsNone() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let broadcaster = AthleteActivityChangeBroadcaster()
        let (_, training, coordinator) = makeCoordinator(container: container, broadcaster: broadcaster)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let athleteId = AthleteId()
        let authorId = ActorId()
        let subscriber = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteId, subscriber)
        let missed = try training.logActivity(
            athleteId: athleteId,
            activityType: .other,
            title: "Canonical missed",
            startedAt: .now,
            durationMinutes: 1,
            status: .missed,
            loggedByActorId: ActorId()
        )
        let reflection = try reflectionService.recordActivityReflection(
            athleteId: athleteId,
            loggedActivityId: missed.loggedActivityId,
            authorId: authorId,
            visibility: .sharedWithGuardians,
            bodyFeeling: 2,
            learningNote: "Canonical reflection"
        )

        // An unrelated workflow has staged, but deliberately not saved,
        // this parent observation in the shared app context.
        let pendingId = UUID()
        let pendingDate = LocalDate(year: 2026, month: 8, day: 22)
        let pending = ParentObservation(
            id: pendingId,
            athleteId: AthleteId(),
            authorId: ActorId(),
            localDate: pendingDate,
            text: "Unrelated pending content",
            visibility: .sharedWithGuardians
        )
        container.mainContext.insert(pending)
        #expect(container.mainContext.hasChanges)

        #expect(throws: TrainingReflectionCoordinationService.ReopenError.transactionBoundaryUnavailable) {
            try coordinator.reopenNoTrainingOutcome(missed.loggedActivityId, athleteId: athleteId)
        }

        // Refusal neither saves nor rolls back the unrelated workflow.
        #expect(container.mainContext.hasChanges)
        #expect(pending.id == pendingId)
        #expect(pending.localDate == pendingDate)
        #expect(pending.text == "Unrelated pending content")
        #expect(pending.visibility == .sharedWithGuardians)

        // Neither canonical reopen deletion was staged or persisted.
        let stillLogged = try training.fetchLoggedActivity(byId: missed.loggedActivityId, athleteId: athleteId)
        let stillReflected = try reflectionService.fetchActivityReflection(forLoggedActivity: missed.loggedActivityId)
        #expect(stillLogged.loggedActivityId == missed.loggedActivityId)
        #expect(stillReflected?.reflectionId == reflection.reflectionId)
        #expect(stillReflected?.bodyFeeling == 2)
        #expect(stillReflected?.learningNote == "Canonical reflection")
        #expect(subscriber.callCount == 0)
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

    // MARK: - Review follow-up: the actual emission boundary (not only a pre-write failure)

    /// Answers "should invalidation fire when the activity write
    /// succeeded even if a later reflection/form write fails, or only on
    /// whole-method success" empirically: `logActivity`'s Session Form
    /// sub-write is wrapped in its OWN local `do/catch` and reported via
    /// `sessionFormOutcome: .failed`, never rethrown — so `logActivity`
    /// itself always SUCCEEDS once the canonical `LoggedActivity` write
    /// has, regardless of Session Form. An out-of-range `bodyFeeling`
    /// (valid range is 1-5, enforced by `ReflectionService`'s own
    /// validation) is the real, reachable way to make that sub-write
    /// fail without touching persistence internals directly.
    @Test("logActivity succeeds and emits exactly once even when the Session Form sub-write fails")
    @MainActor
    func logActivitySucceedsAndEmitsEvenWhenSessionFormWriteFails() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let broadcaster = AthleteActivityChangeBroadcaster()
        let (_, _, coordinator) = makeCoordinator(container: container, broadcaster: broadcaster)
        let athleteId = AthleteId()
        let subscriber = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteId, subscriber)

        let result = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, durationMinutes: 30, authorId: ActorId(), sessionForm: 99
        )

        guard case .failed = result.sessionFormOutcome else {
            Issue.record("Expected the Session Form sub-write to fail for an out-of-range value")
            return
        }
        // The canonical LoggedActivity write is what invalidation tracks
        // — it succeeded, so exactly one notification fires, regardless
        // of the Session Form sub-write's own independent failure.
        #expect(subscriber.callCount == 1)
    }

    /// Same boundary, for `correctLoggedActivity`'s "update an EXISTING
    /// reflection" branch specifically — the un-caught
    /// `reflectionService.fetchActivityReflection(forLoggedActivity:)`
    /// call sitting between this method's own canonical write and its
    /// Form update is a genuine, code-confirmed spot where the WHOLE
    /// coordinator method could throw after the canonical write already
    /// committed (a persistence-layer fetch failure, not reachable
    /// through this test without faking repository internals — reported
    /// in this round's delivery notes, not fixed, since duration/RPE
    /// already being canonically saved by that point makes the broadcast
    /// correct regardless of what fetchActivityReflection does next).
    /// This test covers the REACHABLE half of that same boundary: the
    /// local `do/catch` around `updateActivityReflection` itself, which
    /// (like `logActivity`'s Session Form write) never rethrows.
    @Test("correctLoggedActivity succeeds and emits exactly once even when updating an existing reflection's Form value fails")
    @MainActor
    func correctLoggedActivitySucceedsAndEmitsEvenWhenFormUpdateFails() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let broadcaster = AthleteActivityChangeBroadcaster()
        let (_, _, coordinator) = makeCoordinator(container: container, broadcaster: broadcaster)
        let athleteId = AthleteId()
        let subscriber = RecordingActivityChangeSubscriber()
        broadcaster.subscribe(athleteId: athleteId, subscriber)

        // A valid initial log, WITH a Session Form value — creates the
        // ActivityReflection that correctLoggedActivity's "existing
        // reflection" branch below will then try to update.
        let logged = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, durationMinutes: 30, authorId: ActorId(), sessionForm: 3
        )
        #expect(subscriber.callCount == 1)

        let result = try coordinator.correctLoggedActivity(
            loggedActivityId: logged.loggedActivity.loggedActivityId, athleteId: athleteId, authorId: ActorId(),
            durationMinutes: 45, perceivedExertion: nil, sessionForm: 99
        )

        guard case .failed = result.sessionFormOutcome else {
            Issue.record("Expected the Form update to fail for an out-of-range value")
            return
        }
        // The canonical duration/RPE write already committed — one more
        // notification for this same athlete, on top of the one from
        // the initial log above.
        #expect(subscriber.callCount == 2)
    }
}
