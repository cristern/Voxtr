import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrNotificationsDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.

/// Notifications V1 Activity Reminder UI slice: a trivial no-op
/// `ActivityReminderScheduling` conformance so `ActivityDetailViewModel`
/// tests in this file (which do not exercise reminder behavior) can
/// construct the now-required `NotificationsPlanningCoordinationService`
/// dependency without touching `UNUserNotificationCenter`.
private struct NoOpActivityReminderScheduler: ActivityReminderScheduling {
    func scheduleReminder(id: ActivityReminderId, fireDate: Date, content: ActivityReminderContent) {}
    func cancelReminder(id: ActivityReminderId) {}
    func authorizationStatus(completion: @escaping @MainActor @Sendable (ActivityReminderAuthorizationStatus) -> Void) {
        MainActor.assumeIsolated { completion(.authorized) }
    }
    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        MainActor.assumeIsolated { completion(true) }
    }
}

@Suite("Sprint 1 Core Flow Completion", .serialized)
struct Sprint1CoreFlowCompletionTests {

    /// Item 7: with three athletes, resolving by explicit AthleteId
    /// never silently returns athlete #1 — the actual regression this
    /// whole package is guarding against.
    @Test("With three athletes, navigation identity resolves the correct athlete — never silently falls back to athlete #1")
    @MainActor
    func threeAthletesNeverResolveToFirst() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let workspaceId = WorkspaceId()

        let oliver = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let athleteTwo = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "AthleteTwo",
            birthDate: LocalDate(year: 2013, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let athleteThree = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "AthleteThree",
            birthDate: LocalDate(year: 2014, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        let fetched = try athleteRepository.fetchAthletes(forWorkspace: workspaceId)

        // Resolving athlete #2 and #3 by their own explicit AthleteId
        // (the same pattern FamilyHomeDestination.athlete(_:) resolution
        // uses) must return exactly that athlete, never athlete #1.
        let resolvedTwo = fetched.first(where: { $0.athleteId == athleteTwo.athleteId })
        let resolvedThree = fetched.first(where: { $0.athleteId == athleteThree.athleteId })
        #expect(resolvedTwo?.givenName == "AthleteTwo")
        #expect(resolvedThree?.givenName == "AthleteThree")
        #expect(resolvedTwo?.athleteId != oliver.athleteId)
        #expect(resolvedThree?.athleteId != oliver.athleteId)
    }

    /// Item 7: a planned activity opened via ActivityDetailViewModel
    /// carries its own PlannedActivity/athlete identity — resolving
    /// "the wrong activity" or "the wrong athlete" would be exactly the
    /// failure mode Items 3/6 fix.
    @Test("Planned activity destination identity — ActivityDetailViewModel is built for the exact activity and athlete it represents")
    @MainActor
    func plannedActivityDestinationPreservesIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Football", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Nadderud Stadion"
        )

        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )

        #expect(viewModel.activity.plannedActivityId == activity.plannedActivityId)
        #expect(viewModel.activity.title == "Football")
        #expect(viewModel.activity.location == "Nadderud Stadion")
    }

    // MARK: - Post-mutation navigation and stale-state consistency audit (Issue A)

    /// TestFlight closeout (blank-screen-after-Save fix): a successful
    /// log through `ActivityDetailViewModel.makeLogActivityViewModel()`
    /// must fire the explicit `onActivityLogged` signal the screen that
    /// pushed Activity Detail relies on to reload its own authoritative
    /// data — but must NEVER request that `ActivityDetailView` itself
    /// dismiss. Logging is an in-context correction/update flow: the
    /// user stays on the same Activity Detail screen, which now reflects
    /// the newly logged outcome and recorded data (`loggedActivity`/
    /// `activityReflection`, refreshed here via the SAME canonical
    /// `loggedActivityDetail(forPlannedActivity:)` read
    /// `ActivityDetailViewLoader` uses to build this state initially —
    /// never a caller-supplied snapshot, never inferred). Exercised at
    /// the ViewModel/contract level (not via real SwiftUI navigation,
    /// which is not something Swift Testing can drive) — the SwiftUI
    /// wiring at each of the 5 `ActivityDetailViewLoader` call sites is
    /// what actually connects `onActivityLogged` to each source screen's
    /// own `load`/`refresh` method; `makeLogActivityViewModel()` no
    /// longer accepts (or needs) an `onDismiss` closure at all.
    @Test("A successful log fires onActivityLogged, never requests a parent dismiss, and Activity Detail reflects the canonical logged outcome")
    @MainActor
    func successfulLogFiresOnActivityLoggedAndReflectsCanonicalState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        var reloadCallCount = 0
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            ),
            onActivityLogged: { reloadCallCount += 1 }
        )
        #expect(viewModel.loggedActivity == nil)

        // `makeLogActivityViewModel()` takes no `onDismiss` parameter —
        // there is nothing left for a caller to wire up to a dismiss.
        let logViewModel = viewModel.makeLogActivityViewModel()
        // Planned/Logged Activity lifecycle consistency cleanup: actual
        // duration is required for a completed log; `activity` itself
        // has no planned duration, so it must be entered explicitly.
        logViewModel.durationMinutes = 45
        logViewModel.perceivedExertion = 7
        logViewModel.sessionForm = 3

        #expect(logViewModel.save())
        #expect(reloadCallCount == 1)
        #expect(viewModel.isCompleted == true)
        #expect(viewModel.errorMessage == nil)

        // Activity Detail reflects the exact canonical record just
        // created — not a locally-fabricated stand-in.
        let loggedActivity = try #require(viewModel.loggedActivity)
        #expect(loggedActivity.status == .completed)
        #expect(loggedActivity.durationMinutes == 45)
        #expect(viewModel.perceivedExertion == 7)
        #expect(viewModel.formValue == 3)
    }

    /// A failed log (Form required but missing) must neither flip
    /// `isCompleted` nor mutate `loggedActivity`/`activityReflection`,
    /// nor fire `onActivityLogged` — the same "no false refresh/
    /// navigation on failure" contract as before, now also covering the
    /// canonical-state refresh this round adds. The error itself stays
    /// on `logViewModel.errorMessage` (rendered locally inside
    /// `LogActivityView`'s own "How did it go?" section) — it never
    /// leaks onto `ActivityDetailViewModel.errorMessage`, the separate
    /// top-of-screen error this screen's own mutations use.
    @Test("A failed log fires neither onActivityLogged nor a canonical-state refresh, and keeps the error local to Log Activity")
    @MainActor
    func failedLogFiresNeitherOnActivityLoggedNorStateRefresh() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        var reloadCallCount = 0
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            ),
            onActivityLogged: { reloadCallCount += 1 }
        )

        let logViewModel = viewModel.makeLogActivityViewModel()
        // sessionForm left nil — Form is required for a completed log.

        #expect(logViewModel.save() == false)
        #expect(logViewModel.errorMessage != nil)
        #expect(reloadCallCount == 0)
        #expect(viewModel.isCompleted == false)
        #expect(viewModel.loggedActivity == nil)
        #expect(viewModel.errorMessage == nil)
    }

    /// Review follow-up (blank-screen-after-Save closeout, round 2): the
    /// exact gap the review found — `LogActivityViewModel.save()`'s
    /// RETRY branch (reached whenever `loggedActivityId` is already set,
    /// i.e. a prior `save()` call already logged the base activity)
    /// never fired `onLogged()` on a successful retry, so the sheet
    /// could close on a genuinely successful Save while the mounted
    /// `ActivityDetailViewModel` still showed the stale snapshot from
    /// the FIRST call.
    ///
    /// Round 3 review follow-up: the PRIOR version of this test reached
    /// the retry branch via an invalid domain combination (logging as
    /// Missed, then entering a Form value and saving again) — Missed
    /// means no training occurred, so Form must never be recorded
    /// against it, and that combination must never be encoded as valid
    /// test behavior even to reach an otherwise-legitimate code path.
    /// This version reaches the SAME retry branch through a genuinely
    /// valid scenario instead: a normal COMPLETED log with a valid Form
    /// value succeeds outright on the first `save()` call (Form already
    /// `.saved`, nothing pending), then `save()` is called a SECOND time
    /// on the same `logViewModel` — e.g. a duplicate tap of Save — which
    /// is exactly what routes through the retry branch once
    /// `loggedActivityId` is already set. Proves the fix: a retry-branch
    /// pass, even one with nothing left to retry, still refreshes
    /// Activity Detail's canonical state via `onLogged()`, and — the
    /// retry branch's own core guarantee, unchanged by this fix — never
    /// creates a duplicate `LoggedActivity`.
    @Test("A retry save() call after an already-persisted completed log refreshes Activity Detail's canonical state and never duplicates the LoggedActivity")
    @MainActor
    func retrySaveAfterPersistedLogRefreshesCanonicalStateWithoutDuplicating() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        var reloadCallCount = 0
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            ),
            onActivityLogged: { reloadCallCount += 1 }
        )

        let logViewModel = viewModel.makeLogActivityViewModel()
        // First attempt: a normal Completed log with a valid Form —
        // succeeds outright, Form already saved, nothing pending.
        logViewModel.durationMinutes = 45
        logViewModel.sessionForm = 3
        #expect(logViewModel.save())
        #expect(logViewModel.sessionFormPendingRetry == false)
        #expect(reloadCallCount == 1)
        #expect(viewModel.formValue == 3)

        // Second attempt: the SAME logViewModel, called again — this is
        // the exact RETRY branch the fix touches, even though there is
        // nothing left for it to actually retry.
        #expect(logViewModel.save())

        // No duplicate LoggedActivity from either call.
        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)

        // The retry pass still refreshed Activity Detail's canonical
        // state — not skipped just because nothing needed retrying.
        #expect(reloadCallCount == 2)
        #expect(viewModel.formValue == 3)
        #expect(viewModel.loggedActivity?.status == .completed)

        // `makeLogActivityViewModel()` accepts no dismiss closure of any
        // kind (see the successful/failed-log tests above) — there is
        // structurally nothing here that could request a parent
        // dismiss, on the initial log or on this retry.
    }

    /// Round 3 review follow-up, Blocker 2: even after round 2's fix,
    /// `LogActivityViewModel.save()` still returned `true` unconditionally
    /// once persistence succeeded, regardless of whether the MOUNTED
    /// `ActivityDetailViewModel`'s own canonical refresh succeeded — so
    /// the sheet could still dismiss while Activity Detail stayed stale.
    /// `refreshMountedState` is the new, directly-injectable seam that
    /// closes this gap: constructed here on `LogActivityViewModel`
    /// itself (not via `ActivityDetailViewModel.makeLogActivityViewModel()`,
    /// which always wires a real, working refresh) so the refresh's
    /// success/failure can be controlled directly, without needing any
    /// domain-invalid or otherwise-unreachable-without-new-seams
    /// simulation — genuine coverage, not a disclosed workaround.
    @Test("A failed mounted-state refresh keeps save() reporting failure without a duplicate log; a subsequent successful refresh then reports success")
    @MainActor
    func failedMountedRefreshKeepsSaveFailingUntilRetrySucceeds() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        var onLoggedCallCount = 0
        var refreshShouldSucceed = false
        var refreshCallCount = 0
        let logViewModel = LogActivityViewModel(
            plannedActivity: activity,
            athleteId: athleteId,
            athleteDisplayName: "Oliver",
            authorId: ActorId(),
            trainingReflectionCoordinationService: coordinator,
            onLogged: { onLoggedCallCount += 1 },
            refreshMountedState: {
                refreshCallCount += 1
                return refreshShouldSucceed
            }
        )
        logViewModel.durationMinutes = 45
        logViewModel.sessionForm = 3

        // First attempt: persistence succeeds, but the mounted refresh
        // fails — save() must report failure, never a fabricated
        // success, and the sheet's caller must be able to tell.
        #expect(logViewModel.save() == false)
        #expect(logViewModel.errorMessage != nil)
        #expect(logViewModel.didLog)
        #expect(onLoggedCallCount == 1)
        #expect(refreshCallCount == 1)

        var links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)

        // Retry: the underlying log is NOT re-created (no duplicate),
        // only the refresh is re-attempted — now succeeding.
        refreshShouldSucceed = true
        #expect(logViewModel.save())
        #expect(onLoggedCallCount == 2)
        #expect(refreshCallCount == 2)

        links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)

        // Session Form itself was never touched by any of this — exactly
        // one reflection, matching the single underlying log.
        let reflectionCount = try reflectionService.fetchActivityReflections(
            forLoggedActivity: links[0].loggedActivityId
        ).count
        #expect(reflectionCount == 1)
    }

    /// Round 4 review follow-up: the exact regression the review
    /// caught — round 3's `finishSave` logic returned early on a Form
    /// failure, before `onLogged()`/`refreshMountedState()` ever ran.
    /// So a user who logged successfully, hit a Form failure, then
    /// chose Cancel instead of retrying, would leave the mounted
    /// Activity Detail (and the parent surface behind it) never told
    /// the activity was logged at all — a One Truth violation, since
    /// the canonical `LoggedActivity` genuinely exists.
    ///
    /// Reaching a genuine "Form remains pending/failed" state through
    /// `LogActivityViewModel`'s own public `save()` is not possible
    /// without either bypassing `TrainingValidator`'s required (1...5)
    /// gate (a Completed log's Form is always validated before
    /// `logActivity` is ever called, so it can never fail afterward with
    /// a valid input) or a domain-invalid Missed+Form combination
    /// (explicitly disallowed). This test instead uses
    /// `presetForFormRetryTesting` — a package-internal, test-only seam
    /// — to put the view model into the exact "already logged, Form
    /// retry pending" state a genuine failure leaves behind, backed by a
    /// REAL, already-persisted `LoggedActivity` (created directly
    /// through the coordinator, the same pattern several other tests in
    /// this file already use). The retry's own `recordSessionForm` call
    /// is real, unvalidated production code — the failure itself comes
    /// from a genuinely out-of-range value (99), the same technique
    /// already established elsewhere in this codebase for simulating a
    /// Session Form write failure — never a fabricated result.
    @Test("A retry with Form still unresolved still fires the canonical refresh signal and attempts the mounted refresh, keeps save() false without duplicating the LoggedActivity, and a later valid retry succeeds")
    @MainActor
    func formStillUnresolvedOnRetryStillRefreshesCanonicalStateWithoutDuplicating() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        // The base LoggedActivity genuinely persisted already — created
        // directly through the coordinator with no Form, mirroring the
        // state a real `save()` call reaches the instant `logActivity`
        // itself succeeds, before Form is ever attempted.
        let logged = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
            title: activity.title, startedAt: .now, durationMinutes: 45, status: .completed,
            authorId: ActorId(), sessionForm: nil
        )

        var onLoggedCallCount = 0
        var refreshCallCount = 0
        let logViewModel = LogActivityViewModel(
            plannedActivity: activity,
            athleteId: athleteId,
            athleteDisplayName: "Oliver",
            authorId: ActorId(),
            trainingReflectionCoordinationService: coordinator,
            onLogged: { onLoggedCallCount += 1 },
            refreshMountedState: { refreshCallCount += 1; return true }
        )
        // `sessionForm: 99` is out-of-range — genuinely fails
        // ReflectionService's own validation on the real
        // `recordSessionForm` call the retry branch makes, not a
        // fabricated result. `TrainingReflectionCoordinationService.logActivity`
        // returns `LoggedActivityWithSessionForm` — the `LoggedActivity`
        // itself, and its `loggedActivityId`, live under its own
        // `.loggedActivity` member, not directly on the result.
        logViewModel.presetForFormRetryTesting(loggedActivityId: logged.loggedActivity.loggedActivityId, sessionForm: 99)

        #expect(logViewModel.save() == false)
        #expect(logViewModel.errorMessage != nil)
        #expect(logViewModel.sessionFormPendingRetry)
        // The canonical refresh signal still fired, even though Form
        // remains unresolved — the exact fix this round makes.
        #expect(onLoggedCallCount == 1)
        #expect(refreshCallCount == 1)

        var links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(try reflectionService.fetchActivityReflections(forLoggedActivity: logged.loggedActivity.loggedActivityId).count == 0)

        // A later retry with a valid Form value succeeds, without ever
        // re-invoking logActivity.
        logViewModel.sessionForm = 3
        #expect(logViewModel.save())
        #expect(logViewModel.sessionFormPendingRetry == false)
        #expect(onLoggedCallCount == 2)
        #expect(refreshCallCount == 2)

        links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(try reflectionService.fetchActivityReflections(forLoggedActivity: logged.loggedActivity.loggedActivityId).count == 1)
    }

    // MARK: - Post-mutation consistency closeout: One Truth for Activity Detail completion

    /// The exact defect this closeout fixes: `ActivityDetailViewLoader`
    /// used to trust a caller-provided `isCompleted` snapshot outright,
    /// even after separately fetching the canonical `LoggedActivity`
    /// relationship for RPE/Form. `WeeklyPlanningView` passed a
    /// hardcoded `false` unconditionally — so opening Activity Detail
    /// for an activity ALREADY logged elsewhere would show it as
    /// "Ready to log" again. This test mirrors the loader's corrected
    /// derivation directly (`detail?.loggedActivity != nil`, the exact
    /// rule `TrainingPlanningCoordinationService.plannedActivitiesWithCompletion`
    /// already uses everywhere else — `!links.isEmpty` over the same
    /// `fetchLoggedActivities(forPlannedActivity:)` relationship): a
    /// stale/wrong caller flag of `false` must never suppress genuine
    /// canonical completion.
    @Test("Canonical fetched LoggedActivity determines completion — supersedes a stale caller-provided false (fixes Weekly Planning's hardcoded false)")
    @MainActor
    func canonicalLoggedActivityDeterminesCompletionDespiteStaleCallerFlag() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
            title: activity.title, startedAt: .now, perceivedExertion: 6, authorId: ActorId(), sessionForm: 4
        )

        // Mirrors ActivityDetailViewLoader.onAppear's own derivation
        // exactly — never a hardcoded/stale caller boolean.
        let detail = try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId)
        let derivedIsCompleted = detail?.loggedActivity != nil

        #expect(derivedIsCompleted == true)

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: derivedIsCompleted,
            loggedActivity: detail?.loggedActivity, activityReflection: detail?.reflection,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )

        #expect(viewModel.isCompleted == true)
        // RPE/Form loading is unaffected by this fix — still resolved
        // from the same canonical fetch, alongside completion.
        #expect(viewModel.perceivedExertion == 6)
        #expect(viewModel.formValue == 4)
        // Exact relationship preserved — not inferred from title/date.
        #expect(viewModel.activity.plannedActivityId == activity.plannedActivityId)
        #expect(detail?.loggedActivity.plannedActivityId == activity.plannedActivityId.rawValue)
    }

    /// The mirror case: a caller flag of `true` must never fabricate
    /// completion when no canonical `LoggedActivity` actually exists —
    /// "no title/date inference, no duplicate state authority" applies
    /// in both directions.
    @Test("No canonical LoggedActivity means Activity Detail never falsely claims completion, even if a caller flag said true")
    @MainActor
    func noCanonicalLoggedActivityMeansNotCompletedDespiteStaleCallerFlag() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        // Never logged — no LoggedActivity exists for this PlannedActivity.

        let detail = try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId)
        let derivedIsCompleted = detail?.loggedActivity != nil

        #expect(derivedIsCompleted == false)

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: derivedIsCompleted,
            loggedActivity: detail?.loggedActivity, activityReflection: detail?.reflection,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )

        #expect(viewModel.isCompleted == false)
        #expect(viewModel.perceivedExertion == nil)
        #expect(viewModel.formValue == nil)
    }

    // MARK: - VX-022 closeout: Activity Detail RPE / Form

    /// Builds an `ActivityDetailViewModel` the same way `ActivityDetailViewLoader`
    /// does — resolving `loggedActivity`/`activityReflection` externally
    /// via `TrainingReflectionCoordinationService.loggedActivityDetail(forPlannedActivity:)`
    /// before construction — for tests that need a fully-wired instance.
    @MainActor
    private static func makeCompletedActivityDetailViewModel(
        athleteId: AthleteId,
        container: ModelContainer,
        planningService: PlanningService,
        weekPlan: WeekPlan,
        coordinator: TrainingReflectionCoordinationService,
        perceivedExertion: Int?,
        sessionForm: Int?,
        sessionFormVisibility: VisibilityPolicy = .sharedWithGuardians
    ) throws -> ActivityDetailViewModel {
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
            title: "Morning run", startedAt: .now, perceivedExertion: perceivedExertion, authorId: ActorId(),
            sessionForm: sessionForm, sessionFormVisibility: sessionFormVisibility
        )
        let detail = try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId)
        return ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: detail?.loggedActivity, activityReflection: detail?.reflection,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )
    }

    @Test("Activity Detail exposes the exact stored RPE for a logged activity")
    @MainActor
    func activityDetailExposesStoredRPE() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext)),
            modelContext: container.mainContext
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: nil
        )

        #expect(viewModel.perceivedExertion == 7)
    }

    @Test("Activity Detail omits RPE when none was recorded")
    @MainActor
    func activityDetailOmitsNilRPE() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: nil
        )

        #expect(viewModel.perceivedExertion == nil)
    }

    @Test("Activity Detail exposes ActivityReflection.bodyFeeling as Form, linked to the exact LoggedActivity")
    @MainActor
    func activityDetailExposesFormFromExactLoggedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 4
        )

        #expect(viewModel.formValue == 4)
    }

    @Test("Activity Detail never shows another logged activity's Form value")
    @MainActor
    func activityDetailNeverShowsAnotherActivitysForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModelA = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 2
        )
        let viewModelB = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 5
        )

        #expect(viewModelA.formValue == 2)
        #expect(viewModelB.formValue == 5)
        #expect(viewModelA.activity.plannedActivityId != viewModelB.activity.plannedActivityId)
    }

    @Test("Activity Detail never shows another athlete's Form value")
    @MainActor
    func activityDetailNeverShowsAnotherAthletesForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let otherWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: otherAthleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 3
        )
        _ = try Self.makeCompletedActivityDetailViewModel(
            athleteId: otherAthleteId, container: container, planningService: planningService, weekPlan: otherWeekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 5
        )

        #expect(viewModel.formValue == 3)
    }

    @Test("Activity Detail omits Form when no reflection exists for the logged activity")
    @MainActor
    func activityDetailOmitsFormWhenNoReflectionExists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: nil
        )

        #expect(viewModel.formValue == nil)
    }

    @Test("Activity Detail omits Form when a reflection exists but bodyFeeling itself is nil")
    @MainActor
    func activityDetailOmitsFormWhenBodyFeelingNil() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(trainingService: trainingService, reflectionService: reflectionService)
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let logged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: "Morning run", startedAt: .now,
            loggedByActorId: ActorId()
        )
        // A genuine, valid ActivityReflection whose meaningful content
        // is text, not bodyFeeling — proves ReflectionService still
        // allows this (the entity is not narrowed to VX-022's use
        // case), and that Activity Detail correctly omits Form for it.
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, learningNote: "Felt strong on the last interval."
        )

        let detail = try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId)
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: detail?.loggedActivity, activityReflection: detail?.reflection,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )

        #expect(detail?.reflection != nil) // the reflection genuinely exists...
        #expect(viewModel.formValue == nil) // ...but Form is correctly omitted.
    }

    @Test("Activity Detail never exposes Form when the reflection's visibility is privateToAthlete — hidden, not treated as missing")
    @MainActor
    func activityDetailHidesPrivateToAthleteForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: nil, sessionForm: 4, sessionFormVisibility: .privateToAthlete
        )

        // The reflection genuinely exists with a real bodyFeeling value
        // — privacy hides it from display, it is not silently treated
        // as if the data never existed at the persistence layer.
        #expect(viewModel.formValue == nil)
    }

    @Test("Activity Detail's RPE and Form coexist correctly alongside unchanged Athlete/Activity/Date/Status fields")
    @MainActor
    func activityDetailRPEAndFormCoexistWithExistingFields() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())

        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )

        #expect(viewModel.athleteDisplayName == "Oliver")
        #expect(viewModel.activity.title == "Morning run")
        #expect(viewModel.activity.localDate == TrainingPlanningCoordinationService.today())
        #expect(viewModel.isCompleted == true)
        #expect(viewModel.perceivedExertion == 7)
        #expect(viewModel.formValue == 4)
    }

    // MARK: - Planned/Logged Activity lifecycle consistency cleanup: Edit Logged Activity (RPE + Form)

    @Test("prefillLoggedActivityEditForm loads the exact existing canonical RPE and Form values")
    @MainActor
    func prefillLoggedActivityEditFormLoadsExistingValues() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )

        viewModel.prefillLoggedActivityEditForm()

        #expect(viewModel.editLoggedPerceivedExertion == 7)
        #expect(viewModel.editLoggedSessionForm == 4)
    }

    @Test("saveLoggedActivityEdit persists a changed RPE to the canonical LoggedActivity.perceivedExertion")
    @MainActor
    func saveLoggedActivityEditPersistsChangedRPE() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: trainingRepository),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )
        viewModel.prefillLoggedActivityEditForm()
        viewModel.editLoggedPerceivedExertion = 9

        #expect(viewModel.saveLoggedActivityEdit())

        #expect(viewModel.perceivedExertion == 9)
        let stored = try #require(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).first)
        #expect(stored.perceivedExertion == 9)
    }

    @Test("saveLoggedActivityEdit persists a changed Form to the exact linked ActivityReflection.bodyFeeling")
    @MainActor
    func saveLoggedActivityEditPersistsChangedForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )
        viewModel.prefillLoggedActivityEditForm()
        viewModel.editLoggedSessionForm = 2

        #expect(viewModel.saveLoggedActivityEdit())

        #expect(viewModel.formValue == 2)
        let loggedActivityId = try #require(viewModel.loggedActivity?.loggedActivityId)
        let reflection = try #require(try reflectionService.fetchActivityReflection(forLoggedActivity: loggedActivityId))
        #expect(reflection.bodyFeeling == 2)
        // Exactly one reflection for this LoggedActivity — updated in
        // place, never a second one created.
        #expect(try reflectionService.fetchActivityReflections(forLoggedActivity: loggedActivityId).count == 1)
    }

    @Test("Edit Logged Activity never touches another athlete's LoggedActivity — athlete isolation preserved")
    @MainActor
    func editLoggedActivityEnforcesAthleteIsolation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: trainingRepository),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )
        // A view model wired to a DIFFERENT athlete but pointed at the
        // same LoggedActivity/ActivityReflection via their identity —
        // mirrors the coordinator-level isolation guard from underneath
        // the screen the user would actually interact with.
        // `activityReflection` is carried over too (not just
        // `loggedActivity`) so `prefillLoggedActivityEditForm()` sees a
        // valid, already-set Form value — this test isolates the
        // ATHLETE-ISOLATION guard specifically, not the (separately
        // tested) Form-required validation.
        let otherAthleteViewModel = ActivityDetailViewModel(
            activity: viewModel.activity, isCompleted: true, loggedActivity: viewModel.loggedActivity,
            activityReflection: viewModel.activityReflection,
            weekPlanId: weekPlan.weekPlanId, athleteId: AthleteId(), athleteDisplayName: "Someone Else",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )
        otherAthleteViewModel.prefillLoggedActivityEditForm()
        otherAthleteViewModel.editLoggedPerceivedExertion = 1

        #expect(otherAthleteViewModel.saveLoggedActivityEdit() == false)
        #expect(otherAthleteViewModel.errorMessage != nil)

        // Untouched.
        let stored = try #require(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).first)
        #expect(stored.perceivedExertion == 7)
    }

    // MARK: - Review follow-up: Form remains required on correction for Completed

    @Test("saveLoggedActivityEdit rejects clearing Form back to unset on a Completed activity — canonical data is never left in a state initial logging would have forbidden")
    @MainActor
    func saveLoggedActivityEditRejectsClearingFormOnCompleted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let viewModel = try Self.makeCompletedActivityDetailViewModel(
            athleteId: athleteId, container: container, planningService: planningService, weekPlan: weekPlan,
            coordinator: coordinator, perceivedExertion: 7, sessionForm: 4
        )
        viewModel.prefillLoggedActivityEditForm()
        // The user explicitly picks "Not set" — must be rejected, not
        // silently saved as a cleared Form on a Completed activity.
        viewModel.editLoggedSessionForm = nil

        #expect(viewModel.saveLoggedActivityEdit() == false)
        #expect(viewModel.errorMessage != nil)

        // Canonical data untouched — still the original valid Form.
        let loggedActivityId = try #require(viewModel.loggedActivity?.loggedActivityId)
        let reflection = try #require(try reflectionService.fetchActivityReflection(forLoggedActivity: loggedActivityId))
        #expect(reflection.bodyFeeling == 4)
    }

    @Test("A legacy Completed activity with no historical Form value opens with Form unset but Save is blocked until a real value is chosen — never fabricated")
    @MainActor
    func saveLoggedActivityEditRequiresFormForLegacyCompletedActivityWithNoHistoricalValue() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Legacy session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        // Logged directly through TrainingService — bypasses the
        // coordinator entirely, so genuinely no ActivityReflection
        // exists at all (mirrors a legacy record predating Form).
        let logged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: activity.title, startedAt: .now,
            durationMinutes: 40, status: .completed,
            loggedByActorId: ActorId()
        )
        let detail = try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId)

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: detail?.loggedActivity,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )

        // Opens safely with no historical value — never fabricated.
        viewModel.prefillLoggedActivityEditForm()
        #expect(viewModel.editLoggedSessionForm == nil)

        // Save without choosing one is blocked.
        #expect(viewModel.saveLoggedActivityEdit() == false)
        #expect(viewModel.errorMessage != nil)
        #expect(try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivityId) == nil)

        // Choosing a real value then succeeds.
        viewModel.editLoggedSessionForm = 3
        #expect(viewModel.saveLoggedActivityEdit())
        let reflection = try #require(try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivityId))
        #expect(reflection.bodyFeeling == 3)
    }

    @Test("saveLoggedActivityEdit does not require Form for a Missed activity")
    @MainActor
    func saveLoggedActivityEditDoesNotRequireFormForMissed() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext)),
            modelContext: container.mainContext
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Missed session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let logged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: activity.title, startedAt: .now,
            durationMinutes: 1, status: .missed,
            loggedByActorId: ActorId()
        )

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: logged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )
        viewModel.prefillLoggedActivityEditForm()
        viewModel.editLoggedPerceivedExertion = 5
        // Form left nil — must not block a Missed correction.

        #expect(viewModel.saveLoggedActivityEdit())
        #expect(viewModel.perceivedExertion == 5)
    }

    // MARK: - Review follow-up: actual duration correction

    @Test("canEditLoggedDuration is true for Completed and false for Missed/Cancelled")
    @MainActor
    func canEditLoggedDurationReflectsOutcome() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let completedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Completed session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let missedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Missed session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let completedLogged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: completedActivity.plannedActivityId,
            activityType: .individualTraining, title: completedActivity.title, startedAt: .now,
            durationMinutes: 40, status: .completed,
            loggedByActorId: ActorId()
        )
        let missedLogged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: missedActivity.plannedActivityId,
            activityType: .individualTraining, title: missedActivity.title, startedAt: .now,
            durationMinutes: 1, status: .missed,
            loggedByActorId: ActorId()
        )

        let completedViewModel = ActivityDetailViewModel(
            activity: completedActivity, isCompleted: true, loggedActivity: completedLogged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )
        let missedViewModel = ActivityDetailViewModel(
            activity: missedActivity, isCompleted: true, loggedActivity: missedLogged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )

        #expect(completedViewModel.canEditLoggedDuration == true)
        #expect(missedViewModel.canEditLoggedDuration == false)
    }

    @Test("saveLoggedActivityEdit persists a changed actual duration to the canonical LoggedActivity.durationMinutes — distinct from planned duration")
    @MainActor
    func saveLoggedActivityEditPersistsChangedDuration() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )
        let logged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: activity.title, startedAt: .now,
            durationMinutes: 35, status: .completed,
            loggedByActorId: ActorId()
        )

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: logged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )
        viewModel.prefillLoggedActivityEditForm()
        #expect(viewModel.editLoggedDurationMinutes == 35)
        viewModel.editLoggedDurationMinutes = 42
        viewModel.editLoggedSessionForm = 3

        #expect(viewModel.saveLoggedActivityEdit())

        let stored = try #require(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).first)
        #expect(stored.durationMinutes == 42)
        // The plan's own planned duration is a completely separate
        // value, never overwritten by a logged-duration correction.
        #expect(activity.plannedDurationMinutes == 30)
    }

    @Test("saveLoggedActivityEdit rejects an invalid (out-of-range) duration correction for a Completed activity")
    @MainActor
    func saveLoggedActivityEditRejectsInvalidDuration() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let logged = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId,
            activityType: .individualTraining, title: activity.title, startedAt: .now,
            durationMinutes: 35, status: .completed,
            loggedByActorId: ActorId()
        )

        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: true, loggedActivity: logged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )
        viewModel.prefillLoggedActivityEditForm()
        viewModel.editLoggedDurationMinutes = 0
        viewModel.editLoggedSessionForm = 3

        #expect(viewModel.saveLoggedActivityEdit() == false)
        #expect(viewModel.errorMessage != nil)
        let stored = try #require(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).first)
        #expect(stored.durationMinutes == 35)
    }

    // MARK: - Planned/Logged Activity lifecycle consistency cleanup: Cancel

    @Test("canCancel is true before any outcome is resolved and false once the activity has an outcome")
    @MainActor
    func canCancelReflectsWhetherAnOutcomeIsResolved() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )

        #expect(viewModel.canCancel == true)
        #expect(viewModel.cancelActivity())
        #expect(viewModel.canCancel == false)
    }

    @Test("cancelActivity links a LoggedActivity with status .cancelled, updates outcomeStatus, and never deletes the PlannedActivity")
    @MainActor
    func cancelActivityUpdatesOutcomeStatusWithoutDeletingThePlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        var reloadCallCount = 0
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            ),
            onActivityLogged: { reloadCallCount += 1 }
        )

        #expect(viewModel.cancelActivity())

        #expect(viewModel.outcomeStatus == .cancelled)
        #expect(viewModel.isCompleted == true)
        #expect(reloadCallCount == 1)
        // Never a delete — the PlannedActivity itself is untouched and
        // still resolvable from the WeekPlan.
        #expect(viewModel.isDeleted == false)
        let stillPlanned = try planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        #expect(stillPlanned.contains { $0.plannedActivityId == activity.plannedActivityId })
    }

    @Test("Cancelling twice surfaces an error on the retry and never creates a duplicate LoggedActivity")
    @MainActor
    func cancellingTwiceSurfacesErrorOnRetry() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: trainingRepository),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )

        #expect(viewModel.cancelActivity())
        #expect(viewModel.cancelActivity() == false)
        #expect(viewModel.errorMessage != nil)
        #expect(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).count == 1)
    }

    // MARK: - Reversibility principle: Reopen Activity (undo Cancel)

    @Test("canReopen is true only once cancelled, false before cancellation and false once logged normally")
    @MainActor
    func canReopenReflectsCancelledOutcomeOnly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )

        #expect(viewModel.canReopen == false)
        #expect(viewModel.cancelActivity())
        #expect(viewModel.canReopen == true)
    }

    @Test("canReopen allows Missed and rejects Completed and Partially Completed")
    @MainActor
    func canReopenUsesNoTrainingOutcomeGate() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(
            athleteId: athleteId,
            weekStart: TrainingPlanningCoordinationService.weekStart()
        )

        for status: ActivityStatus in [.missed, .completed, .partiallyCompleted] {
            let activity = try planningService.addPlannedActivity(
                toWeekPlan: weekPlan.weekPlanId,
                athleteId: athleteId,
                activityType: .individualTraining,
                title: "\(status)",
                localDate: TrainingPlanningCoordinationService.today(),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
            let logged = try trainingService.logActivity(
                athleteId: athleteId,
                plannedActivityId: activity.plannedActivityId,
                activityType: .individualTraining,
                title: activity.title,
                startedAt: .now,
                durationMinutes: status == .missed ? 1 : 30,
                status: status,
                loggedByActorId: ActorId()
            )
            let viewModel = ActivityDetailViewModel(
                activity: activity,
                isCompleted: true,
                loggedActivity: logged,
                weekPlanId: weekPlan.weekPlanId,
                athleteId: athleteId,
                athleteDisplayName: "Oliver",
                isWeekPlanDraft: true,
                deletedByActorId: ActorId(),
                planningService: planningService,
                trainingReflectionCoordinationService: coordinator,
                notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                    activityReminderService: ActivityReminderService(
                        repository: ActivityReminderRepository(modelContext: container.mainContext),
                        scheduler: NoOpActivityReminderScheduler()
                    ),
                    planningService: planningService
                )
            )

            #expect(viewModel.canReopen == (status == .missed))
        }
    }

    @Test("Reopening Missed preserves PlannedActivityId and reloads the host after success")
    @MainActor
    func reopenMissedPreservesPlanAndSignalsSuccess() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let broadcaster = AthleteActivityChangeBroadcaster()
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService,
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext)),
            activityChangeBroadcaster: broadcaster,
            modelContext: container.mainContext
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(
            athleteId: athleteId,
            weekStart: TrainingPlanningCoordinationService.weekStart()
        )
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Missed session",
            localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let logged = try trainingService.logActivity(
            athleteId: athleteId,
            plannedActivityId: activity.plannedActivityId,
            activityType: activity.activityType,
            title: activity.title,
            startedAt: .now,
            durationMinutes: 1,
            status: .missed,
            loggedByActorId: ActorId()
        )
        var hostReloads = 0
        let viewModel = ActivityDetailViewModel(
            activity: activity,
            isCompleted: true,
            loggedActivity: logged,
            weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId,
            athleteDisplayName: "Oliver",
            isWeekPlanDraft: true,
            deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            ),
            onActivityLogged: { hostReloads += 1 }
        )

        #expect(viewModel.reopenActivity())
        #expect(hostReloads == 1)
        #expect(viewModel.activity.plannedActivityId == activity.plannedActivityId)
        #expect(try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId).isEmpty)
        #expect(
            try planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
                .contains { $0.plannedActivityId == activity.plannedActivityId }
        )
    }

    @Test("reopenActivity removes the cancelled LoggedActivity link, restores the unresolved state, and never deletes or duplicates the PlannedActivity")
    @MainActor
    func reopenActivityRestoresUnresolvedStateWithoutTouchingThePlan() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: trainingRepository),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext)),
            modelContext: container.mainContext
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        var reloadCallCount = 0
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            ),
            onActivityLogged: { reloadCallCount += 1 }
        )
        #expect(viewModel.cancelActivity())
        #expect(reloadCallCount == 1)

        #expect(viewModel.reopenActivity())

        // The exact SAME PlannedActivity identity — never deleted,
        // never duplicated.
        #expect(viewModel.activity.plannedActivityId == activity.plannedActivityId)
        #expect(viewModel.outcomeStatus == nil)
        #expect(viewModel.isCompleted == false)
        #expect(viewModel.canCancel == true)
        #expect(viewModel.canReopen == false)
        // The reload signal fires again — same contract Log/Cancel
        // already establish, so a mounted host screen picks up the
        // now-unresolved state immediately.
        #expect(reloadCallCount == 2)
        #expect(try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId).isEmpty)
        let stillPlanned = try planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        #expect(stillPlanned.count == 1)
        #expect(stillPlanned.first?.plannedActivityId == activity.plannedActivityId)
    }

    @Test("A reopened activity can be logged again through the normal canonical flow")
    @MainActor
    func reopenedActivityCanBeLoggedAgain() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: trainingRepository),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext)),
            modelContext: container.mainContext
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )
        let viewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )
        #expect(viewModel.cancelActivity())
        #expect(viewModel.reopenActivity())

        let logViewModel = viewModel.makeLogActivityViewModel()
        logViewModel.sessionForm = 4
        #expect(logViewModel.save())

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.status == .completed)
    }

    @Test("reopenActivity is a no-op that fails cleanly on an activity that was never cancelled")
    @MainActor
    func reopenActivityFailsCleanlyWhenNotCancelled() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: TrainingService(repository: TrainingRepository(modelContext: container.mainContext)),
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext)),
            modelContext: container.mainContext
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart())
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening swim", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        // Never cancelled or logged — outcomeStatus is nil.
        let unresolvedViewModel = ActivityDetailViewModel(
            activity: activity, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService, trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )
        #expect(unresolvedViewModel.reopenActivity() == false)

        // Completed — never reopenable through this action.
        let completedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let completedLogged = try TrainingService(repository: TrainingRepository(modelContext: container.mainContext)).logActivity(
            athleteId: athleteId, plannedActivityId: completedActivity.plannedActivityId,
            activityType: .individualTraining, title: completedActivity.title, startedAt: .now,
            durationMinutes: 40, status: .completed, loggedByActorId: ActorId()
        )
        let completedViewModel = ActivityDetailViewModel(
            activity: completedActivity, isCompleted: true, loggedActivity: completedLogged,
            weekPlanId: weekPlan.weekPlanId, athleteId: athleteId, athleteDisplayName: "Oliver",
            isWeekPlanDraft: true, deletedByActorId: ActorId(), planningService: planningService,
            trainingReflectionCoordinationService: coordinator,
            notificationsPlanningCoordinationService: NotificationsPlanningCoordinationService(
                activityReminderService: ActivityReminderService(
                    repository: ActivityReminderRepository(modelContext: container.mainContext),
                    scheduler: NoOpActivityReminderScheduler()
                ),
                planningService: planningService
            )
        )
        #expect(completedViewModel.canReopen == false)
        #expect(completedViewModel.reopenActivity() == false)
        #expect(completedViewModel.outcomeStatus == .completed)
    }

    /// Item 7: logging via the canonical flow preserves the
    /// PlannedActivity linkage automatically — the user never has to
    /// manually reconnect a completed activity to its plan.
    @Test("Logging preserves PlannedActivity linkage automatically")
    @MainActor
    func loggingPreservesPlannedActivityLinkage() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        var loggedFlag = false
        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: { loggedFlag = true }
        )
        logViewModel.durationMinutes = 45
        logViewModel.perceivedExertion = 6
        logViewModel.sessionForm = 4 // VX-022: required for a completed log.
        #expect(logViewModel.save())
        #expect(loggedFlag)

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.durationMinutes == 45)
        #expect(links.first?.perceivedExertion == 6)
    }

    /// VX-022 (Form / Session Form): logging a completed planned
    /// activity with a Form value stores it as
    /// `ActivityReflection.bodyFeeling`, linked to the exact
    /// `LoggedActivity` this save created by its stable typed ID —
    /// never inferred from title/date.
    @Test("Logging a completed planned activity with Form stores it as ActivityReflection.bodyFeeling, linked to the exact LoggedActivity, visible to guardians by default")
    @MainActor
    func loggingCompletedPlannedActivityWithFormStoresBodyFeeling() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let authorId = ActorId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: authorId,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        #expect(logViewModel.isCompleted) // default — this is the completed-logging path.
        // Planned/Logged Activity lifecycle consistency cleanup: actual
        // duration is required for a completed log; `activity` itself
        // has no planned duration, so it must be entered explicitly.
        logViewModel.durationMinutes = 45
        logViewModel.sessionForm = 3

        #expect(logViewModel.save())
        #expect(logViewModel.sessionFormPendingRetry == false)

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        let loggedActivity = try #require(links.first)
        let reflection = try reflectionService.fetchActivityReflection(forLoggedActivity: loggedActivity.loggedActivityId)
        #expect(reflection?.bodyFeeling == 3)
        #expect(reflection?.loggedActivityId == loggedActivity.id)
        #expect(reflection?.athleteId == athleteId.rawValue)
        // VX-022 correction: family-first MVP default, not
        // privateToAthlete.
        #expect(reflection?.visibility == .sharedWithGuardians)
    }

    /// VX-022 correction: Form is required for the V1 Log Activity flow
    /// ("Form is required for completed training/match/competition
    /// logging") — a completed log must not be reported as saved
    /// without it, and nothing (not even the LoggedActivity) should be
    /// created when it's missing.
    @Test("Logging a completed planned activity without Form is blocked entirely — nothing is created")
    @MainActor
    func loggingCompletedPlannedActivityWithoutFormIsBlocked() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        // sessionForm left nil — Form is required for a completed log.

        #expect(logViewModel.save() == false)
        #expect(logViewModel.errorMessage != nil)
        #expect(logViewModel.didLog == false)
        #expect(try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId).isEmpty)
    }

    /// VX-022 correction: Form is required for COMPLETED logging
    /// specifically — logging as NOT completed represents a session
    /// that didn't happen, so there is nothing to rate, and Form must
    /// not block that path.
    @Test("Logging a planned activity as NOT completed does not require Form")
    @MainActor
    func loggingNotCompletedPlannedActivityDoesNotRequireForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        logViewModel.isCompleted = false
        // sessionForm left nil — must not block a not-completed log.

        #expect(logViewModel.save())
        #expect(logViewModel.errorMessage == nil)

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.status == .missed)
        #expect(try reflectionService.fetchActivityReflections(forAthlete: athleteId).isEmpty)
    }

    /// Review follow-up (duration placeholder audit): the exact leak
    /// found and fixed — `durationMinutes` is prefilled from the plan's
    /// own `plannedDurationMinutes` at init, so logging as NOT completed
    /// without clearing that field must never persist the leftover
    /// planned value as if it were a real, measured "actual" duration.
    /// The stored value for a Missed log must always be the schema's
    /// documented `1`-minute placeholder — never a fabricated real
    /// number for a session that never happened.
    @Test("Logging as NOT completed always stores the 1-minute placeholder duration, never the leftover prefilled planned duration")
    @MainActor
    func loggingNotCompletedNeverLeaksThePrefilledPlannedDuration() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        // Prefilled from the plan — never touched by the user.
        #expect(logViewModel.durationMinutes == 30)
        logViewModel.isCompleted = false

        #expect(logViewModel.save())

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.status == .missed)
        // The leftover planned value (30) must never leak through as
        // the actual/logged duration.
        #expect(links.first?.durationMinutes == 1)
    }

    /// Review follow-up (final check before merge, item 2): the Outcome
    /// picker lets a parent enter a Form value while "Completed" is
    /// selected, then switch to "Missed" before saving — `sessionForm`
    /// itself is never cleared by that switch (only the View's duration
    /// picker is hidden for Missed). Without gating at `save()`, that
    /// stale value would still reach `TrainingReflectionCoordinationService.logActivity`,
    /// which records whatever non-nil Form value it is given regardless
    /// of `status`. Nothing happened to rate for a Missed session, so it
    /// must never be persisted as this log's `ActivityReflection.bodyFeeling`.
    @Test("A Form value entered while Completed was selected is never persisted when the outcome is switched to Missed before saving")
    @MainActor
    func loggingAsMissedNeverPersistsAFormValueEnteredWhileCompletedWasSelected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        // Entered while "Completed" (the default) was still selected.
        logViewModel.sessionForm = 4
        // Then the parent switches the Outcome picker to "Missed" —
        // `sessionForm` is left exactly as it was; the View never clears it.
        logViewModel.isCompleted = false

        #expect(logViewModel.save())

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        let logged = try #require(links.first)
        #expect(logged.status == .missed)
        #expect(try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivityId) == nil)
        // The local edit state is cleared too, not just what was sent —
        // guards a defensive re-invocation of save() from hitting the
        // retry branch and resurrecting the stale value afterward.
        #expect(logViewModel.sessionForm == nil)

        // Even a defensive second save() call (e.g. a double-tap before
        // the sheet dismisses) must not retroactively attach the stale
        // Form value — sessionForm is nil now, so the retry branch's own
        // `guard let sessionForm else { return true }` exits cleanly.
        #expect(logViewModel.save())
        #expect(try reflectionService.fetchActivityReflection(forLoggedActivity: logged.loggedActivityId) == nil)
    }

    // MARK: - Planned/Logged Activity lifecycle consistency cleanup: actual duration required for Completed

    @Test("Logging a completed planned activity with no duration entered is blocked entirely — nothing is created")
    @MainActor
    func loggingCompletedPlannedActivityWithoutDurationIsBlocked() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            // plannedDurationMinutes deliberately omitted.
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        // Activity outcome consistency closeout (item D): the plan has
        // no duration, so the ViewModel's own canonical edit state must
        // genuinely be nil — never fabricated to 60. (The View-layer
        // `RequiredDurationPickerView` is what makes this visible as
        // "Not set" instead of a misleading pre-selected 60; this
        // asserts the state it reads from.)
        #expect(logViewModel.durationMinutes == nil)
        logViewModel.sessionForm = 3
        // durationMinutes left nil — nothing to prefill from, nothing entered.

        #expect(logViewModel.save() == false)
        #expect(logViewModel.errorMessage != nil)
        #expect(logViewModel.didLog == false)
        #expect(try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId).isEmpty)

        // Explicitly choosing a value (the "Set duration" tap, then
        // adjusting) allows the same save to succeed — nil is a valid,
        // recoverable editing state, not a dead end.
        logViewModel.durationMinutes = 45
        #expect(logViewModel.save())
        #expect(logViewModel.didLog == true)
        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.durationMinutes == 45)
    }

    // MARK: - TestFlight regression: required Completed duration

    /// A nil value stays nil until the required control's explicit Set
    /// duration action assigns its starting selection. The component
    /// exposes no transition back to nil once the required value exists.
    @Test("RequiredDurationPickerView starts a duration only after the explicit Set duration action")
    func requiredDurationPickerUsesExplicitStartingSelection() {
        var durationMinutes: Int? = nil
        #expect(durationMinutes == nil)

        durationMinutes = RequiredDurationPickerView.initialSelectionMinutes
        #expect(durationMinutes == 60)
    }

    /// Review follow-up (TestFlight regression): reproduces the full
    /// nil -> selected -> saved flow entirely through `LogActivityViewModel`'s
    /// own public API — the exact state transition the View's "Not set"
    /// tap performs (`durationMinutes = RequiredDurationPickerView.initialSelectionMinutes`,
    /// then further wheel adjustment) — proving a Completed log can
    /// actually save once a duration has genuinely been selected, for a
    /// plan with no planned duration at all.
    @Test("A plan with no planned duration: selecting a duration through the same seed the View uses allows a Completed log to save")
    @MainActor
    func selectingDurationFromNoPlanAllowsCompletedLogToSave() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            // plannedDurationMinutes deliberately omitted.
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        #expect(logViewModel.durationMinutes == nil)

        // The exact assignment RequiredDurationPickerView's "Not set" tap
        // performs — never a fabricated 60 baked into the ViewModel itself.
        logViewModel.durationMinutes = RequiredDurationPickerView.initialSelectionMinutes
        logViewModel.sessionForm = 3
        #expect(logViewModel.durationMinutes == 60)

        #expect(logViewModel.save())
        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        #expect(links.first?.status == .completed)
        #expect(links.first?.durationMinutes == 60)
    }

    /// Outcome changes only control whether the required picker is
    /// visible. They do not erase the user's transient duration edit,
    /// and no canonical Training value exists until Save.
    @Test("Completed to Missed to Completed preserves the transient duration selection")
    @MainActor
    func outcomeTogglePreservesTransientDurationSelection() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(
            repository: TrainingRepository(modelContext: container.mainContext)
        )
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let viewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        viewModel.durationMinutes = 45
        #expect(viewModel.isCompleted)

        viewModel.isCompleted = false
        #expect(viewModel.durationMinutes == 45)

        viewModel.isCompleted = true
        #expect(viewModel.durationMinutes == 45)
    }

    @Test("A planned duration of 60 is the live edit value and saves immediately without a duration error")
    @MainActor
    func plannedDurationSixtySavesWithoutPickerInteraction() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionService = ReflectionService(
            repository: ReflectionRepository(modelContext: container.mainContext)
        )
        let athleteId = AthleteId()
        let weekPlan = try planningService.getOrCreateWeekPlan(
            athleteId: athleteId,
            weekStart: TrainingPlanningCoordinationService.weekStart()
        )
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId,
            athleteId: athleteId,
            activityType: .individualTraining,
            title: "Morning run",
            localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            plannedDurationMinutes: 60
        )
        let viewModel = LogActivityViewModel(
            plannedActivity: activity,
            athleteId: athleteId,
            athleteDisplayName: "Oliver",
            authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService,
                reflectionService: reflectionService
            ),
            onLogged: {}
        )

        #expect(viewModel.durationMinutes == 60)
        viewModel.sessionForm = 3
        #expect(viewModel.save())
        #expect(viewModel.errorMessage == nil)

        let loggedActivities = try trainingRepository.fetchLoggedActivities(
            forPlannedActivity: activity.plannedActivityId
        )
        let logged = try #require(loggedActivities.first)
        #expect(logged.durationMinutes == 60)
    }

    @Test("Logging prefills actual duration from the planned duration but the user's changed value is what actually saves — never re-derived from the plan")
    @MainActor
    func loggingPrefillsPlannedDurationButSavesTheChangedActualValue() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )

        let logViewModel = LogActivityViewModel(
            plannedActivity: activity, athleteId: athleteId, athleteDisplayName: "Oliver", authorId: ActorId(),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            onLogged: {}
        )
        // Prefilled from the plan — the parent hasn't touched it yet.
        #expect(logViewModel.durationMinutes == 30)

        // Reality differed — the parent corrects it before saving.
        logViewModel.durationMinutes = 50
        logViewModel.sessionForm = 3

        #expect(logViewModel.save())

        let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
        #expect(links.count == 1)
        // The saved actual duration is the corrected value, not the
        // original planned one — canonical training truth, never
        // silently re-derived from the plan.
        #expect(links.first?.durationMinutes == 50)
        #expect(activity.plannedDurationMinutes == 30)
    }

    /// Item 7: Location — save/reload round-trip, and that it remains
    /// genuinely optional (nil stays nil, never a fabricated default).
    @Test("Location persists and reloads correctly, and remains optional")
    @MainActor
    func locationPersistsAndReloads() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        let withLocation = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Football", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Nadderud Stadion"
        )
        let withoutLocation = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let reloaded = try planningRepository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        let reloadedWithLocation = reloaded.first { $0.plannedActivityId == withLocation.plannedActivityId }
        let reloadedWithoutLocation = reloaded.first { $0.plannedActivityId == withoutLocation.plannedActivityId }
        #expect(reloadedWithLocation?.location == "Nadderud Stadion")
        #expect(reloadedWithoutLocation?.location == nil)

        // Edit can also set/clear location.
        let edited = try planningService.editPlannedActivity(
            withoutLocation.plannedActivityId, expectedWeekPlanId: weekPlan.weekPlanId,
            activityType: .individualTraining, title: "Run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), location: "Park"
        )
        #expect(edited.location == "Park")
    }

    /// Item 4: Athlete Home's reflection section resolves the
    /// SPECIFIC, already-known athleteId it was constructed with — not
    /// a fallback to any other athlete. WeeklyReviewViewModel is
    /// constructed with the exact athleteId HomeDashboardView holds.
    @Test("Athlete Home's reflection navigation carries the specific athlete's own AthleteId, not a fallback")
    @MainActor
    func reflectionNavigationPreservesSpecificAthleteId() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let workspaceId = WorkspaceId()
        let oliver = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let athleteTwo = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "AthleteTwo",
            birthDate: LocalDate(year: 2013, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        // HomeDashboardViewModel is constructed once per specific
        // athlete — this is what makes its own reflectionSection
        // correct: the athleteId baked into the ViewModel at
        // construction is the ONLY one it ever uses, for whichever
        // athlete's Home this happens to be.
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let firstViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: coordinationService,
            coachingPresentationProvider: NoopCoachingPresentationProvider(),
            athleteId: oliver.athleteId,
            weekStart: TrainingPlanningCoordinationService.weekStart(),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
        let secondViewModel = HomeDashboardViewModel(
            trainingPlanningCoordinationService: coordinationService,
            coachingPresentationProvider: NoopCoachingPresentationProvider(),
            athleteId: athleteTwo.athleteId,
            weekStart: TrainingPlanningCoordinationService.weekStart(),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )

        #expect(firstViewModel.athleteId == oliver.athleteId)
        #expect(secondViewModel.athleteId == athleteTwo.athleteId)
        #expect(firstViewModel.athleteId != secondViewModel.athleteId)
    }
}

/// A minimal no-op stand-in, since this suite only needs to confirm
/// HomeDashboardViewModel's own athleteId identity, not real coaching
/// data.
private struct NoopCoachingPresentationProvider: CoachingPresentationProviding {
    struct NotImplemented: Error {}
    func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
        throw NotImplemented()
    }
}
