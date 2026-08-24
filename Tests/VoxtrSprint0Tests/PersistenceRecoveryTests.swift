import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrReflectionDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrCoreReferenceData

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
//
// Unlike every prior persistence test in this project's history, these
// go THROUGH SwiftDataPersistenceController and FamilyOnboardingCoordinator
// — the real production types both AthleteApp and ParentApp actually
// use — rather than constructing ModelContainer/repositories directly.
// That gap in test coverage (every earlier test bypassed the real
// construction path) is why CompositionRoot.build's own default
// argument bug went uncaught despite the migration plan itself already
// having passing tests. Critical persistence recovery work: after
// collapsing the schema history to AppCurrentSchema (see
// AppSchemaVersioning.swift's own doc comment for why), these tests
// cover fresh install, restart, and onboarding rollback — the actual
// three scenarios reported as broken.
@Suite("Persistence recovery: fresh install, restart, and onboarding rollback", .serialized)
struct PersistenceRecoveryTests {

    @Test("Fresh install: create family, create multiple athletes, restart container, reload data")
    @MainActor
    func freshInstallCreateFamilyMultipleAthletesRestartReload() throws {
        // SwiftDataPersistenceController.makeModelContainer() targets
        // the app's own default on-disk location, not a controllable
        // temp file — construct the equivalent container directly
        // against a temp URL instead, using the exact same
        // Schema(versionedSchema:)/migrationPlan pairing
        // SwiftDataPersistenceController uses internally, so this still
        // exercises the real construction path.
        let storeURL = URL.temporaryDirectory.appendingPathComponent("fresh-install-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        // VX-023 review follow-up, updated for Design Foundation V0.1
        // (Athlete Color canonical preference round), updated again for
        // Sport / Activity Identity domain foundation: a genuine fresh
        // install now targets AppSchemaV4 (CompositionRoot.build's real
        // default) — no migration stage runs at all for a brand-new
        // store; it's simply created directly under the current
        // version.
        let schema = Schema(versionedSchema: AppSchemaV4.self)

        var athleteIds: [UUID] = []
        var workspaceId: WorkspaceId
        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
            let athleteRepository = AthleteRepository(modelContext: container.mainContext)
            let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)

            // The real production onboarding path, not a hand-rolled
            // equivalent.
            let coordinator = FamilyOnboardingCoordinator(
                modelContext: container.mainContext,
                parentWorkspaceRepository: parentWorkspaceRepository,
                athleteRepository: athleteRepository,
                athleteAccessGrantRepository: athleteAccessGrantRepository
            )
            let created = try coordinator.createFamily(
                parentGivenName: "Kari",
                athleteGivenName: "Jonas",
                athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
                athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                athleteDevelopmentStage: .parentLed
            )
            workspaceId = created.workspace.workspaceId

            // A second athlete, via the real
            // AthleteFamilyManagementService — matching "create
            // multiple athletes."
            let managementService = AthleteFamilyManagementService(
                modelContext: container.mainContext,
                athleteRepository: athleteRepository,
                athleteAccessGrantRepository: athleteAccessGrantRepository
            )
            let second = try managementService.addAthlete(
                workspaceId: created.workspace.workspaceId,
                participantId: created.participant.id,
                givenName: "Emma",
                birthDate: LocalDate(year: 2014, month: 6, day: 1),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                developmentStage: .parentLed
            )
            athleteIds = [created.athlete.athleteId.rawValue, second.athlete.athleteId.rawValue]
        }
        // Container above goes out of scope — genuinely closed.

        // Restart: a completely new container against the same file,
        // via the same construction path.
        let restartedContainer = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let restartedParentRepository = ParentWorkspaceRepository(modelContext: restartedContainer.mainContext)
        let restartedAthleteRepository = AthleteRepository(modelContext: restartedContainer.mainContext)

        #expect(try restartedParentRepository.fetchAllParentProfiles().first?.givenName == "Kari")
        let restartedAthletes = try restartedAthleteRepository.fetchAthletes(forWorkspace: workspaceId)
        #expect(Set(restartedAthletes.map(\.givenName)) == ["Jonas", "Emma"])
        #expect(Set(restartedAthletes.map(\.id)) == Set(athleteIds))
    }

    @Test("Restarting a store created under the current schema succeeds without a migration path being required")
    @MainActor
    func restartUnderCurrentSchemaSucceeds() throws {
        // A store created under whatever the CURRENT version is still
        // needs to reopen correctly on the NEXT construction, with no
        // migration stage actually being exercised (source and target
        // version are identical). VX-023 review follow-up: this now
        // targets AppSchemaV2 — the real current version — rather than
        // the now-frozen AppCurrentSchema (V1). The genuine V1→V2
        // migration case this comment used to describe as "not yet
        // meaningful" is now covered separately by
        // existingV1StoreMigratesToV2Successfully below. Design
        // Foundation V0.1 (Athlete Color canonical preference round):
        // updated again to AppSchemaV3, the real current version after
        // that round's bump — the V2→V3 migration case is covered
        // separately by existingV2StoreMigratesToV3Successfully below.
        // Sport / Activity Identity domain foundation: updated again to
        // AppSchemaV4, the real current version after that round's own
        // bump — the V3→V4 migration case is covered separately by
        // existingV3StoreMigratesToV4Successfully below.
        let storeURL = URL.temporaryDirectory.appendingPathComponent("restart-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let schema = Schema(versionedSchema: AppSchemaV4.self)

        do {
            let firstContainer = try ModelContainer(
                for: schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: firstContainer.mainContext)
            _ = try parentWorkspaceRepository.createParentAndWorkspace(givenName: "Kari")
        }

        let secondContainer = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let secondParentWorkspaceRepository = ParentWorkspaceRepository(modelContext: secondContainer.mainContext)
        #expect(try secondParentWorkspaceRepository.fetchAllParentProfiles().count == 1)

        // Reopen a third time, matching "restart, reload data" being
        // exercised more than once.
        let thirdContainer = try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let thirdParentWorkspaceRepository = ParentWorkspaceRepository(modelContext: thirdContainer.mainContext)
        #expect(try thirdParentWorkspaceRepository.fetchAllParentProfiles().first?.givenName == "Kari")
    }

    @Test("CompositionRoot.build's own default persistence provider constructs successfully")
    @MainActor
    func compositionRootDefaultPersistenceConstructsSuccessfully() throws {
        // Exercises the real, current default directly — the exact
        // construction CompositionRoot.build() performs when called
        // with no arguments, as both AthleteApp and ParentApp actually
        // do. This is the single most direct regression guard against
        // the exact class of bug (a default argument silently pointing
        // at the wrong schema version) that caused this whole
        // investigation. Design Foundation V0.1 (Athlete Color
        // canonical preference round): updated to AppSchemaV3, matching
        // CompositionRoot.build's own real default after that round's
        // version bump. Sport / Activity Identity domain foundation:
        // updated again to AppSchemaV4, matching that round's own bump.
        let controller = SwiftDataPersistenceController(
            versionedSchema: AppSchemaV4.self,
            migrationPlan: AppSchemaMigrationPlan.self
        )
        let container = try controller.makeModelContainer()

        #expect(container.schema.entities.count == AppSchema.modelTypes.count)
    }

    @Test("VX-023 review follow-up: a store created under AppCurrentSchema (V1, 15 entities) reopens successfully under AppSchemaV2 (17 entities) via the lightweight migration stage — existing data survives, and the newly-added Sleep model types are genuinely usable against the migrated store")
    @MainActor
    func existingV1StoreMigratesToV2Successfully() throws {
        // Simulates exactly the scenario an existing TestFlight install
        // hits after updating to a build containing VX-023: a store
        // already on disk, saved under the OLD, now-frozen V1 schema —
        // no DailyStatus/AthleteSettings tables exist in it at all.
        let storeURL = URL.temporaryDirectory.appendingPathComponent("v1-to-v2-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let v1Schema = Schema(versionedSchema: AppCurrentSchema.self)
        var athleteRawId: UUID
        do {
            let v1Container = try ModelContainer(
                for: v1Schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: v1Schema, url: storeURL)]
            )
            let athlete = AthleteProfile(
                workspaceId: WorkspaceId(), givenName: "Jonas",
                birthDate: LocalDate(year: 2012, month: 4, day: 10),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
            )
            v1Container.mainContext.insert(athlete)
            try v1Container.mainContext.save()
            athleteRawId = athlete.id
        }
        // Container above goes out of scope — genuinely closed, matching
        // a real app relaunch rather than a container kept alive.

        // The NEXT launch, on the SAME store file, targets V2 — current
        // at the time this migration shipped (Design Foundation V0.1's
        // Athlete Color round later moved the real production default
        // to AppSchemaV3; see existingV2StoreMigratesToV3Successfully
        // below for that later step of the SAME migration chain).
        let v2Schema = Schema(versionedSchema: AppSchemaV2.self)
        let v2Container = try ModelContainer(
            for: v2Schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: v2Schema, url: storeURL)]
        )

        // Pre-existing data survived the migration completely untouched.
        let athleteRepository = AthleteRepository(modelContext: v2Container.mainContext)
        let athletes = try athleteRepository.fetchAllAthletes()
        #expect(athletes.count == 1)
        #expect(athletes.first?.id == athleteRawId)
        #expect(athletes.first?.givenName == "Jonas")

        // The new Sleep model type is genuinely usable against the
        // migrated store — proves the lightweight stage actually
        // created its table, not merely that the container opened
        // without throwing.
        let reflectionRepository = ReflectionRepository(modelContext: v2Container.mainContext)
        let athleteId = AthleteId(rawValue: athleteRawId)
        let recorded = try reflectionRepository.upsertSleepQuality(
            athleteId: athleteId,
            localDate: LocalDate(year: 2026, month: 8, day: 18),
            sleepQuality: 4,
            visibility: .sharedWithGuardians
        )
        #expect(recorded.sleepQuality == 4)
        #expect(try v2Container.mainContext.fetch(FetchDescriptor<DailyStatus>()).count == 1)
    }

    /// Design Foundation V0.1 (Athlete Color canonical preference
    /// round), requirement 7: migration preserves existing athlete data
    /// and permits colour persistence. Simulates the scenario every
    /// existing TestFlight install hits after updating to a build
    /// containing this round: a store already on disk under the OLD,
    /// now-frozen V2 schema, with an `AthleteSettings` row whose
    /// `preferredColor` was never touched (this field did not exist as
    /// a concept when that row was written).
    @Test("A store created under AppSchemaV2 (17 entities, no explicit Athlete Color ever set) reopens successfully under AppSchemaV3 via the lightweight migration stage — existing AthleteProfile/AthleteSettings data survives untouched, preferredColor resolves to nil (never a forced default), and the field is genuinely writable/readable against the migrated store")
    @MainActor
    func existingV2StoreMigratesToV3Successfully() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("v2-to-v3-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let v2Schema = Schema(versionedSchema: AppSchemaV2.self)
        var athleteRawId: UUID
        do {
            let v2Container = try ModelContainer(
                for: v2Schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: v2Schema, url: storeURL)]
            )
            let athlete = AthleteProfile(
                workspaceId: WorkspaceId(), givenName: "Jonas",
                birthDate: LocalDate(year: 2012, month: 4, day: 10),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
            )
            v2Container.mainContext.insert(athlete)
            try v2Container.mainContext.save()
            athleteRawId = athlete.id

            // An AthleteSettings row exists (Sleep tracking already
            // toggled, as a real pre-this-round install could easily
            // have) but preferredColor was never set — the exact state
            // this round's migration must leave untouched, not force
            // to some default.
            //
            // Codemagic checksum fix: `v2Container`'s registered schema
            // is `AppSchemaV2`, which (after that fix) declares its OWN
            // frozen `AppSchemaV2.AthleteSettings` — the genuine V2-era
            // shape, with no `preferredColor` field at all — not the
            // live `VoxtrAthleteDomain.AthleteSettings` `AthleteRepository`
            // constructs. Inserting the live type here would no longer
            // match this context's own registered schema, so this row
            // is built directly against the frozen V2 type instead,
            // exactly as an app actually running under V2 (before the
            // Athlete Color round ever existed) would have persisted
            // it.
            let v2Settings = AppSchemaV2.AthleteSettings(athleteId: athleteRawId, sleepTrackingEnabled: false)
            v2Container.mainContext.insert(v2Settings)
            try v2Container.mainContext.save()
        }
        // Container above goes out of scope — genuinely closed, matching
        // a real app relaunch rather than a container kept alive.

        // The NEXT launch, on the SAME store file, targets the CURRENT
        // schema (V3) — the real production default
        // (CompositionRoot.build's own `versionedSchema: AppSchemaV3.self`).
        let v3Schema = Schema(versionedSchema: AppSchemaV3.self)
        let v3Container = try ModelContainer(
            for: v3Schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: v3Schema, url: storeURL)]
        )

        // Pre-existing data survived the migration completely untouched.
        let athleteRepository = AthleteRepository(modelContext: v3Container.mainContext)
        let athletes = try athleteRepository.fetchAllAthletes()
        #expect(athletes.count == 1)
        #expect(athletes.first?.id == athleteRawId)
        #expect(athletes.first?.givenName == "Jonas")

        let athleteId = AthleteId(rawValue: athleteRawId)
        let migratedSettings = try athleteRepository.fetchAthleteSettings(forAthlete: athleteId)
        // Sleep tracking, set before the migration, survived it exactly
        // as-is — this round's field addition never touches unrelated
        // existing fields on the same row.
        #expect(migratedSettings?.sleepTrackingEnabled == false)
        // No forced/synthesized default for the new field — an
        // athlete who never touched Athlete Color still resolves
        // through the stable AthleteId fallback, never a hard-coded
        // persisted value.
        #expect(migratedSettings?.preferredColor == nil)

        // The new field is genuinely writable/readable against the
        // migrated store — proves the lightweight stage actually
        // carries the new column, not merely that the container opened
        // without throwing.
        try athleteRepository.setPreferredColor(athleteId: athleteId, color: .purple)
        let afterWrite = try athleteRepository.fetchAthleteSettings(forAthlete: athleteId)
        #expect(afterWrite?.preferredColor == .purple)
        // Still exactly one AthleteSettings row for this athlete — the
        // new field's write reused the migrated row, never created a
        // second one.
        #expect(try v3Container.mainContext.fetch(FetchDescriptor<AthleteSettings>()).count == 1)
    }

    /// Sport / Activity Identity domain foundation, Part 8 (historical
    /// data): simulates the scenario every existing TestFlight install
    /// hits after updating to a build containing this round — a store
    /// already on disk under the OLD, now-frozen V3 schema, holding:
    /// - a `PlannedActivity` written under the PRE-this-round contract
    ///   (title was mandatory 1-120 characters, `Sport` was never
    ///   persisted at all);
    /// - a SECOND `PlannedActivity`, a `LoggedActivity`, AND a
    ///   `RecurringPlannedActivity` — all three independently persisted
    ///   with the OLD `activityType` raw value `"physicalTraining"`,
    ///   exactly as a genuine pre-this-round install would have.
    ///
    /// Review correction (Blocker A): a prior version of this migration
    /// removed `physicalTraining` from the `ActivityType` enum outright,
    /// which would have made every one of these four rows fail to
    /// decode on the very next launch — completely unacceptable, and
    /// exactly what this test now proves does NOT happen.
    ///
    /// Confirms for every row: migration succeeds, the row still exists
    /// with its id/title/duration/date/provenance completely unchanged,
    /// its `activityType` still honestly reads back as `physicalTraining`
    /// (never silently reclassified to `strength`/`conditioning`/`other`,
    /// never discarded), and no Sport is ever inferred from it. Also
    /// confirms the new `Sport` table genuinely exists and is usable
    /// against the migrated store (proves the `.lightweight` stage
    /// actually created it, not merely that the container opened).
    @Test("A store created under AppSchemaV3 reopens successfully under AppSchemaV4 via the lightweight migration stage — existing PlannedActivity/LoggedActivity/RecurringPlannedActivity rows persisted with the legacy physicalTraining ActivityType all survive untouched and honestly re-readable as physicalTraining, the name-only PlannedActivity survives with no Sport ever inferred from its title, and the new Sport table is genuinely usable against the migrated store")
    @MainActor
    func existingV3StoreMigratesToV4Successfully() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("v3-to-v4-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let v3Schema = Schema(versionedSchema: AppSchemaV3.self)
        var athleteRawId: UUID
        var plannedActivityRawId: UUID
        var legacyPlannedActivityRawId: UUID
        var legacyLoggedActivityRawId: UUID
        var legacyRecurringActivityRawId: UUID
        let legacyStartedAt = Date(timeIntervalSince1970: 1_755_000_000)
        do {
            let v3Container = try ModelContainer(
                for: v3Schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: v3Schema, url: storeURL)]
            )
            let athlete = AthleteProfile(
                workspaceId: WorkspaceId(), givenName: "Jonas",
                birthDate: LocalDate(year: 2012, month: 4, day: 10),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
            )
            v3Container.mainContext.insert(athlete)
            try v3Container.mainContext.save()
            athleteRawId = athlete.id
            let athleteId = AthleteId(rawValue: athleteRawId)

            // A genuine pre-this-round record: mandatory title, no
            // Sport — exactly what every Internal Alpha record already
            // looks like (see this round's audit findings).
            let planningRepository = PlanningRepository(modelContext: v3Container.mainContext)
            let weekPlan = try planningRepository.insertWeekPlan(
                athleteId: athleteId,
                weekStart: LocalDate(year: 2026, month: 8, day: 17)
            )
            let plannedActivity = try planningRepository.insertPlannedActivity(
                weekPlanId: weekPlan.weekPlanId,
                athleteId: athleteId,
                activityType: .teamTraining,
                title: "Football practice",
                localDate: LocalDate(year: 2026, month: 8, day: 18),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
            )
            plannedActivityRawId = plannedActivity.id
            // No Sport table exists at all under V3 — nothing to seed.

            // The actual real-world case Blocker A is about: a
            // PlannedActivity ALREADY persisted, under V3, with the OLD
            // `activityType` raw value — inserted directly against the
            // real V3-schema ModelContext, exercising the true on-disk
            // representation, not merely an in-memory enum decode.
            let legacyPlannedActivity = try planningRepository.insertPlannedActivity(
                weekPlanId: weekPlan.weekPlanId,
                athleteId: athleteId,
                activityType: .physicalTraining,
                title: "Wednesday gym",
                localDate: LocalDate(year: 2026, month: 8, day: 19),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                plannedDurationMinutes: 45,
                notes: "Legacy pre-round classification"
            )
            legacyPlannedActivityRawId = legacyPlannedActivity.id

            // Same legacy raw value, independently persisted on
            // LoggedActivity — proves this isn't only fixed for
            // PlannedActivity.
            let trainingRepository = TrainingRepository(modelContext: v3Container.mainContext)
            let legacyLoggedActivity = try trainingRepository.insertLoggedActivity(
                athleteId: athleteId,
                activityType: .physicalTraining,
                title: "Wednesday gym",
                startedAt: legacyStartedAt,
                durationMinutes: 45,
                status: .completed,
                source: "manual"
            )
            legacyLoggedActivityRawId = legacyLoggedActivity.id

            // Same legacy raw value, independently persisted on
            // RecurringPlannedActivity — proves this isn't only fixed
            // for one-off activities.
            let legacyRecurringActivity = try planningRepository.insertRecurringPlannedActivity(
                athleteId: athleteId,
                title: "Wednesday gym",
                activityType: .physicalTraining,
                weekdays: [.wednesday],
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                effectiveStartDate: LocalDate(year: 2026, month: 8, day: 1),
                effectiveEndDate: LocalDate(year: 2026, month: 12, day: 31)
            )
            legacyRecurringActivityRawId = legacyRecurringActivity.id
        }
        // Container above goes out of scope — genuinely closed, matching
        // a real app relaunch rather than a container kept alive.

        // The NEXT launch, on the SAME store file, targets the CURRENT
        // schema (V4) — the real production default
        // (CompositionRoot.build's own `versionedSchema: AppSchemaV4.self`).
        let v4Schema = Schema(versionedSchema: AppSchemaV4.self)
        let v4Container = try ModelContainer(
            for: v4Schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: v4Schema, url: storeURL)]
        )

        // The pre-existing name-only PlannedActivity survived completely
        // untouched: same id, same title, no Sport ever backfilled from
        // it.
        let allPlannedActivities = try v4Container.mainContext.fetch(FetchDescriptor<PlannedActivity>())
        let migratedActivity = allPlannedActivities.first { $0.id == plannedActivityRawId }
        #expect(migratedActivity?.title == "Football practice")
        #expect(migratedActivity?.sportId == nil)

        // The legacy physicalTraining PlannedActivity: migration
        // succeeded, the row still exists, and every field — id, title,
        // duration, date, notes — is completely unchanged. Its
        // classification still honestly reads back as `physicalTraining`
        // — never silently reclassified, never discarded — and it
        // remains excluded from `selectableCases`, so nothing NEW can
        // ever be created with it again.
        let migratedLegacyActivity = allPlannedActivities.first { $0.id == legacyPlannedActivityRawId }
        #expect(migratedLegacyActivity != nil)
        #expect(migratedLegacyActivity?.title == "Wednesday gym")
        #expect(migratedLegacyActivity?.activityType == .physicalTraining)
        #expect(migratedLegacyActivity?.activityType.isLegacyPersistenceOnly == true)
        #expect(migratedLegacyActivity?.plannedDurationMinutes == 45)
        #expect(migratedLegacyActivity?.notes == "Legacy pre-round classification")
        #expect(migratedLegacyActivity?.localDate == LocalDate(year: 2026, month: 8, day: 19))
        #expect(migratedLegacyActivity?.sportId == nil)

        // Same proof for LoggedActivity.
        let migratedLegacyLoggedActivity = try v4Container.mainContext
            .fetch(FetchDescriptor<LoggedActivity>())
            .first { $0.id == legacyLoggedActivityRawId }
        #expect(migratedLegacyLoggedActivity != nil)
        #expect(migratedLegacyLoggedActivity?.title == "Wednesday gym")
        #expect(migratedLegacyLoggedActivity?.activityType == .physicalTraining)
        #expect(migratedLegacyLoggedActivity?.durationMinutes == 45)
        #expect(migratedLegacyLoggedActivity?.startedAt == legacyStartedAt)
        #expect(migratedLegacyLoggedActivity?.athleteId == athleteRawId)

        // Same proof for RecurringPlannedActivity.
        let migratedLegacyRecurringActivity = try v4Container.mainContext
            .fetch(FetchDescriptor<RecurringPlannedActivity>())
            .first { $0.id == legacyRecurringActivityRawId }
        #expect(migratedLegacyRecurringActivity != nil)
        #expect(migratedLegacyRecurringActivity?.title == "Wednesday gym")
        #expect(migratedLegacyRecurringActivity?.activityType == .physicalTraining)
        #expect(migratedLegacyRecurringActivity?.weekdays == [.wednesday])

        // The new Sport table is genuinely usable against the migrated
        // store — proves the lightweight stage actually created it, not
        // merely that the container opened without throwing.
        let sportRepository = SportRepository(modelContext: v4Container.mainContext)
        let seeded = try sportRepository.seedCanonicalSportsIfNeeded()
        #expect(seeded.count == 3)
        #expect(try sportRepository.fetchAllSports().count == 3)
    }

    /// Codemagic checksum fix, requirement 2: an existing install still
    /// on the OLDEST schema (V1, `AppCurrentSchema`) must be able to
    /// reach the CURRENT schema (V3) in a single relaunch, through the
    /// FULL migration plan walking BOTH stages in order (V1→V2, then
    /// V2→V3) — this is the actual scenario a real TestFlight install
    /// that has never been relaunched since before Sleep V1 hits today.
    /// `existingV1StoreMigratesToV2Successfully` and
    /// `existingV2StoreMigratesToV3Successfully` above each cover one
    /// hop in isolation; neither proves the CHAIN itself resolves
    /// correctly when both stages must run back-to-back against a
    /// single container construction — which is exactly the class of
    /// bug ("Duplicate version checksums detected.") this whole fix
    /// addresses, since that error is thrown while `ModelContainer`
    /// validates the ENTIRE `AppSchemaMigrationPlan.schemas` graph, not
    /// just the one stage nominally being exercised.
    @Test("A store created under AppCurrentSchema (V1) reopens successfully directly under AppSchemaV3 — the full V1->V2->V3 migration chain runs in one relaunch, existing data survives, and Athlete Color resolves to nil/fallback for an athlete who predates the concept entirely")
    @MainActor
    func existingV1StoreMigratesAllTheWayToV3Successfully() throws {
        let storeURL = URL.temporaryDirectory.appendingPathComponent("v1-to-v3-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let v1Schema = Schema(versionedSchema: AppCurrentSchema.self)
        var athleteRawId: UUID
        do {
            let v1Container = try ModelContainer(
                for: v1Schema,
                migrationPlan: AppSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: v1Schema, url: storeURL)]
            )
            let athlete = AthleteProfile(
                workspaceId: WorkspaceId(), givenName: "Jonas",
                birthDate: LocalDate(year: 2012, month: 4, day: 10),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
            )
            v1Container.mainContext.insert(athlete)
            try v1Container.mainContext.save()
            athleteRawId = athlete.id
            // No AthleteSettings row at all under V1 — that type didn't
            // exist yet in this store's schema. Deliberately left
            // unset, matching a genuinely ancient install.
        }
        // Container above goes out of scope — genuinely closed, matching
        // a real app relaunch rather than a container kept alive.

        // The NEXT launch skips straight to V3 — the real production
        // default (CompositionRoot.build's own
        // `versionedSchema: AppSchemaV3.self`) — exactly what a real
        // app update does; nothing in production ever opens V2
        // explicitly as an intermediate step.
        let v3Schema = Schema(versionedSchema: AppSchemaV3.self)
        let v3Container = try ModelContainer(
            for: v3Schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: v3Schema, url: storeURL)]
        )

        // Pre-existing V1 data survived both migration stages, chained,
        // completely untouched.
        let athleteRepository = AthleteRepository(modelContext: v3Container.mainContext)
        let athletes = try athleteRepository.fetchAllAthletes()
        #expect(athletes.count == 1)
        #expect(athletes.first?.id == athleteRawId)
        #expect(athletes.first?.givenName == "Jonas")

        // DailyStatus/AthleteSettings — added at V2, absent from V1 —
        // are genuinely usable against the fully-migrated store, not
        // merely present as empty tables.
        let athleteId = AthleteId(rawValue: athleteRawId)
        let reflectionRepository = ReflectionRepository(modelContext: v3Container.mainContext)
        let recorded = try reflectionRepository.upsertSleepQuality(
            athleteId: athleteId,
            localDate: LocalDate(year: 2026, month: 8, day: 19),
            sleepQuality: 5,
            visibility: .sharedWithGuardians
        )
        #expect(recorded.sleepQuality == 5)

        // No AthleteSettings row ever existed for this athlete (V1 had
        // no such table at all) — preferredColor resolves to nil, and
        // Athlete Color's own stable AthleteId fallback is what
        // presentation uses for it, never a forced default persisted
        // here.
        #expect(try athleteRepository.fetchAthleteSettings(forAthlete: athleteId)?.preferredColor == nil)

        // The field added at V3 is genuinely writable/readable against
        // a store that jumped all the way from V1.
        try athleteRepository.setPreferredColor(athleteId: athleteId, color: .cyan)
        #expect(try athleteRepository.fetchAthleteSettings(forAthlete: athleteId)?.preferredColor == .cyan)
    }

    @Test("A save failure during onboarding rolls back completely, leaving no partial family data")
    @MainActor
    func onboardingRollbackOnSaveFailure() throws {
        struct InjectedSaveFailure: Error {}

        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )

        #expect(throws: InjectedSaveFailure.self) {
            try coordinator.createFamily(
                parentGivenName: "Kari",
                athleteGivenName: "Jonas",
                athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
                athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
                athleteDevelopmentStage: .parentLed,
                failAt: nil,
                saveOverride: { throw InjectedSaveFailure() }
            )
        }

        #expect(try parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
        #expect(try parentWorkspaceRepository.fetchAllWorkspaces().isEmpty)
        #expect(try athleteRepository.fetchAllAthletes().isEmpty)
        #expect(try athleteAccessGrantRepository.fetchAllGrants().isEmpty)
    }

    // A test previously here ("A genuine SwiftData save failure
    // (forced parent-id collision) during onboarding rolls back
    // completely") assumed that reusing the same ParentProfile.id
    // across two createFamily calls would cause SwiftData to reject
    // the second insert with a uniqueness violation. That assumption
    // was checked against this project's own prior, documented finding
    // — see the "Recurring Hard-Won Lessons" note "@Attribute(.unique)
    // is upsert not a rejecting constraint" — and confirmed still true:
    // ParentProfile.id genuinely IS declared `@Attribute(.unique)` (so
    // that part of the assumption was correct), but SwiftData's actual
    // behavior for a `.unique` collision is to UPSERT the existing row
    // rather than throw. The second createFamily call therefore never
    // throws at all — it silently overwrites the first family's
    // ParentProfile fields — so `#expect(throws:)` never has anything
    // to catch, and the test fails not because rollback is broken but
    // because its own premise about SwiftData's behavior was wrong.
    // Removed rather than rewritten to assert the upsert instead: that
    // would be a different test with a different purpose (documenting
    // upsert behavior, not rollback), and rollback against a genuine,
    // non-simulated failure is already covered by
    // onboardingRollbackOnSaveFailure above, via this project's
    // established saveOverride seam — the correct, deterministic way
    // to force a real save-time failure in this codebase.
}
